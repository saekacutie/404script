#!/usr/bin/env python3
"""
saeka-tg-bot — Telegram bot that deploys the 4N1 FAST DEPLOYER stack to GCP Cloud Run.

Flow:
  1. /deploy → fallback link (extracts project + region) OR /skip
  2. Antibot verification (simple math CAPTCHA)
  3. Engine → ads mode → region → service name → tier → confirm
  4. Cloud Build → Cloud Run deploy → live URL → client links (vless/trojan/vmess/ss)

Only required setup: BOT_TOKEN in .env. GCP_PROJECT_ID is optional (extracted from link).
"""

from __future__ import annotations

import html
import os
import re
import secrets
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Optional
from urllib.parse import unquote, urlparse

from telegram import (
    InlineKeyboardButton,
    InlineKeyboardMarkup,
    Update,
    ReplyKeyboardRemove,
)
from telegram.constants import ParseMode
from telegram.ext import (
    Application,
    ApplicationBuilder,
    CommandHandler,
    ConversationHandler,
    ContextTypes,
    CallbackQueryHandler,
    MessageHandler,
    filters,
)

# ---------------------------------------------------------------------------
# Conversation states
# ---------------------------------------------------------------------------
(
    STATE_LINK,
    STATE_VERIFY,
    STATE_ENGINE,
    STATE_ADS,
    STATE_REGION,
    STATE_NAME,
    STATE_TIER,
    STATE_CONFIRM,
) = range(8)

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
BOT_TOKEN = os.environ.get("BOT_TOKEN", "")
PROJECT_ID = os.environ.get("GCP_PROJECT_ID", "")
DEFAULT_REGION = os.environ.get("GCP_REGION", "us-central1")
REPO_DIR = os.environ.get("REPO_DIR", str(Path(__file__).resolve().parent.parent))
ADMIN_IDS = {
    int(x) for x in os.environ.get("ADMIN_IDS", "").split(",") if x.strip().isdigit()
}

ENGINES = [
    ("⚡ HAProxy", "haproxy", "HAProxy"),
    ("🚀 Envoy", "envoy", "Envoy"),
    ("🔥 Caddy", "caddy", "Caddy"),
    ("🧊 H2O", "h2o", "H2O"),
    ("🌪️ Traefik", "traefik", "Traefik"),
    ("🌐 OpenResty", "openresty", "OpenResty"),
]

ADS_MODES = [
    ("🚫 No ads", "noads", "No ads"),
    ("📢 Ads", "ads", "Ads"),
]

REGIONS = [
    ("us-central1", "us-central1"),
    ("us-east1", "us-east1"),
    ("us-west1", "us-west1"),
    ("asia-east1", "asia-east1"),
    ("asia-southeast1", "asia-southeast1"),
    ("europe-west1", "europe-west1"),
    ("europe-west4", "europe-west4"),
]

TIERS = [
    ("1) Browsing (1 vCPU / 2Gi)", "1", "2Gi", 100, 4, "BROWSING"),
    ("2) Streaming (2 vCPU / 4Gi)", "2", "4Gi", 50, 4, "STREAMING"),
    ("3) Gaming (4 vCPU / 8Gi)", "4", "8Gi", 50, 4, "GAMING"),
]


def require_env() -> None:
    if not BOT_TOKEN:
        print("FATAL: missing BOT_TOKEN env var", file=sys.stderr)
        sys.exit(1)


def is_admin(user_id: int) -> bool:
    return not ADMIN_IDS or user_id in ADMIN_IDS


# ---------------------------------------------------------------------------
# Fallback-link processing (extract project + region)
# ---------------------------------------------------------------------------
def extract_project_hint(raw: str) -> Optional[str]:
    """Pull a GCP project id from qwiklabs/console URLs."""
    m = re.search(r"[?&]project=([^&]+)", raw)
    if m:
        return unquote(m.group(1))
    m = re.search(r"qwiklabs-gcp-[a-z0-9]+", raw)
    if m:
        return m.group(0)
    return None


def extract_region_hint(raw: str) -> Optional[str]:
    """Pull a GCP region from console URLs."""
    m = re.search(r"[?&]region=([^&]+)", raw)
    if m:
        return unquote(m.group(1))
    m = re.search(r"/(us-central1|us-east1|us-west1|asia-east1|asia-southeast1|europe-west1|europe-west4)(/|$)", raw)
    if m:
        return m.group(1)
    return None


def extract_host_from_link(raw: str) -> Optional[str]:
    """Return a bare host if the link looks like a direct service URL."""
    raw = raw.strip().strip("<>")
    if not raw:
        return None
    parsed = urlparse(raw)
    host = parsed.hostname if (parsed.scheme and parsed.hostname) else raw.split("/")[0]
    host = host.lower()
    bad = {
        "www.skills.google", "accounts.google.com", "console.cloud.google.com",
        "myaccount.google.com", "mail.google.com",
    }
    if host in bad or "." not in host or " " in host:
        return None
    return host


# ---------------------------------------------------------------------------
# Deployment logic (non-interactive, mirrors deploy.sh)
# ---------------------------------------------------------------------------
class Deployer:
    def __init__(self, project_id: str, region: str, repo_dir: str):
        self.project_id = project_id
        self.region = region
        self.repo_dir = repo_dir

    def _run(self, args: list[str], label: str, timeout: int = 1800) -> tuple[bool, str]:
        lines: list[str] = []
        try:
            proc = subprocess.Popen(
                args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                text=True, cwd=self.repo_dir,
            )
            assert proc.stdout is not None
            for raw in proc.stdout:
                lines.append(raw.rstrip("\n"))
            proc.wait(timeout=timeout)
            ok = proc.returncode == 0
            return ok, "\n".join(lines)
        except subprocess.TimeoutExpired:
            proc.kill()
            return False, "\n".join(lines) + f"\n[!] {label} timed out after {timeout}s"
        except Exception as exc:  # noqa: BLE001
            return False, "\n".join(lines) + f"\n[!] {label} error: {exc}"

    def build_image(self, engine: str, image_tag: str) -> tuple[bool, str]:
        dockerfile = f"proxies/{engine}/Dockerfile"
        cb_config = tempfile.NamedTemporaryFile("w", suffix=".yaml", delete=False)
        cb_config.write(
            "timeout: '1200s'\n"
            "steps:\n"
            f"  - name: 'gcr.io/cloud-builders/docker'\n"
            f"    args: ['build', '-f', '{dockerfile}', '-t', 'gcr.io/{self.project_id}/{image_tag}', '.']\n"
            f"images:\n  - 'gcr.io/{self.project_id}/{image_tag}'\n"
        )
        cb_config.close()
        try:
            ok, out = self._run(
                ["gcloud", "builds", "submit", ".",
                 "--config", cb_config.name,
                 "--project", self.project_id],
                "cloud build",
                timeout=1300,
            )
        finally:
            os.unlink(cb_config.name)
        return ok, out

    def deploy(
        self, service_name: str, image_tag: str, engine: str,
        cpu: str, ram: str, max_instances: str, concurrency: int,
        ads_mode: str, min_instances: int,
    ) -> tuple[bool, str]:
        env_vars = f"ADS_MODE={ads_mode}"
        cmd = [
            "gcloud", "run", "deploy", service_name,
            f"--image=gcr.io/{self.project_id}/{image_tag}",
            "--platform=managed", f"--region={self.region}",
            f"--cpu={cpu}", f"--memory={ram}", "--port=8080",
            f"--max-instances={max_instances}",
            "--timeout=3600", "--allow-unauthenticated", f"--project={self.project_id}",
            f"--set-env-vars={env_vars}",
            f"--concurrency={concurrency}",
            "--cpu-boost", "--no-cpu-throttling",
            f"--min-instances={min_instances}",
            "--quiet",
        ]
        return self._run(cmd, "cloud run deploy", timeout=1800)

    def get_service_url(self, service_name: str) -> Optional[str]:
        ok, out = self._run(
            ["gcloud", "run", "services", "describe", service_name,
             f"--region={self.region}", f"--project={self.project_id}",
             "--format=value(status.url)"],
            "describe service",
            timeout=60,
        )
        if not ok:
            return None
        url = out.strip()
        return url or None

    def generate_links(self, host: str) -> tuple[bool, str]:
        script = os.path.join(self.repo_dir, "generate-client-links.sh")
        if not os.path.exists(script):
            return False, "generate-client-links.sh not found"
        return self._run(
            ["bash", script, host, "443", "saeka", "chrome"],
            "generate-client-links",
            timeout=60,
        )


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
def esc(text: str) -> str:
    return html.escape(str(text), quote=False)


def chunk_text(text: str, size: int = 3500) -> list[str]:
    return [text[i:i + size] for i in range(0, len(text), size)] or [""]


async def send_msg(update: Update, context: ContextTypes.DEFAULT_TYPE, text: str, **kwargs) -> None:
    chat_id = update.effective_chat.id
    for part in chunk_text(text):
        await context.bot.send_message(chat_id=chat_id, text=part, parse_mode=ParseMode.HTML, **kwargs)


def box(title: str, lines: list[str]) -> str:
    inner = "\n".join(f"  {line}" for line in lines)
    return f"<b>{esc(title)}</b>\n<pre>{inner}</pre>"


# ---------------------------------------------------------------------------
# Antibot verification
# ---------------------------------------------------------------------------
def make_captcha() -> tuple[str, int]:
    a = secrets.randbelow(9) + 1
    b = secrets.randbelow(9) + 1
    return f"{a} + {b} = ?", a + b


# ---------------------------------------------------------------------------
# Handlers
# ---------------------------------------------------------------------------
async def start(update: Update, context: ContextTypes.DEFAULT_TYPE) -> int:
    user = update.effective_user
    if not is_admin(user.id):
        await update.effective_message.reply_text("🔒 Access denied.")
        return ConversationHandler.END
    text = (
        "🤖 <b>saeka-tg-bot — 4N1 FAST DEPLOYER</b>\n\n"
        "Deploy your proxy stack to GCP Cloud Run from Telegram.\n\n"
        "Commands:\n"
        "• /deploy — start a new deployment\n"
        "• /cancel — cancel current operation\n"
        "• /status — show bot config\n"
        "• /help — show this message\n\n"
        "Flow: fallback link → verify → engine → ads → region → name → tier → confirm → deploy → links"
    )
    await send_msg(update, context, text)
    return ConversationHandler.END


async def deploy_cmd(update: Update, context: ContextTypes.DEFAULT_TYPE) -> int:
    user = update.effective_user
    if not is_admin(user.id):
        await update.effective_message.reply_text("🔒 Access denied.")
        return ConversationHandler.END
    context.user_data.clear()
    context.user_data["started"] = time.time()
    text = (
        "📎 <b>Step 1 — Fallback link</b>\n\n"
        "Paste a fallback link (Qwiklabs / console.cloud.google.com URL). The bot extracts\n"
        "the GCP project and region from it.\n\n"
        "Or send <code>/skip</code> to begin without a link.\n\n"
        "Send /cancel to abort."
    )
    await send_msg(update, context, text)
    return STATE_LINK


async def link_received(update: Update, context: ContextTypes.DEFAULT_TYPE) -> int:
    raw = (update.effective_message.text or "").strip()
    proj = extract_project_hint(raw)
    reg = extract_region_hint(raw)
    host = extract_host_from_link(raw)
    context.user_data["fallback_link"] = raw
    context.user_data["project_hint"] = proj
    context.user_data["region_hint"] = reg
    context.user_data["fallback_host"] = host

    bits = []
    if proj:
        bits.append(f"✅ Project: <code>{esc(proj)}</code>")
    else:
        bits.append("⚠️ Project: not found in link")
    if reg:
        bits.append(f"✅ Region: <code>{esc(reg)}</code>")
        context.user_data["region"] = reg
    if host:
        bits.append(f"🔗 Host: <code>{esc(host)}</code>")

    await send_msg(
        update, context,
        "📥 <b>Link processed — target extracted.</b>\n" + "\n".join(bits) +
        "\n\nChoose the proxy engine to deploy:",
        reply_markup=engine_keyboard(),
    )
    return STATE_ENGINE


async def skip_link(update: Update, context: ContextTypes.DEFAULT_TYPE) -> int:
    context.user_data["fallback_link"] = ""
    context.user_data["project_hint"] = None
    context.user_data["region_hint"] = None
    context.user_data["fallback_host"] = None
    await send_msg(
        update, context,
        "⏭️ Link skipped. Choose the proxy engine to deploy:",
        reply_markup=engine_keyboard(),
    )
    return STATE_ENGINE


def engine_keyboard() -> InlineKeyboardMarkup:
    return InlineKeyboardMarkup([
        [InlineKeyboardButton(f"{name} ({engine})", callback_data=f"eng:{eng}")]
        for name, eng, _ in ENGINES
    ])


async def engine_chosen(update: Update, context: ContextTypes.DEFAULT_TYPE) -> int:
    query = update.callback_query
    await query.answer()
    try:
        _, eng = query.data.split(":", 1)
    except ValueError:
        await send_msg(update, context, "❌ Invalid selection. Start over with /deploy.")
        return ConversationHandler.END
    emap = {eng: (label, disp) for label, eng, disp in ENGINES}
    if eng not in emap:
        await send_msg(update, context, "❌ Unknown engine. Start over with /deploy.")
        return ConversationHandler.END
    _, disp = emap[eng]
    context.user_data["engine"] = eng
    context.user_data["engine_label"] = disp
    await query.edit_message_text(
        f"⚙️ <b>Step 2 — Ads mode</b>\nEngine: <code>{esc(disp)}</code>\nChoose ads mode:",
        parse_mode=ParseMode.HTML,
        reply_markup=ads_keyboard(),
    )
    return STATE_ADS


def ads_keyboard() -> InlineKeyboardMarkup:
    return InlineKeyboardMarkup([
        [InlineKeyboardButton(name, callback_data=f"ads:{mode}")]
        for name, mode, _ in ADS_MODES
    ])


async def ads_chosen(update: Update, context: ContextTypes.DEFAULT_TYPE) -> int:
    query = update.callback_query
    await query.answer()
    try:
        _, mode = query.data.split(":", 1)
    except ValueError:
        await send_msg(update, context, "❌ Invalid selection. Start over with /deploy.")
        return ConversationHandler.END
    amap = {mode: (label, disp) for label, mode, disp in ADS_MODES}
    if mode not in amap:
        await send_msg(update, context, "❌ Unknown ads mode. Start over with /deploy.")
        return ConversationHandler.END
    _, disp = amap[mode]
    context.user_data["ads_mode"] = mode
    context.user_data["ads_label"] = disp
    await query.edit_message_text(
        f"📢 <b>Step 3 — Region</b>\nAds mode: <code>{esc(disp)}</code>\nChoose deploy region:",
        parse_mode=ParseMode.HTML,
        reply_markup=region_keyboard(),
    )
    return STATE_REGION


def region_keyboard() -> InlineKeyboardMarkup:
    rows = [
        [InlineKeyboardButton(region, callback_data=f"reg:{region}")]
        for region, _ in REGIONS
    ]
    paired = [rows[i:i + 2] for i in range(0, len(rows), 2)]
    return InlineKeyboardMarkup(paired)


async def region_chosen(update: Update, context: ContextTypes.DEFAULT_TYPE) -> int:
    query = update.callback_query
    await query.answer()
    try:
        _, region = query.data.split(":", 1)
    except ValueError:
        await send_msg(update, context, "❌ Invalid selection. Start over with /deploy.")
        return ConversationHandler.END
    if region not in {r for r, _ in REGIONS}:
        await send_msg(update, context, "❌ Unknown region. Start over with /deploy.")
        return ConversationHandler.END
    context.user_data["region"] = region
    await query.edit_message_text(
        f"🌍 <b>Step 4 — Service name</b>\nRegion: <code>{esc(region)}</code>\n"
        "Send a service name (e.g. <code>saeka</code>) or blank for default.",
        parse_mode=ParseMode.HTML,
        reply_markup=ReplyKeyboardRemove(),
    )
    return STATE_NAME


async def name_received(update: Update, context: ContextTypes.DEFAULT_TYPE) -> int:
    raw = (update.effective_message.text or "").strip()
    name = raw or "saeka"
    name = re.sub(r"[^a-z0-9-]", "-", name.lower())[:40] or "saeka"
    context.user_data["service_name"] = name
    context.user_data["image_tag"] = f"{name}-{context.user_data.get('engine', 'haproxy')}"
    await send_msg(
        update, context,
        f"📛 <b>Step 5 — Tier</b>\nService: <code>{esc(name)}</code>\nChoose sizing tier:",
        parse_mode=ParseMode.HTML,
        reply_markup=tier_keyboard(),
    )
    return STATE_TIER


def tier_keyboard() -> InlineKeyboardMarkup:
    return InlineKeyboardMarkup([
        [InlineKeyboardButton(label, callback_data=f"tier:{i}")]
        for i, (label, *_rest) in enumerate(TIERS)
    ])


async def tier_chosen(update: Update, context: ContextTypes.DEFAULT_TYPE) -> int:
    query = update.callback_query
    await query.answer()
    try:
        _, idx = query.data.split(":", 1)
        idx = int(idx)
    except (ValueError, IndexError):
        await send_msg(update, context, "❌ Invalid tier. Start over with /deploy.")
        return ConversationHandler.END
    if idx < 0 or idx >= len(TIERS):
        await send_msg(update, context, "❌ Unknown tier. Start over with /deploy.")
        return ConversationHandler.END
    tier = TIERS[idx]
    _, cpu, ram, concurrency, max_instances, mode_name = tier
    context.user_data.update({
        "cpu": cpu, "ram": ram, "concurrency": concurrency,
        "max_instances": max_instances, "tier": mode_name, "min_instances": 1,
    })

    ud = context.user_data
    deploy_project = ud.get("project_hint") or PROJECT_ID or ""
    text = (
        "✅ <b>Confirm deployment</b>\n\n"
        f"• Project: <code>{esc(deploy_project) or '—'}</code>\n"
        f"• Engine: <code>{esc(ud.get('engine_label',''))}</code>\n"
        f"• Ads: <code>{esc(ud.get('ads_label',''))}</code>\n"
        f"• Region: <code>{esc(ud.get('region',''))}</code>\n"
        f"• Service: <code>{esc(ud.get('service_name',''))}</code>\n"
        f"• Tier: <code>{esc(mode_name)}</code> ({cpu} vCPU / {ram})\n"
        f"• Concurrency: <code>{concurrency}</code>, min-instances: 1\n\n"
        "Tap <b>Confirm & Deploy</b> to verify and start."
    )
    keyboard = [
        [InlineKeyboardButton("✅ Confirm & Deploy", callback_data="confirm:yes"),
         InlineKeyboardButton("❌ Cancel", callback_data="confirm:no")],
    ]
    await query.edit_message_text(
        text, parse_mode=ParseMode.HTML,
        reply_markup=InlineKeyboardMarkup(keyboard),
    )
    return STATE_CONFIRM


async def captcha_received(update: Update, context: ContextTypes.DEFAULT_TYPE) -> int:
    text = (update.effective_message.text or "").strip()
    expected = context.user_data.get("captcha_answer")
    asked = context.user_data.get("captcha_asked", 0)
    if expected is None:
        await send_msg(update, context, "❌ No verification pending. Start over with /deploy.")
        return ConversationHandler.END
    if time.time() - asked > 300:
        context.user_data.pop("captcha_answer", None)
        context.user_data.pop("captcha_asked", None)
        await send_msg(update, context, "⏰ Verification expired. Start over with /deploy.")
        return ConversationHandler.END
    try:
        if int(text) != int(expected):
            await send_msg(update, context, "❌ Wrong answer. Verification failed. Start over with /deploy.")
            return ConversationHandler.END
    except ValueError:
        await send_msg(update, context, "❌ Invalid input. Send a number. Start over with /deploy.")
        return ConversationHandler.END

    # Verified — proceed to confirm/deploy
    context.user_data.pop("captcha_answer", None)
    context.user_data.pop("captcha_asked", None)
    return await _do_deploy(update, context)


async def confirm(update: Update, context: ContextTypes.DEFAULT_TYPE) -> int:
    query = update.callback_query
    await query.answer()
    try:
        _, choice = query.data.split(":", 1)
    except ValueError:
        await send_msg(update, context, "❌ Invalid selection. Start over with /deploy.")
        return ConversationHandler.END
    if choice == "no":
        await query.edit_message_text("❌ Deployment cancelled.")
        context.user_data.clear()
        return ConversationHandler.END
    if choice != "yes":
        await send_msg(update, context, "❌ Invalid selection. Start over with /deploy.")
        return ConversationHandler.END

    # Require verification before deploy
    if not context.user_data.get("captcha_verified"):
        question, answer = make_captcha()
        context.user_data["captcha_answer"] = answer
        context.user_data["captcha_asked"] = time.time()
        await query.edit_message_text(
            "🛡️ <b>Verification (antibot)</b>\n\n"
            f"Solve: <code>{question}</code>\nReply with the number only.\n\n"
            "Once verified, deployment will start.",
            parse_mode=ParseMode.HTML,
        )
        return STATE_VERIFY

    return await _do_deploy(update, context)


async def _do_deploy(update: Update, context: ContextTypes.DEFAULT_TYPE) -> int:
    ud = context.user_data
    deploy_project = ud.get("project_hint") or PROJECT_ID or ""
    if not deploy_project:
        await send_msg(
            update, context,
            "❌ No GCP project found. Send a fallback link containing a project "
            "(e.g. qwiklabs-gcp-...) or set GCP_PROJECT_ID.",
        )
        context.user_data.clear()
        return ConversationHandler.END

    region = ud.get("region") or DEFAULT_REGION
    engine = ud.get("engine") or "haproxy"
    image_tag = ud.get("image_tag") or f"{ud.get('service_name','saeka')}-{engine}"
    service_name = ud.get("service_name") or "saeka"

    await send_msg(update, context, "🚀 <b>Starting deployment...</b>\nThis may take several minutes.")

    try:
        deployer = Deployer(deploy_project, region, REPO_DIR)

        # 1. Build
        await send_msg(update, context, "📦 <b>Building container image</b> (Cloud Build)...")
        ok, out = deployer.build_image(engine, image_tag)
        if not ok:
            await send_msg(update, context, f"❌ <b>Build failed</b>\n<pre>{esc(out[-2500:])}</pre>")
            context.user_data.clear()
            return ConversationHandler.END
        await send_msg(update, context, "✅ Image built successfully.")

        # 2. Deploy
        await send_msg(update, context, "🚀 <b>Deploying to Cloud Run</b>...")
        ok, out = deployer.deploy(
            service_name=service_name, image_tag=image_tag, engine=engine,
            cpu=ud.get("cpu", "1"), ram=ud.get("ram", "2Gi"),
            max_instances=ud.get("max_instances", "4"),
            concurrency=ud.get("concurrency", 100),
            ads_mode=ud.get("ads_mode", "noads"),
            min_instances=ud.get("min_instances", 1),
        )
        if not ok:
            await send_msg(update, context, f"❌ <b>Deploy failed</b>\n<pre>{esc(out[-2500:])}</pre>")
            context.user_data.clear()
            return ConversationHandler.END
        await send_msg(update, context, "✅ Deployed to Cloud Run.")

        # 3. Get live URL
        url = deployer.get_service_url(service_name)
        if not url:
            await send_msg(update, context, "⚠️ Deployed but could not fetch service URL.")
            context.user_data.clear()
            return ConversationHandler.END
        clean_host = url.replace("https://", "")
        ud["deployed_host"] = clean_host

        await send_msg(
            update, context,
            f"✅ <b>Live:</b> <code>{esc(url)}</code>\n"
            f"Host: <code>{esc(clean_host)}</code>\n"
            f"Engine: <code>{esc(ud.get('engine_label',''))}</code>\n"
            f"Tier: <code>{esc(ud.get('tier',''))}</code>",
        )

        # 4. Generate client links
        await send_msg(update, context, "🔗 <b>Generating client links</b>...")
        ok, out = deployer.generate_links(clean_host)
        if ok:
            await send_msg(update, context, f"✅ Client links generated.\n<pre>{esc(out[-1800:])}</pre>")
        else:
            await send_msg(update, context, f"⚠️ Link generation issues:\n<pre>{esc(out[-1200:])}</pre>")

        await send_msg(
            update, context,
            f"🎉 <b>Deployment complete!</b>\n"
            f"Live URL: <code>{esc(url)}</code>\n"
            f"Regenerate: <code>./generate-client-links.sh {clean_host}</code>\n"
            f"Send /deploy to deploy again.",
        )
    except Exception as exc:  # noqa: BLE001
        await send_msg(update, context, f"💥 <b>Unexpected error:</b>\n<pre>{esc(str(exc))}</pre>")
    finally:
        context.user_data.clear()
    return ConversationHandler.END


async def cancel(update: Update, context: ContextTypes.DEFAULT_TYPE) -> int:
    await update.effective_message.reply_text("❌ Cancelled.", reply_markup=ReplyKeyboardRemove())
    context.user_data.clear()
    return ConversationHandler.END


async def status(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    user = update.effective_user
    if not is_admin(user.id):
        await update.effective_message.reply_text("🔒 Access denied.")
        return
    text = (
        "📊 <b>Bot status</b>\n"
        f"• Project: <code>{esc(PROJECT_ID) or '(from link)'}</code>\n"
        f"• Default region: <code>{esc(DEFAULT_REGION)}</code>\n"
        f"• Repo dir: <code>{esc(REPO_DIR)}</code>\n"
        f"• Admin mode: {'on' if ADMIN_IDS else 'off (anyone can use)'}\n"
    )
    await send_msg(update, context, text)


async def help_cmd(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    text = (
        "🤖 <b>saeka-tg-bot help</b>\n\n"
        "/deploy — Start a new deployment\n"
        "/cancel — Cancel the current flow\n"
        "/status — Show bot configuration\n"
        "/help — Show this message\n\n"
        "Flow: fallback link → verify → engine → ads → region → name → tier → confirm → deploy → links\n"
        "The bot runs your 4N1 deploy logic on GCP Cloud Run and returns client links."
    )
    await send_msg(update, context, text)


async def unknown(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    await send_msg(update, context, "Send /deploy to start a deployment, or /help for info.")


def main() -> None:
    require_env()
    app = (
        ApplicationBuilder()
        .token(BOT_TOKEN)
        .concurrent_updates(True)
        .build()
    )

    conv = ConversationHandler(
        entry_points=[CommandHandler("deploy", deploy_cmd)],
        states={
            STATE_LINK: [
                MessageHandler(filters.TEXT & ~filters.COMMAND, link_received),
                CommandHandler("skip", skip_link),
                CommandHandler("cancel", cancel),
            ],
            STATE_VERIFY: [
                MessageHandler(filters.TEXT & ~filters.COMMAND, captcha_received),
                CommandHandler("cancel", cancel),
            ],
            STATE_ENGINE: [CallbackQueryHandler(engine_chosen, pattern=r"^eng:")],
            STATE_ADS: [CallbackQueryHandler(ads_chosen, pattern=r"^ads:")],
            STATE_REGION: [CallbackQueryHandler(region_chosen, pattern=r"^reg:")],
            STATE_NAME: [
                MessageHandler(filters.TEXT & ~filters.COMMAND, name_received),
                CommandHandler("cancel", cancel),
            ],
            STATE_TIER: [CallbackQueryHandler(tier_chosen, pattern=r"^tier:")],
            STATE_CONFIRM: [CallbackQueryHandler(confirm, pattern=r"^confirm:")],
        },
        fallbacks=[CommandHandler("cancel", cancel), CommandHandler("start", start)],
        allow_reentry=True,
    )

    app.add_handler(CommandHandler("start", start))
    app.add_handler(CommandHandler("help", help_cmd))
    app.add_handler(CommandHandler("status", status))
    app.add_handler(conv)
    app.add_handler(MessageHandler(filters.ALL, unknown))

    print("saeka-tg-bot starting...")
    app.run_polling(allowed_updates=Update.ALL_TYPES)


if __name__ == "__main__":
    main()
