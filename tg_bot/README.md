# saeka-tg-bot

Telegram bot that deploys the 4N1 FAST DEPLOYER stack to GCP Cloud Run and returns client links.

## What it does

1. User sends `/deploy` (or pastes a fallback host link).
2. Bot walks them through: host → engine → ads mode → region → service name → tier → confirm.
3. Bot runs the deployment non-interactively (Cloud Build → Cloud Run).
4. Bot generates VLESS / Trojan / VMess / Shadowsocks client links and sends them back.

All deployment logic is yours — the bot just drives your existing `deploy.sh` /
`generate-client-links.sh` scripts on GCP.

## Files

| File | Purpose |
|------|---------|
| `bot.py` | Telegram bot (python-telegram-bot, ConversationHandler) |
| `requirements.txt` | Python dependencies |
| `Dockerfile` | Container image (Cloud Run / GCE) |
| `.env.example` | Config template (copy to `.env`) |
| `deploy_bot.sh` | Deploys the bot itself to Cloud Run |
| `README.md` | This file |

## Setup

### 1. Create the bot on Telegram

- Message [@BotFather](https://t.me/botfather) on Telegram.
- `/newbot` → pick a name → get your `BOT_TOKEN`.
- (Optional) `/setcommands` to register `/deploy`, `/cancel`, `/status`, `/help`.

### 2. Configure

```bash
cd tg_bot
cp .env.example .env
# edit .env: set BOT_TOKEN, GCP_PROJECT_ID, GCP_REGION, REPO_DIR
```

`REPO_DIR` must point to the 404script checkout (the one with `deploy.sh`,
`proxies/`, `common/`, `generate-client-links.sh`).

### 3. Deploy the bot to GCP

```bash
gcloud init   # if not already done
source .env   # or export BOT_TOKEN/GCP_PROJECT_ID manually
./deploy_bot.sh
```

The bot's service account needs these roles:
- Cloud Run Admin
- Cloud Build Editor
- Compute Admin (for load balancer, if used)
- Service Account User (on the compute default service account)

### 4. Run locally (for testing)

```bash
pip install -r requirements.txt
cp .env.example .env
# edit .env
python3 bot.py
```

## Deployment flow (what the user sees in Telegram)

```
/deploy
→ (optional) paste a fallback link — e.g. a Qwiklabs / console.cloud.google.com URL:
   https://www.skills.google/google_sso?fallback=https%3A%2F%2Faccounts.google.com%2F...
   The bot reads it for context (best-effort host / project hint). Send /skip to skip.
→ pick engine (HAProxy / Envoy / Caddy / H2O / Traefik / OpenResty)
→ pick ads mode (No ads / Ads)
→ pick region
→ send service name
→ pick tier (Browsing / Streaming / Gaming)
→ confirm (✅ Deploy / ❌ Cancel)
→ bot builds image (Cloud Build) and deploys (Cloud Run)
→ bot fetches the live Cloud Run URL
→ bot generates client links (vless/trojan/vmess/ss) and sends them back
```

The real deploy target is the live Cloud Run service URL obtained after deployment — not the fallback link. The fallback link is context only.

## Security notes

- `BOT_TOKEN` is a secret — never commit `.env`.
- By default any Telegram user can use the bot. Set `ADMIN_IDS` in `.env` to
  restrict to specific users (comma-separated numeric chat IDs).
- The bot provisions real GCP resources that incur billing.
