#!/usr/bin/env python3
"""
saeka-premium-bot — 4N1 FAST DEPLOYER Telegram Bot (Premium Edition)
Button-only interaction. Commands: /start only.
Welcome -> Deploy | Exit -> Fallback link -> Selection -> Deploy -> Links.
HTML-styled fonts, GIF animations, Back/Exit on every screen.
"""

from __future__ import annotations

import asyncio
import base64
import collections
import functools
import html
import json
import logging
import os
import re
import signal
import time
from pathlib import Path
from urllib.parse import urlparse, unquote

import yaml
from dotenv import load_dotenv
from telegram import (
    InlineKeyboardButton,
    InlineKeyboardMarkup,
    Update,
)
from telegram.constants import ParseMode
from telegram.error import BadRequest
from telegram.ext import (
    Application,
    CallbackQueryHandler,
    CommandHandler,
    ContextTypes,
    MessageHandler,
    filters,
)

# ---------------------------------------------------------------------------
# Design (HTML fonts only, no emojis)
# ---------------------------------------------------------------------------
GIFS = {
    "welcome": "https://media.giphy.com/media/3oEjI6SIIHBdRxXI40/giphy.gif",
    "deploy": "https://media.giphy.com/media/l0HlAbOIKAf5jLm1S/giphy.gif",
    "success": "https://media.giphy.com/media/3o7ZG8INZaT42dYVeq/giphy.gif",
    "error": "https://media.giphy.com/media/l378khQzB66sDlTjO/giphy.gif",
    "processing": "https://media.giphy.com/media/3o6ZtaO9BZHcOjmErm/giphy.gif",
    "link": "https://media.giphy.com/media/xT9IgzoKnwFNfISR8I/giphy.gif",
}

BASE = Path(__file__).resolve().parent
load_dotenv(BASE / ".env")
DATA = BASE / "data"
DATA.mkdir(exist_ok=True)

logging.basicConfig(
    format="%(asctime)s %(levelname)s %(name)s: %(message)s", level=logging.INFO
)
log = logging.getLogger("saeka-premium")

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
ENGINES = {
    "1": ("HAProxy", "Full protocol support incl. gRPC", False),
    "2": ("Envoy", "Fast & stable", False),
    "3": ("Caddy", "Modern & simple", False),
    "4": ("H2O", "Ultra-fast", False),
    "5": ("Traefik", "Cloud-native", False),
    "6": ("OpenResty", "No gRPC/H2", False),
    "7": ("SSH Gateway", "Tunnel only", True),
    "8": ("OVPN Relay", "VPN relay", True),
    "9": ("Reality Combo", "Reality + XTLS", True),
}
MODES = {
    "1": ("Browsing", "1 vCPU / 2Gi", "Light usage"),
    "2": ("Streaming", "2 vCPU / 4Gi", "Media & video"),
    "3": ("Gaming", "4 vCPU / 8Gi", "Low latency"),
}
REGIONS = [
    "us-central1", "us-east1", "us-west1",
    "asia-east1", "asia-southeast1",
    "europe-west1", "europe-west4",
]
ADS_CHOICES = {"1": "No ads (block ad/tracker domains)", "2": "Ads (normal DNS)"}

ANSI_RE = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]")
SPINNER_RE = re.compile(r"\.\.\. [|/\\-] \d+s\s*$")
LINK_RE = re.compile(r"(?:vless|vmess|trojan|ss)://[^\s\"'<>]+")
HOST_RE = re.compile(r"^[A-Za-z0-9.-]+$")


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
def esc(text: str) -> str:
    return html.escape(str(text), quote=False)


def kb(rows: list[list[tuple[str, str]]]) -> InlineKeyboardMarkup:
    return InlineKeyboardMarkup(
        [[InlineKeyboardButton(label, callback_data=data) for label, data in row] for row in rows]
    )


def with_nav(rows: list[list[tuple[str, str]]], extra_back: bool = True) -> list[list[tuple[str, str]]]:
    nav = []
    if extra_back:
        nav.append([("Back", "nav:back")])
    nav.append([("Exit", "nav:exit")])
    return rows + nav


# ---------------------------------------------------------------------------
# Config / auth
# ---------------------------------------------------------------------------
def load_config() -> dict:
    cfg = {
        "repo_dir": "./404script",
        "allowed_user_ids": [],
        "default_region": "us-central1",
        "default_service_name": "saeka",
        "deploy_timeout_seconds": 3600,
        "progress_interval_seconds": 3,
    }
    for path in (BASE / "config.yaml", DATA / "settings.json"):
        if not path.exists():
            continue
        try:
            raw = path.read_text(encoding="utf-8")
            loaded = json.loads(raw) if path.suffix == ".json" else yaml.safe_load(raw)
            cfg.update({k: v for k, v in (loaded or {}).items() if v is not None})
        except Exception as exc:
            log.warning("could not read %s: %s", path, exc)
    return cfg


def repo_dir(cfg: dict) -> Path:
    p = Path(str(cfg["repo_dir"])).expanduser()
    return p if p.is_absolute() else (BASE / p).resolve()


def get_owner() -> int | None:
    f = DATA / "owner.json"
    if not f.exists():
        return None
    try:
        return int(json.loads(f.read_text())["id"])
    except Exception:
        return None


def set_owner(uid: int) -> None:
    f = DATA / "owner.json"
    f.write_text(json.dumps({"id": uid}))


def is_authorized(uid: int, cfg: dict) -> bool:
    allowed = [int(x) for x in (cfg.get("allowed_user_ids") or [])]
    if allowed:
        return uid in allowed
    owner = get_owner()
    if owner is None:
        set_owner(uid)
        return True
    return uid == owner


def authorized(fn):
    @functools.wraps(fn)
    async def wrapper(update: Update, context: ContextTypes.DEFAULT_TYPE):
        user = update.effective_user
        if user is None or not is_authorized(user.id, load_config()):
            text = "<b>Access denied.</b>"
            if update.callback_query:
                await update.callback_query.answer("Not authorized.", show_alert=True)
                try:
                    await update.callback_query.edit_message_text(text, parse_mode=ParseMode.HTML)
                except Exception:
                    pass
            elif update.effective_message:
                await update.effective_message.reply_text(text, parse_mode=ParseMode.HTML)
            return
        return await fn(update, context)
    return wrapper


# ---------------------------------------------------------------------------
# Link parsing (fallback link -> project + host + region)
# ---------------------------------------------------------------------------
def host_from_link(text: str) -> str | None:
    m = re.search(r"[a-z]+://[^\s]+", text, re.I)
    if not m:
        return None
    link = m.group(0)
    scheme = link.split("://", 1)[0].lower()
    if scheme == "vmess":
        try:
            body = link.split("://", 1)[1].split("#", 1)[0]
            body += "=" * (-len(body) % 4)
            obj = json.loads(base64.b64decode(body).decode("utf-8", "ignore"))
            for key in ("sni", "host", "add"):
                val = str(obj.get(key) or "").strip()
                if val and HOST_RE.match(val):
                    return val.lower()
        except Exception:
            return None
        return None
    try:
        host = urlparse(link).hostname
    except ValueError:
        return None
    if host and HOST_RE.match(host):
        return host.lower()
    return None


def extract_project_hint(text: str) -> str | None:
    m = re.search(r"[?&]project=([^&]+)", text)
    if m:
        return unquote(m.group(1))
    m = re.search(r"qwiklabs-gcp-[a-z0-9]+", text)
    if m:
        return m.group(0)
    return None


def extract_region_hint(text: str) -> str | None:
    m = re.search(r"[?&]region=([^&]+)", text)
    if m:
        return unquote(m.group(1))
    for r in REGIONS:
        if r in text:
            return r
    return None


# ---------------------------------------------------------------------------
# Sending helpers (HTML + optional GIF)
# ---------------------------------------------------------------------------
async def send_msg(update: Update, context: ContextTypes.DEFAULT_TYPE, text: str, reply_markup=None, gif_key=None):
    chat_id = update.effective_chat.id
    if gif_key and gif_key in GIFS:
        try:
            await context.bot.send_animation(
                chat_id=chat_id, animation=GIFS[gif_key], caption=text,
                parse_mode=ParseMode.HTML, reply_markup=reply_markup,
            )
            return
        except Exception as exc:
            log.debug("gif send failed: %s", exc)
    await context.bot.send_message(
        chat_id=chat_id, text=text, parse_mode=ParseMode.HTML, reply_markup=reply_markup,
    )


async def safe_edit(query, text: str, reply_markup=None):
    try:
        await query.edit_message_text(text=text, parse_mode=ParseMode.HTML, reply_markup=reply_markup)
    except BadRequest as exc:
        if "not modified" not in str(exc).lower():
            log.debug("edit failed: %s", exc)
    except Exception as exc:
        log.debug("edit failed: %s", exc)


# ---------------------------------------------------------------------------
# Draft
# ---------------------------------------------------------------------------
def new_draft(cfg: dict, host: str | None = None, project: str | None = None, region: str | None = None) -> dict:
    default_name = str(cfg.get("default_service_name") or "saeka")
    name = host.split(".")[0] if host else default_name
    name = re.sub(r"[^a-z0-9-]", "", name.lower()).strip("-")[:30] or default_name
    return {
        "step": "engine",
        "engine": "1",
        "ads": "1",
        "mode": "1",
        "region": region or str(cfg.get("default_region") or REGIONS[0]),
        "name": name,
        "project": project or "",
        "host": host or "",
        "password": "",
    }


def draft_summary(d: dict) -> str:
    eng = ENGINES.get(d["engine"], ("Unknown", "", False))[0]
    lines = [
        f"<b>Project:</b> <code>{esc(d.get('project', '-'))}</code>",
        f"<b>Engine:</b> {esc(eng)}",
    ]
    if not ENGINES.get(d["engine"], ("", "", True))[2]:
        lines.append(f"<b>Ads:</b> {ADS_CHOICES.get(d['ads'], 'No ads')}")
    lines += [
        f"<b>Size:</b> {MODES[d['mode']][0]} ({MODES[d['mode']][1]})",
        f"<b>Region:</b> <code>{esc(d['region'])}</code>",
        f"<b>Service:</b> <code>{esc(d['name'])}</code>",
    ]
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# Screens
# ---------------------------------------------------------------------------
async def show_welcome(update: Update, context: ContextTypes.DEFAULT_TYPE):
    text = (
        "<b>SAEKA 4N1 FAST DEPLOYER</b>\n\n"
        "Deploy your proxy stack to GCP Cloud Run.\n\n"
        "<b>Features:</b>\n"
        "• 9 proxy engines\n"
        "• Smart sizing tiers (Browsing / Streaming / Gaming)\n"
        "• Auto client-link generation (VLESS / Trojan / VMess / SS)\n"
        "• Fallback-link project detection\n\n"
        "Tap <b>Deploy</b> to begin, or <b>Exit</b> to close."
    )
    await send_msg(
        update, context, text,
        reply_markup=kb([
            [("Deploy", "m:deploy")],
            [("Exit", "m:exit")],
        ]),
        gif_key="welcome",
    )


async def show_link_prompt(update: Update, context: ContextTypes.DEFAULT_TYPE, draft_note: str = ""):
    text = (
        "<b>Step 1 — Fallback Link</b>\n\n"
        "Paste your Qwiklabs / Google Cloud Console fallback link.\n"
        "I will extract the <b>project</b> and <b>region</b> automatically.\n\n"
        f"{draft_note}"
        "Send the link below, or tap <b>Back</b> / <b>Exit</b>."
    )
    await send_msg(
        update, context, text,
        reply_markup=with_nav([]),
        gif_key="link",
    )


# ---------------------------------------------------------------------------
# Command /start
# ---------------------------------------------------------------------------
@authorized
async def cmd_start(update: Update, context: ContextTypes.DEFAULT_TYPE):
    cfg = load_config()
    user = update.effective_user
    context.user_data.clear()
    context.user_data["started"] = time.time()
    await show_welcome(update, context)


# ---------------------------------------------------------------------------
# Main button handler
# ---------------------------------------------------------------------------
@authorized
async def on_button(update: Update, context: ContextTypes.DEFAULT_TYPE):
    query = update.callback_query
    await query.answer()
    cfg = load_config()
    data = query.data or ""
    d = context.user_data.get("draft")

    log.info("Button pressed: %s, step: %s", data, d.get("step") if d else None)

    if data == "nav:exit":
        context.user_data.pop("draft", None)
        await safe_edit(query, "<b>Session closed.</b>\nSend /start to begin again.")
        return
    if data == "nav:back":
        await handle_back(query, d, cfg)
        return

    if data == "m:deploy":
        context.user_data["draft"] = new_draft(cfg)
        await show_link_prompt(update, context)
        return
    if data == "m:exit":
        context.user_data.pop("draft", None)
        await safe_edit(query, "<b>Goodbye!</b>\nSend /start anytime.")
        return

    if not d:
        await query.edit_message_text(
            "<b>Session expired.</b> Send /start again.",
            parse_mode=ParseMode.HTML,
        )
        return

    kind, _, val = data.partition(":")
    step = d.get("step")

    if kind == "e" and step == "engine" and val in ENGINES:
        d["engine"] = val
        if ENGINES[val][2]:
            d["ads"] = "1"
            await show_region(query, d, cfg)
        else:
            await show_ads(query, d, cfg)
        return

    if kind == "a" and step == "ads" and val in ADS_CHOICES:
        d["ads"] = val
        await show_mode(query, d, cfg)
        return

    if kind == "m" and step == "mode" and val in MODES:
        d["mode"] = val
        await show_region(query, d, cfg)
        return

    if kind == "r" and step == "region" and val in REGIONS:
        d["region"] = val
        await show_name(query, d, cfg)
        return

    if kind == "n" and step == "name" and val == "use":
        await show_confirm(query, d, cfg)
        return

    if kind == "c" and step == "confirm" and val == "go":
        await do_deploy(update, context, d, cfg)
        return

    await query.answer("Option outdated. Use /start again.", show_alert=False)


async def show_ads(query, d: dict, cfg: dict):
    d["step"] = "ads"
    rows = [[(f"{label}", f"a:{k}")] for k, label in ADS_CHOICES.items()]
    await safe_edit(
        query,
        "<b>Step 2 — Ads Mode</b>\nChoose DNS filtering:",
        reply_markup=with_nav(rows),
    )


async def show_mode(query, d: dict, cfg: dict):
    d["step"] = "mode"
    rows = [[(f"{label} — {sub}", f"m:{k}")] for k, (label, _, sub) in MODES.items()]
    await safe_edit(
        query,
        "<b>Step 3 — Sizing Tier</b>\nPick your performance tier:",
        reply_markup=with_nav(rows),
    )


async def show_region(query, d: dict, cfg: dict):
    d["step"] = "region"
    default = d.get("region") or cfg.get("default_region") or REGIONS[0]
    rows = [[(r + (" *" if r == default else ""), f"r:{r}")] for r in REGIONS]
    await safe_edit(
        query,
        "<b>Step 4 — Deploy Region</b>\nPick a GCP region (* = default):",
        reply_markup=with_nav(rows),
    )


async def show_name(query, d: dict, cfg: dict):
    d["step"] = "name"
    await safe_edit(
        query,
        f"<b>Step 5 — Service Name</b>\nTap <b>Use {esc(d['name'])}</b> or send a custom name.\n\n"
        f"Current: <code>{esc(d['name'])}</code>",
        reply_markup=with_nav([[("Use " + d["name"], "n:use")]]),
    )


async def show_confirm(query, d: dict, cfg: dict):
    d["step"] = "confirm"
    markup = with_nav([[("Deploy Now", "c:go")]])
    await safe_edit(
        query,
        "<b>Confirm Deployment</b>\n\n"
        f"{draft_summary(d)}\n\n"
        "<i>This creates real GCP resources (billing applies).</i>",
        reply_markup=markup,
    )


async def handle_back(query, d: dict | None, cfg: dict):
    if not d:
        await safe_edit(query, "<b>No session.</b> Send /start.", reply_markup=None)
        return
    step = d.get("step")
    if step == "engine":
        await show_welcome_from_query(query)
    elif step == "ads":
        await show_engine(query, d, cfg)
    elif step == "mode":
        await show_ads(query, d, cfg)
    elif step == "region":
        await show_mode(query, d, cfg)
    elif step == "name":
        await show_region(query, d, cfg)
    elif step == "confirm":
        await show_name(query, d, cfg)
    else:
        await show_welcome_from_query(query)


async def show_welcome_from_query(query):
    text = (
        "<b>SAEKA 4N1 FAST DEPLOYER</b>\n\n"
        "Deploy your proxy stack to GCP Cloud Run.\n\n"
        "Tap <b>Deploy</b> to begin."
    )
    await safe_edit(
        query, text,
        reply_markup=kb([
            [("Deploy", "m:deploy")],
            [("Exit", "m:exit")],
        ]),
    )


async def show_engine(query, d: dict, cfg: dict):
    d["step"] = "engine"
    rows = []
    row = []
    for key, (name, desc, _) in ENGINES.items():
        row.append((f"{key}) {name}", f"e:{key}"))
        if len(row) == 2:
            rows.append(row)
            row = []
    if row:
        rows.append(row)
    await safe_edit(
        query,
        "<b>Step 1 — Proxy Engine</b>\nChoose your engine:",
        reply_markup=with_nav(rows),
    )


# ---------------------------------------------------------------------------
# Text input
# ---------------------------------------------------------------------------
@authorized
async def on_text(update: Update, context: ContextTypes.DEFAULT_TYPE):
    cfg = load_config()
    msg = update.effective_message
    text = (msg.text or "").strip()
    d = context.user_data.get("draft")

    # Custom service name input
    if d and d.get("step") == "name":
        name = text.lower()
        if not re.match(r"^[a-z][a-z0-9-]{0,29}$", name) or name.endswith("-"):
            await msg.reply_text(
                "<b>Invalid name.</b> Use a-z, 0-9 and - only. Start with a letter. Max 30 chars.",
                parse_mode=ParseMode.HTML,
            )
            return
        d["name"] = name
        await show_confirm_from_msg(msg, d, cfg)
        return

    # Fallback link input
    host = host_from_link(text)
    project = extract_project_hint(text)
    region = extract_region_hint(text)
    if host or project:
        if context.application.bot_data.get("current"):
            await msg.reply_text("<b>A deployment is already running.</b> Use /start.", parse_mode=ParseMode.HTML)
            return
        context.user_data["draft"] = new_draft(cfg, host, project, region)
        parts = []
        if project:
            parts.append(f"<b>Project:</b> <code>{esc(project)}</code>")
        if region:
            parts.append(f"<b>Region:</b> <code>{esc(region)}</code>")
        if host:
            parts.append(f"<b>Host:</b> <code>{esc(host)}</code>")
        note = " | ".join(parts) if parts else "No details detected."
        await msg.reply_text(
            f"<b>Link processed.</b>\n{note}\n\nChoose your proxy engine:",
            parse_mode=ParseMode.HTML,
            reply_markup=engine_kb_with_nav(),
        )
        return

    await msg.reply_text(
        "<b>Send a fallback link, or tap Deploy from /start.</b>",
        parse_mode=ParseMode.HTML,
    )


async def show_confirm_from_msg(msg, d: dict, cfg: dict):
    d["step"] = "confirm"
    markup = with_nav([[("Deploy Now", "c:go")]])
    await msg.reply_text(
        "<b>Confirm Deployment</b>\n\n"
        f"{draft_summary(d)}\n\n"
        "<i>This creates real GCP resources (billing applies).</i>",
        parse_mode=ParseMode.HTML,
        reply_markup=markup,
    )


def engine_kb_with_nav():
    rows = []
    row = []
    for key, (name, desc, _) in ENGINES.items():
        row.append((f"{key}) {name}", f"e:{key}"))
        if len(row) == 2:
            rows.append(row)
            row = []
    if row:
        rows.append(row)
    return with_nav(rows)


# ---------------------------------------------------------------------------
# Deploy runner
# ---------------------------------------------------------------------------
def kill_tree(proc):
    try:
        os.killpg(os.getpgid(proc.pid), signal.SIGTERM)
    except (ProcessLookupError, PermissionError):
        pass


def pre_block(lines, limit=3000):
    body = "\n".join(lines)
    if len(body) > limit:
        body = "..." + body[-limit:]
    return "<pre>" + html.escape(body) + "</pre>"


async def do_deploy(update: Update, context: ContextTypes.DEFAULT_TYPE, d: dict, cfg: dict):
    bot = context.bot
    chat_id = update.effective_chat.id
    repo = repo_dir(cfg)
    script = repo / "deploy.sh"
    engine_name = ENGINES[d["engine"]][0]

    if not script.exists():
        await bot.send_message(
            chat_id,
            f"<b>deploy.sh not found</b> at {script}.",
            parse_mode=ParseMode.HTML,
        )
        context.application.bot_data["current"] = None
        return

    project = d.get("project") or ""
    if not project:
        await bot.send_message(
            chat_id,
            "<b>No project found.</b>\nSend a fallback link containing a GCP project "
            "(e.g. qwiklabs-gcp-XXXX).",
            parse_mode=ParseMode.HTML,
        )
        context.application.bot_data["current"] = None
        return

    password = d.get("password") or os.environ.get("DEPLOY_PASSWORD", "")
    env = os.environ.copy()
    env.pop("BOT_TOKEN", None)
    env.update({
        "DEPLOY_AUTO": "1",
        "DEPLOY_PASSWORD": password,
        "DEPLOY_PROJECT": project,
        "DEPLOY_ENGINE_CHOICE": d["engine"],
        "DEPLOY_ADS_CHOICE": d["ads"],
        "DEPLOY_MODE_CHOICE": d["mode"],
        "DEPLOY_SERVICE_NAME": d["name"],
        "DEPLOY_REGION": d["region"],
        "REGION": d["region"],
        "TERM": env.get("TERM", "dumb"),
    })

    status = await bot.send_message(
        chat_id,
        f"<b>Starting deployment</b> — {esc(d['name'])}",
        parse_mode=ParseMode.HTML,
    )
    cur = {
        "name": d["name"],
        "engine": engine_name,
        "started": time.time(),
        "proc": None,
        "cancelled": False,
    }
    context.application.bot_data["current"] = cur
    lines = collections.deque(maxlen=600)
    timed_out = False

    try:
        proc = await asyncio.create_subprocess_exec(
            "bash", str(script), "--auto",
            cwd=str(repo), env=env,
            stdin=asyncio.subprocess.DEVNULL,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.STDOUT,
            start_new_session=True,
        )
        cur["proc"] = proc

        interval = max(2, int(cfg.get("progress_interval_seconds", 3)))
        deadline = time.time() + int(cfg.get("deploy_timeout_seconds", 3600))
        last_edit = 0.0
        remainder = ""

        while True:
            try:
                chunk = await asyncio.wait_for(proc.stdout.read(4096), timeout=interval)
            except asyncio.TimeoutError:
                chunk = None
            if chunk == b"":
                break
            if chunk:
                text = remainder + ANSI_RE.sub("", chunk.decode("utf-8", "replace"))
                parts = re.split(r"[\r\n]", text)
                remainder = parts.pop()
                for p in parts:
                    p = p.rstrip()
                    if p.strip() and not SPINNER_RE.search(p):
                        lines.append(p)
            if time.time() > deadline:
                timed_out = True
                kill_tree(proc)
                break
            if time.time() - last_edit >= interval:
                last_edit = time.time()
                secs = int(time.time() - cur["started"])
                try:
                    await status.edit_text(
                        f"<b>Deploying</b> {esc(d['name'])} ({secs}s)\n"
                        + pre_block(list(lines)[-10:], 1500),
                        parse_mode=ParseMode.HTML,
                    )
                except Exception:
                    pass
        if remainder.strip():
            lines.append(remainder.strip())
        try:
            rc = await asyncio.wait_for(proc.wait(), timeout=15)
        except asyncio.TimeoutError:
            proc.kill()
            rc = -9
    except Exception as exc:
        log.exception("deploy crashed")
        context.application.bot_data["current"] = None
        await bot.send_message(
            chat_id, f"<b>Deploy error:</b>\n<pre>{esc(str(exc))}</pre>",
            parse_mode=ParseMode.HTML,
        )
        return
    finally:
        context.application.bot_data["current"] = None

    all_lines = list(lines)
    full = "\n".join(all_lines)
    host_m = re.search(r"RAW HOST\s+(https://\S+)", full)
    links = list(dict.fromkeys(LINK_RE.findall(full)))
    creds = [l.strip() for l in all_lines if "Generated login" in l or "Generated password" in l]

    if cur["cancelled"]:
        await status.edit_text("<b>Cancelled.</b>", parse_mode=ParseMode.HTML)
        return
    if timed_out:
        await status.edit_text("<b>Timed out.</b>", parse_mode=ParseMode.HTML)
        await bot.send_message(chat_id, pre_block(all_lines[-25:]), parse_mode=ParseMode.HTML)
        return

    if rc == 0 and host_m:
        await status.edit_text(
            f"<b>Deployed!</b> {esc(d['name'])}",
            parse_mode=ParseMode.HTML,
        )
        out = [
            "<b>Deployment Successful</b>",
            f"<b>Project:</b> <code>{esc(project)}</code>",
            f"<b>Engine:</b> {esc(engine_name)}",
            f"<b>Region:</b> <code>{esc(d['region'])}</code>",
            f"<b>Host:</b> <code>{esc(host_m.group(1))}</code>",
        ]
        if creds:
            out.append("<b>Logins (shown once):</b>")
            out.extend(f"<code>{esc(c)}</code>" for c in creds)
        if links:
            out.append("<b>Client Links:</b>")
            out.extend(f"<code>{esc(l)}</code>" for l in links[:8])
        try:
            await context.bot.send_animation(
                chat_id=chat_id, animation=GIFS["success"], caption="\n".join(out)[:4000],
                parse_mode=ParseMode.HTML,
            )
        except Exception:
            await bot.send_message(chat_id, "\n".join(out)[:4000], parse_mode=ParseMode.HTML)
        return

    await status.edit_text(f"<b>Deploy failed</b> (exit code {rc}).", parse_mode=ParseMode.HTML)
    extra = []
    for p in (repo / "deploy.log", repo / "build.log"):
        if p.exists():
            extra = p.read_text(errors="replace").splitlines()[-15:]
            break
    shown = all_lines[-20:] + (["--- log tail ---"] + extra if extra else [])
    await bot.send_message(chat_id, pre_block(shown), parse_mode=ParseMode.HTML)


# ---------------------------------------------------------------------------
# Error handler
# ---------------------------------------------------------------------------
async def on_error(update, context: ContextTypes.DEFAULT_TYPE):
    log.error("handler error", exc_info=context.error)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def main() -> None:
    token = os.environ.get("BOT_TOKEN", "").strip()
    if not token or token.startswith("123456:"):
        raise SystemExit("Set BOT_TOKEN in .env")

    app = Application.builder().token(token).build()
    app.bot_data["current"] = None

    app.add_handler(CommandHandler("start", cmd_start))
    app.add_handler(CallbackQueryHandler(on_button))
    app.add_handler(MessageHandler(filters.TEXT & ~filters.COMMAND, on_text))
    app.add_error_handler(on_error)

    log.info("saeka-premium-bot started")
    app.run_polling(drop_pending_updates=True)


if __name__ == "__main__":
    main()
