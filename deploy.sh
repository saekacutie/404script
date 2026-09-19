#!/bin/bash
# ==============================================================================
# 4N1 FAST DEPLOYER v2 - PER-ENGINE EDITION
# ENGINEERED BY SAEKA TOJIRP
# ==============================================================================
# Key change from v1: each proxy engine now lives in its own
# proxies/<engine>/Dockerfile. Choosing HAProxy here builds ONLY HAProxy's
# small Alpine image - Envoy, Caddy, H2O, Traefik and OpenResty are never
# downloaded, compiled, or added to the image. That's what makes builds
# fast now instead of the old single-Dockerfile-with-everything approach.
set -euo pipefail

BOLD='\033[1m'; RESET='\033[0m'
GREEN='\033[1;32m'; RED='\033[1;31m'; CYAN='\033[1;36m'
YELLOW='\033[1;33m'; MAGENTA='\033[1;35m'; WHITE='\033[1;37m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ------------------------------------------------------------------------
# TERMINAL LAYOUT HELPERS
# Everything below is used to render the access screen as a centered
# "page" in the terminal: a bordered box, a random greeting drawn from a
# 100-entry pool (10 openers x 10 closers), a short feature summary, and
# a centered password prompt. Purely cosmetic - the auth logic itself is
# unchanged from v1/v2.
# ------------------------------------------------------------------------
TERM_WIDTH=$(tput cols 2>/dev/null || echo 80)
case "$TERM_WIDTH" in ''|*[!0-9]*) TERM_WIDTH=80;; esac
[ "$TERM_WIDTH" -lt 40 ] && TERM_WIDTH=80

BOX_WIDTH=64
[ "$BOX_WIDTH" -gt $((TERM_WIDTH - 2)) ] && BOX_WIDTH=$((TERM_WIDTH - 2))
BOX_INNER=$((BOX_WIDTH - 4))
BOX_PAD=$(( (TERM_WIDTH - BOX_WIDTH) / 2 ))
[ "$BOX_PAD" -lt 0 ] && BOX_PAD=0
BPAD="$(printf '%*s' "$BOX_PAD" '')"
HRULE="$(printf '─%.0s' $(seq 1 $((BOX_WIDTH - 2))))"

center_line() {
    local text="$1" color="${2:-}"
    local pad=$(( (TERM_WIDTH - ${#text}) / 2 ))
    [ "$pad" -lt 0 ] && pad=0
    if [ -n "$color" ]; then
        printf "%*s${color}%s${RESET}\n" "$pad" "" "$text"
    else
        printf "%*s%s\n" "$pad" "" "$text"
    fi
}

box_top()    { printf "%s${CYAN}┌%s┐${RESET}\n" "$BPAD" "$HRULE"; }
box_bottom() { printf "%s${CYAN}└%s┘${RESET}\n" "$BPAD" "$HRULE"; }
box_sep()    { printf "%s${CYAN}├%s┤${RESET}\n" "$BPAD" "$HRULE"; }
box_blank()  { printf "%s${CYAN}│${RESET}%*s${CYAN}│${RESET}\n" "$BPAD" "$((BOX_WIDTH - 2))" ""; }

box_line() {
    local content="$1" color="${2:-}"
    local clen=${#content}
    [ "$clen" -gt "$BOX_INNER" ] && content="${content:0:$BOX_INNER}" && clen=$BOX_INNER
    local lpad=$(( (BOX_INNER - clen) / 2 ))
    [ "$lpad" -lt 0 ] && lpad=0
    local rpad=$(( BOX_INNER - clen - lpad ))
    if [ -n "$color" ]; then
        printf "%s${CYAN}│${RESET} %*s${color}%s${RESET}%*s ${CYAN}│${RESET}\n" \
            "$BPAD" "$lpad" "" "$content" "$rpad" ""
    else
        printf "%s${CYAN}│${RESET} %*s%s%*s ${CYAN}│${RESET}\n" \
            "$BPAD" "$lpad" "" "$content" "$rpad" ""
    fi
}

GREET_OPEN=(
    "Welcome back,"      "Good to see you,"   "Hello again,"      "Systems nominal,"
    "Standing by,"       "Greetings,"         "All clear,"        "Access point live,"
    "Terminal awake,"    "Ready when you are,"
)
GREET_CLOSE=(
    "operator."          "commander."         "engineer."         "deployer."
    "let's ship something." "the grid awaits."  "your keys, please." "time to deploy."
    "stay sharp."        "no rush."
)
GREET_IDX=$(( RANDOM % 100 ))
GREETING="${GREET_OPEN[$(( GREET_IDX / 10 ))]} ${GREET_CLOSE[$(( GREET_IDX % 10 ))]}"

render_gate_screen() {
    clear
    echo ""
    center_line "4N1 FAST DEPLOYER v2" "${BOLD}${WHITE}"
    center_line "engineered by saeka tojirp" "${MAGENTA}"
    echo ""
    box_top
    box_line "$GREETING" "${GREEN}"
    box_sep
    box_line "PURPOSE" "${BOLD}${CYAN}"
    box_line "Cloud Run reverse-proxy deployer"
    box_line "for VLESS / VMess / Trojan / Shadowsocks"
    box_blank
    box_line "SUPPORTED PROXY ENGINES" "${BOLD}${CYAN}"
    box_line "HAProxy · Envoy · Caddy · Traefik · OpenResty"
    box_blank
    box_line "SUPPORTED TRANSPORTS" "${BOLD}${CYAN}"
    box_line "WebSocket · HTTPUpgrade · XHTTP · gRPC* · H2 · SSH-WS"
    box_line "(*gRPC/H2 unsupported on OpenResty)" "${YELLOW}"
    box_blank
    box_line "This tool provisions real GCP billing resources." "${YELLOW}"
    box_line "Authorized use only." "${YELLOW}"
    box_bottom
    echo ""
}

ALLOWED_HASHES=(
    "2c443ca329d2d85d093b80349ee88cc23169eaec1698dea050920836773fb7ad"
    "718052c0d0866bb03f23d3d4f2488f2aa86c435b9fd658abecbfc4c7abf2de47"
    "57141b782821c05da2e2bcb1e2fa1253bce1a817c0d14f79bc899e1171ad7bb0"
    ""  # slot 4 - paste a hash here, or leave blank to keep this slot unused
    ""  # slot 5
    ""  # slot 6
    ""  # slot 7
    ""  # slot 8
    ""  # slot 9
    ""  # slot 10
)
MAX_ATTEMPTS=3
authorized=0

render_gate_screen
for ((attempt=1; attempt<=MAX_ATTEMPTS; attempt++)); do
    printf "%s" "$BPAD"
    read -r -s -p "$(echo -e "  ${CYAN}${BOLD}ENTER PASSWORD ›${RESET} ")" INPUT_PW
    echo ""
    INPUT_HASH=$(printf '%s' "$INPUT_PW" | sha256sum | cut -d' ' -f1)
    for h in "${ALLOWED_HASHES[@]}"; do
        [ -z "$h" ] && continue
        if [ "$INPUT_HASH" == "$h" ]; then
            authorized=1
            break 2
        fi
    done
    echo ""
    center_line "Incorrect password (${attempt}/${MAX_ATTEMPTS})." "${RED}"
    echo ""
done
if [ "$authorized" -ne 1 ]; then
    echo ""
    center_line "ACCESS DENIED" "${BOLD}${RED}"
    echo ""
    exit 1
fi
clear
echo ""
center_line "ACCESS GRANTED" "${BOLD}${GREEN}"
echo ""

echo -e "  ${BOLD}${WHITE}4N1 FAST DEPLOYER v2 (PER-ENGINE)${RESET}"
echo -e "  ${MAGENTA}ENGINEERED BY SAEKA TOJIRP${RESET}"
echo ""

PROJECT_ID=$(gcloud config get-value project 2>/dev/null | tr -d '[:space:]')
if [ -z "$PROJECT_ID" ]; then
    echo -e "  ${RED}ERROR: No active GCP project detected. Please run 'gcloud init'.${RESET}"
    exit 1
fi
echo -e "  ${CYAN}PROJECT: ${GREEN}${PROJECT_ID}${RESET}"
echo ""

echo -e "  ${CYAN}==================================================${RESET}"
echo -e "  ${GREEN}              CHOOSE PROXY ENGINE${RESET}"
echo -e "  ${CYAN}==================================================${RESET}"
echo -e "  ${YELLOW}1) HAProxy    - full protocol support incl. gRPC (recommended)${RESET}"
echo -e "  ${YELLOW}2) Envoy      - full protocol support incl. gRPC (fast & stable)${RESET}"
echo -e "  ${YELLOW}3) Caddy      - full protocol support incl. gRPC (fast & stable)${RESET}"
echo -e "  ${YELLOW}4) Traefik    - full protocol support incl. gRPC (recommended)${RESET}"
echo -e "  ${YELLOW}5) OpenResty  - WS/HTTPUpgrade/XHTTP/SSH-WS only, NO gRPC/H2 (nginx limitation)${RESET}"
echo ""
read -r -p "$(echo -e "  ${CYAN}SELECT PROXY ENGINE [1-6] (Default 1): ${RESET}")" ENGINE_CHOICE

case "$ENGINE_CHOICE" in
    2) ENGINE="Envoy";      PROXY_ENV="envoy";;
    3) ENGINE="Caddy";      PROXY_ENV="caddy";;
    4) ENGINE="Traefik";    PROXY_ENV="traefik";;
    5) ENGINE="OpenResty";  PROXY_ENV="openresty";;
    *) ENGINE="HAProxy";    PROXY_ENV="haproxy";;
esac
DOCKERFILE="proxies/${PROXY_ENV}/Dockerfile"
if [ ! -f "$DOCKERFILE" ]; then
    echo -e "  ${RED}ERROR: ${DOCKERFILE} not found - repo layout looks wrong.${RESET}"
    exit 1
fi
echo -e "  ${GREEN}SELECTED PROXY ENGINE: ${ENGINE}${RESET}"
if [ "$PROXY_ENV" == "openresty" ]; then
    echo -e "  ${YELLOW}Note: gRPC/H2 endpoints will return 501 on this engine - nginx cannot${RESET}"
    echo -e "  ${YELLOW}multiplex HTTP/1.1 and cleartext HTTP/2 on one port. Pick another${RESET}"
    echo -e "  ${YELLOW}engine if you need those transports.${RESET}"
fi
echo ""

echo -e "  ${CYAN}==================================================${RESET}"
echo -e "  ${GREEN}                  ADS MODE${RESET}"
echo -e "  ${CYAN}==================================================${RESET}"
echo -e "  ${YELLOW}1) No ads   - blocks known ad/tracker domains via DNS${RESET}"
echo -e "  ${YELLOW}2) Ads      - normal DNS, no blocking${RESET}"
read -r -p "$(echo -e "  ${CYAN}CHOICE [1-2] (Default 1): ${RESET}")" ADS_CHOICE
case "$ADS_CHOICE" in
    2) ADS_MODE="ads";;
    *) ADS_MODE="noads";;
esac
echo -e "  ${GREEN}ADS MODE: ${ADS_MODE}${RESET}"
echo ""

# ------------------------------------------------------------------------
# SSH TUNNEL USERS (SSH-over-WS at /saeka-ssh)
# Provisioned at CONTAINER START, not baked into the image - the same
# pattern ADS_MODE already uses. Passwords are auto-generated here (never
# typed, never logged) unless you choose to set your own. This builds an
# SSH_USERS env var that entrypoint.sh reads to create forwarding-only
# accounts (no shell, no TTY - just `ssh -D` tunnel endpoints).
# ------------------------------------------------------------------------
echo -e "  ${CYAN}==================================================${RESET}"
echo -e "  ${GREEN}           SSH TUNNEL USERS (SSH-over-WS)${RESET}"
echo -e "  ${CYAN}==================================================${RESET}"
echo -e "  ${YELLOW}Adds forwarding-only SSH accounts at /saeka-ssh - no shell, no${RESET}"
echo -e "  ${YELLOW}login, just a SOCKS tunnel endpoint (ssh -D). Needs ws_bridge.py${RESET}"
echo -e "  ${YELLOW}client-side, since plain ssh doesn't speak WebSocket.${RESET}"
echo ""

SSH_USER_LIST=()
if [ -x "$(command -v openssl)" ]; then
    GEN_PW() { openssl rand -base64 12 | tr -dc 'A-Za-z0-9' | head -c16; }
else
    GEN_PW() { < /dev/urandom tr -dc 'A-Za-z0-9' | head -c16; }
fi

read -r -p "$(echo -e "  ${CYAN}Add an SSH tunnel user? [y/N]: ${RESET}")" ADD_SSH
while [[ "$ADD_SSH" =~ ^[Yy] ]]; do
    read -r -p "$(echo -e "  ${CYAN}Username [saeka]: ${RESET}")" SSH_UNAME
    SSH_UNAME=${SSH_UNAME:-saeka}
    # Strip characters that would break the user:pass / comma / @ delimiter
    # scheme below (also keeps sshd/useradd happy with the result).
    SSH_UNAME=$(printf '%s' "$SSH_UNAME" | tr -dc 'A-Za-z0-9_-')
    read -r -p "$(echo -e "  ${CYAN}Password (blank = auto-generate): ${RESET}")" SSH_PW
    if [ -z "$SSH_PW" ]; then
        SSH_PW=$(GEN_PW)
        echo -e "  ${GREEN}Generated password for ${SSH_UNAME}: ${SSH_PW}${RESET}"
        echo -e "  ${YELLOW}(shown once - write it down now)${RESET}"
    fi
    SSH_USER_LIST+=("${SSH_UNAME}:${SSH_PW}")
    echo ""
    read -r -p "$(echo -e "  ${CYAN}Add another? [y/N]: ${RESET}")" ADD_SSH
done

SSH_USERS_CSV=""
if [ "${#SSH_USER_LIST[@]}" -gt 0 ]; then
    SSH_USERS_CSV=$(IFS=,; echo "${SSH_USER_LIST[*]}")
    echo -e "  ${GREEN}${#SSH_USER_LIST[@]} SSH tunnel user(s) configured.${RESET}"
else
    echo -e "  ${YELLOW}No SSH tunnel users added - /saeka-ssh will run but nothing can authenticate.${RESET}"
fi
echo ""

if [ -f "./regions.sh" ]; then
    source ./regions.sh
else
    echo -e "  ${RED}ERROR: regions.sh not found. Please ensure it is in the same directory.${RESET}"
    exit 1
fi

read -r -p "$(echo -e "  ${CYAN}SERVICE NAME [saeka]: ${RESET}")" INPUT_NAME
SERVICE_NAME=${INPUT_NAME:-saeka}
IMAGE_TAG="${SERVICE_NAME}-${PROXY_ENV}"

echo ""
echo -e "  ${CYAN}SELECT MODE:${RESET}"
echo -e "  ${YELLOW}1) BROWSING      (1 vCPU / 2Gi  RAM)${RESET}"
echo -e "  ${YELLOW}2) STREAMING     (2 vCPU / 4Gi  RAM)${RESET}"
echo -e "  ${YELLOW}3) GAMING        (4 vCPU / 8Gi  RAM)${RESET}"
echo -e "  ${YELLOW}4) CUSTOM${RESET}"
echo ""
read -r -p "$(echo -e "  ${CYAN}CHOICE: ${RESET}")" MODE_CHOICE

case "$MODE_CHOICE" in
    2) CPU="2"; RAM="4Gi"; MODE="STREAMING"; MAX_INSTANCES="4";;
    3) CPU="4"; RAM="8Gi"; MODE="GAMING";    MAX_INSTANCES="4";;
    4)
        read -r -p "$(echo -e "  ${CYAN}CPU (1/2/4): ${RESET}")" CPU
        read -r -p "$(echo -e "  ${CYAN}RAM (2Gi/4Gi/8Gi): ${RESET}")" RAM
        read -r -p "$(echo -e "  ${CYAN}MAX INSTANCES (1/2/4): ${RESET}")" MAX_INSTANCES
        MODE="CUSTOM"
        ;;
    *) CPU="1"; RAM="2Gi"; MODE="BROWSING"; MAX_INSTANCES="4";;
esac

run_quiet() {
    local label="$1" logfile="$2"
    shift 2
    : > "$logfile"
    "$@" >"$logfile" 2>&1 &
    local pid=$!
    local spin='|/-\'
    local i=0
    while kill -0 "$pid" 2>/dev/null; do
        i=$(( (i + 1) % 4 ))
        printf "\r  ${CYAN}%s...${RESET} %s" "$label" "${spin:$i:1}"
        sleep 0.2
    done
    wait "$pid"
    local status=$?
    if [ "$status" -eq 0 ]; then
        printf "\r  ${GREEN}%s... OK${RESET}          \n" "$label"
        rm -f "$logfile"
        return 0
    else
        printf "\r  ${RED}%s... FAILED${RESET}          \n" "$label"
        echo -e "  ${RED}Last 30 log lines (full log kept at ${logfile}):${RESET}"
        tail -n 30 "$logfile"
        return "$status"
    fi
}

CB_CONFIG=$(mktemp)
cat > "$CB_CONFIG" <<YAML
steps:
  - name: 'gcr.io/cloud-builders/docker'
    args: ['build', '-f', '${DOCKERFILE}', '-t', 'gcr.io/${PROJECT_ID}/${IMAGE_TAG}', '.']
images:
  - 'gcr.io/${PROJECT_ID}/${IMAGE_TAG}'
YAML

if ! run_quiet "Building ${ENGINE} image" build.log \
        gcloud builds submit . --config "$CB_CONFIG" --project="$PROJECT_ID"; then
    rm -f "$CB_CONFIG"
    exit 1
fi
rm -f "$CB_CONFIG"

if [ -n "$SSH_USERS_CSV" ]; then
    # SSH_USERS_CSV already contains both ',' (between users) and ':'
    # (inside each user:pass pair), so gcloud's normal comma-delimited
    # --set-env-vars can't carry it safely alongside ADS_MODE. The
    # "^SEP^" prefix switches the delimiter for the WHOLE value to
    # something that appears in neither var - '@' never shows up in
    # ADS_MODE, in a generated password (alphanumeric only), or in any
    # reasonable username.
    ENV_VARS="^@^ADS_MODE=${ADS_MODE}@SSH_USERS=${SSH_USERS_CSV}"
else
    ENV_VARS="ADS_MODE=${ADS_MODE}"
fi

deploy_attempt() {
    local cpu="$1" mem="$2" maxi="$3"
    shift 3
    gcloud run deploy "$SERVICE_NAME" \
        --image "gcr.io/${PROJECT_ID}/${IMAGE_TAG}" \
        --platform managed --region "$REGION" \
        --cpu "$cpu" --memory "$mem" --port 8080 \
        --max-instances "$maxi" \
        --timeout 3600 --allow-unauthenticated --project="$PROJECT_ID" \
        --set-env-vars "$ENV_VARS" \
        --quiet "$@"
}

echo ""
if run_quiet "Deploying to Cloud Run in ${REGION} (full tier)" deploy.log \
        deploy_attempt "$CPU" "$RAM" "$MAX_INSTANCES" --concurrency 1000 --cpu-boost --no-cpu-throttling --min-instances 1; then
    DEPLOY_NOTE="full stability tuning (always-on CPU)"
elif run_quiet "Deploying to Cloud Run in ${REGION} (reduced tier)" deploy.log \
        deploy_attempt 1 2Gi 2 --concurrency 500 --no-cpu-throttling --min-instances 1; then
    DEPLOY_NOTE="reduced tier - project quota couldn't fit ${MODE}"
elif run_quiet "Deploying to Cloud Run in ${REGION} (minimal tier)" deploy.log \
        deploy_attempt 1 2Gi 2 --concurrency 250 --min-instances 0; then
    DEPLOY_NOTE="minimal tier, no always-on CPU - expect cold-start delay after idle"
else
    echo -e "  ${RED}DEPLOYMENT FAILED on every tier.${RESET}"
    exit 1
fi

SERVICE_URL=$(gcloud run services describe "$SERVICE_NAME" --region "$REGION" --project="$PROJECT_ID" --format='value(status.url)' 2>/dev/null)
CLEAN_HOST=$(echo "$SERVICE_URL" | sed 's|https://||')

echo ""
echo -e "  ${GREEN}DEPLOYED SUCCESSFULLY WITH ${ENGINE}${RESET}"
echo ""
echo -e "  ${CYAN}RAW HOST   ${GREEN}https://${CLEAN_HOST}${RESET}"
echo -e "  ${CYAN}TIER       ${GREEN}${DEPLOY_NOTE}${RESET}"
echo -e "  ${CYAN}ENGINE     ${GREEN}${ENGINE}${RESET}"
echo -e "  ${CYAN}ADS MODE   ${GREEN}${ADS_MODE}${RESET}"
echo -e "  ${CYAN}CPU / RAM  ${GREEN}${CPU} vCPU / ${RAM}${RESET}"
echo ""
echo -e "  ${YELLOW}------------------------------------------------------------${RESET}"
echo -e "  ${CYAN}                    PATHS & PROTOCOLS${RESET}"
echo -e "  ${YELLOW}------------------------------------------------------------${RESET}"
echo -e "  ${GREEN}VLESS${RESET}        | WS: /vless-saeka   | HU: /vless-saeka-hu   | XH: /vless-saeka-xh   | gRPC: /vless-saeka-grpc   | H2: /vless-saeka-h2"
echo -e "  ${GREEN}VMess${RESET}        | WS: /vmess-saeka   | HU: /vmess-saeka-hu   | XH: /vmess-saeka-xh   | gRPC: /vmess-saeka-grpc   | H2: /vmess-saeka-h2"
echo -e "  ${GREEN}TROJAN${RESET}       | WS: /saeka-tojirp  | HU: /saeka-tojirp-hu  | XH: /saeka-tojirp-xh  | gRPC: /saeka-tojirp-grpc  | H2: /saeka-tojirp-h2"
echo -e "  ${GREEN}Shadowsocks${RESET}  | WS: /ss-saeka      | HU: /ss-saeka-hu      | XH: /ss-saeka-xh      | gRPC: /ss-saeka-grpc      | H2: /ss-saeka-h2"
echo -e "  ${YELLOW}------------------------------------------------------------${RESET}"
if [ -n "$SSH_USERS_CSV" ]; then
    echo -e "  ${GREEN}SSH-WS${RESET}       | /saeka-ssh  (needs ws_bridge.py client-side - plain ssh can't speak WS)"
    echo -e "  ${CYAN}  python3 ws_bridge.py --local-port 2222 --remote wss://${CLEAN_HOST}/saeka-ssh${RESET}"
    echo -e "  ${CYAN}  ssh -p 2222 -o UserKnownHostsFile=/dev/null <user>@127.0.0.1${RESET}"
fi
echo -e "  ${YELLOW}------------------------------------------------------------${RESET}"
if [ "$PROXY_ENV" == "openresty" ]; then
    echo -e "  ${YELLOW}gRPC/H2 paths above will return 501 on OpenResty - see engine note.${RESET}"
fi
echo ""

FINAL_HOST="$CLEAN_HOST"

echo -e "  ${CYAN}==================================================${RESET}"
echo -e "  ${GREEN}       CUSTOM DOMAIN & UNIVERSAL SNI MANAGER${RESET}"
echo -e "  ${CYAN}==================================================${RESET}"
echo -e "  ${YELLOW}Google Managed Certs take 15-60 mins. To bypass the wait, you have options:${RESET}"
echo -e "  ${WHITE}1) Enter a Domain : ${YELLOW}Auto-generates Google cert (Stacks all past domains. Takes up to 1 hr)${RESET}"
echo -e "  ${WHITE}2) Type UNIVERSAL : ${YELLOW}Instant self-signed cert. (Use with Cloudflare 'Full' SSL for instant valid cert!)${RESET}"
echo -e "  ${WHITE}3) Type LOCAL     : ${YELLOW}Instantly uploads your own 'cert.pem' and 'key.pem' from this folder.${RESET}"
echo ""
read -r -p "$(echo -e "  ${CYAN}Input (Domain / UNIVERSAL / LOCAL) or blank to skip: ${RESET}")" LB_INPUT

if [ -n "$LB_INPUT" ] && [ "$LB_INPUT" != "UNIVERSAL" ] && [ "$LB_INPUT" != "LOCAL" ]; then
    echo -e "  ${CYAN}Checking that ${LB_INPUT} actually resolves before touching the LB...${RESET}"
    DOMAIN_UP=0
    for _ in $(seq 1 3); do
        HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 6 "https://${LB_INPUT}" 2>/dev/null || echo "000")
        RESOLVES=$(getent ahostsv4 "$LB_INPUT" 2>/dev/null | head -n1)
        if [ -n "$RESOLVES" ] || [ "$HTTP_CODE" != "000" ]; then
            DOMAIN_UP=1
            break
        fi
        sleep 2
    done
    if [ "$DOMAIN_UP" -eq 0 ]; then
        echo -e "  ${RED}${LB_INPUT} isn't resolving / responding right now.${RESET}"
        read -r -p "$(echo -e "  ${CYAN}Use it anyway? [y/N]: ${RESET}")" FORCE_DOMAIN
        if [[ ! "$FORCE_DOMAIN" =~ ^[Yy] ]]; then
            LB_INPUT=""
            echo -e "  ${YELLOW}Skipping the domain/LB step.${RESET}"
        fi
    else
        echo -e "  ${GREEN}${LB_INPUT} responds - proceeding.${RESET}"
    fi
fi

FINAL_HOST="$CLEAN_HOST"
if [ -n "$LB_INPUT" ]; then
    IP_NAME="${SERVICE_NAME}-ip"
    NEG_NAME="${SERVICE_NAME}-neg"
    BACKEND_NAME="${SERVICE_NAME}-backend"
    URLMAP_NAME="${SERVICE_NAME}-urlmap"
    HTTPS_PROXY_NAME="${SERVICE_NAME}-https-proxy"
    FWD_RULE_NAME="${SERVICE_NAME}-https-fwd"
    lb_setup_failed=0

    gcloud services enable compute.googleapis.com --project="$PROJECT_ID" >/dev/null 2>&1 || true

    if ! gcloud compute addresses describe "$IP_NAME" --global --project="$PROJECT_ID" >/dev/null 2>&1; then
        run_quiet "Reserving static IP" lb.log \
            gcloud compute addresses create "$IP_NAME" --global --project="$PROJECT_ID" || lb_setup_failed=1
    fi
    STATIC_IP=$(gcloud compute addresses describe "$IP_NAME" --global --project="$PROJECT_ID" --format='value(address)' 2>/dev/null)

    if ! gcloud compute network-endpoint-groups describe "$NEG_NAME" --region="$REGION" --project="$PROJECT_ID" >/dev/null 2>&1; then
        run_quiet "Creating serverless NEG" lb.log \
            gcloud compute network-endpoint-groups create "$NEG_NAME" \
                --region="$REGION" --network-endpoint-type=serverless \
                --cloud-run-service="$SERVICE_NAME" --project="$PROJECT_ID" || lb_setup_failed=1
    fi

    if ! gcloud compute backend-services describe "$BACKEND_NAME" --global --project="$PROJECT_ID" >/dev/null 2>&1; then
        run_quiet "Creating backend service" lb.log \
            gcloud compute backend-services create "$BACKEND_NAME" --global --project="$PROJECT_ID" || lb_setup_failed=1
        run_quiet "Attaching NEG to backend" lb.log \
            gcloud compute backend-services add-backend "$BACKEND_NAME" --global \
                --network-endpoint-group="$NEG_NAME" --network-endpoint-group-region="$REGION" \
                --project="$PROJECT_ID" || lb_setup_failed=1
    fi

    if ! gcloud compute url-maps describe "$URLMAP_NAME" --global --project="$PROJECT_ID" >/dev/null 2>&1; then
        run_quiet "Creating URL map" lb.log \
            gcloud compute url-maps create "$URLMAP_NAME" --default-service="$BACKEND_NAME" \
                --global --project="$PROJECT_ID" || lb_setup_failed=1
    fi

    CERT_TEMP="${SERVICE_NAME}-tmp-$(date +%s)"
    CERT_MANAGED="${SERVICE_NAME}-mng-$(date +%s)"

    if [ "$LB_INPUT" == "UNIVERSAL" ]; then
        echo -e "  ${CYAN}Provisioning Universal SNI (Self-Signed) Certificate...${RESET}"
        run_quiet "Generating self-signed cert" lb.log \
            openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
            -keyout key.pem -out cert.pem -subj "/CN=cloudfront.net" 2>/dev/null

        run_quiet "Uploading self-managed cert to GCP" lb.log \
            gcloud compute ssl-certificates create "$CERT_TEMP" \
                --certificate=cert.pem --private-key=key.pem \
                --global --project="$PROJECT_ID" || lb_setup_failed=1

        rm -f key.pem cert.pem
        FINAL_CERTS="$CERT_TEMP"
        FINAL_HOST="$STATIC_IP"
    elif [ "$LB_INPUT" == "LOCAL" ]; then
        if [ ! -f cert.pem ] || [ ! -f key.pem ]; then
            echo -e "  ${RED}cert.pem / key.pem not found in ${SCRIPT_DIR} - aborting LB step.${RESET}"
            lb_setup_failed=1
        else
            run_quiet "Uploading your cert.pem/key.pem to GCP" lb.log \
                gcloud compute ssl-certificates create "$CERT_TEMP" \
                    --certificate=cert.pem --private-key=key.pem \
                    --global --project="$PROJECT_ID" || lb_setup_failed=1
            FINAL_CERTS="$CERT_TEMP"
            FINAL_HOST="$STATIC_IP"
        fi
    else
        echo -e "  ${CYAN}Applying Hybrid SSL (Instant Temp + Background Managed)...${RESET}"
        DOMAINS_FILE="${SCRIPT_DIR}/.domains-${SERVICE_NAME}.list"
        touch "$DOMAINS_FILE"
        grep -qxF "$LB_INPUT" "$DOMAINS_FILE" || echo "$LB_INPUT" >> "$DOMAINS_FILE"
        DOMAINS_CSV=$(paste -sd, "$DOMAINS_FILE")

        openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
            -keyout key.pem -out cert.pem -subj "/CN=${LB_INPUT}" 2>/dev/null
        run_quiet "Uploading instant temporary cert" lb.log \
            gcloud compute ssl-certificates create "$CERT_TEMP" \
                --certificate=cert.pem --private-key=key.pem \
                --global --project="$PROJECT_ID" || lb_setup_failed=1
        rm -f key.pem cert.pem

        run_quiet "Requesting real managed cert for ${DOMAINS_CSV}" lb.log \
            gcloud compute ssl-certificates create "$CERT_MANAGED" \
                --domains="$DOMAINS_CSV" --global --project="$PROJECT_ID" || lb_setup_failed=1

        FINAL_CERTS="${CERT_TEMP},${CERT_MANAGED}"
        FINAL_HOST="$LB_INPUT"
    fi

    if ! gcloud compute target-https-proxies describe "$HTTPS_PROXY_NAME" --global --project="$PROJECT_ID" >/dev/null 2>&1; then
        run_quiet "Creating HTTPS proxy with cert(s)" lb.log \
            gcloud compute target-https-proxies create "$HTTPS_PROXY_NAME" \
                --url-map="$URLMAP_NAME" --ssl-certificates="$FINAL_CERTS" \
                --global --project="$PROJECT_ID" || lb_setup_failed=1
    else
        run_quiet "Repointing HTTPS proxy to new cert(s)" lb.log \
            gcloud compute target-https-proxies update "$HTTPS_PROXY_NAME" \
                --ssl-certificates="$FINAL_CERTS" --global --project="$PROJECT_ID" || lb_setup_failed=1
    fi

    if ! gcloud compute forwarding-rules describe "$FWD_RULE_NAME" --global --project="$PROJECT_ID" >/dev/null 2>&1; then
        run_quiet "Creating forwarding rule" lb.log \
            gcloud compute forwarding-rules create "$FWD_RULE_NAME" \
                --global --target-https-proxy="$HTTPS_PROXY_NAME" \
                --address="$IP_NAME" --ports=443 --project="$PROJECT_ID" || lb_setup_failed=1
    fi

    if [ "$lb_setup_failed" -eq 0 ]; then
        echo ""
        echo -e "  ${GREEN}Load Balancer ready.${RESET}"
        echo -e "  ${CYAN}STATIC IP: ${GREEN}${STATIC_IP}${RESET}"
        if [ "$LB_INPUT" == "UNIVERSAL" ]; then
            echo -e "  ${YELLOW}Universal Mode active. Use ANY domain or IP directly.${RESET}"
            echo -e "  ${YELLOW}Client apps MUST have 'allowInsecure' set to true - that also means${RESET}"
            echo -e "  ${YELLOW}TLS validation is off entirely, so this connection can be intercepted${RESET}"
            echo -e "  ${YELLOW}by anyone on the network path. Fine for testing, not for real traffic.${RESET}"
        elif [ "$LB_INPUT" == "LOCAL" ]; then
            echo -e "  ${YELLOW}Using your own cert.pem/key.pem. Point DNS at the static IP above.${RESET}"
        else
            echo -e "  ${CYAN}Domains currently on the cert: ${GREEN}${DOMAINS_CSV}${RESET}"
            echo -e "  ${YELLOW}1. Point DNS A records for all these domains to the static IP.${RESET}"
            echo -e "  ${YELLOW}2. You can connect IMMEDIATELY by setting 'allowInsecure: true' in your app${RESET}"
            echo -e "  ${YELLOW}   (same MITM caveat as Universal Mode above, until the real cert lands).${RESET}"
            echo -e "  ${YELLOW}3. In ~60 mins, Google will finish the real cert. You can then disable 'allowInsecure'.${RESET}"
        fi
    else
        echo -e "  ${RED}Load balancer setup hit an error above - falling back to the raw Cloud Run host.${RESET}"
    fi
    rm -f lb.log
    echo ""
fi

echo -e "  ${CYAN}Generate client links / outbound JSON with:${RESET}"
echo -e "  ${GREEN}./generate-client-links.sh ${FINAL_HOST}${RESET}"
echo ""

rm -f build.log deploy.log lb.log
echo -e "  ${GREEN}Deployer session complete.${RESET}"
