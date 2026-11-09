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

# Region can be preset: --region, XGCPX_REGION, CLOUDSDK_COMPUTE_REGION, or
# `gcloud config set compute/region`. Otherwise regions.sh shows a live menu.
REGION_HINT="${XGCPX_REGION:-${CLOUDSDK_COMPUTE_REGION:-}}"
REGION_HINT_SOURCE=""
while [ $# -gt 0 ]; do
    case "$1" in
        --region)   [ $# -ge 2 ] || { echo "--region requires a region name." >&2; exit 1; }
                    REGION_HINT="$2"; REGION_HINT_SOURCE="--region"; shift 2;;
        --region=*) REGION_HINT="${1#--region=}"; REGION_HINT_SOURCE="--region"; shift;;
        -h|--help)  echo "Usage: $0 [--region REGION]"; exit 0;;
        *)          echo "Unknown argument: $1 (use --help)" >&2; exit 1;;
    esac
done

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
    box_line "HAProxy · Envoy · Caddy · H2O · Traefik · OpenResty"
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
echo -e "  ${YELLOW}4) H2O        - full protocol support incl. gRPC${RESET}"
echo -e "  ${YELLOW}5) Traefik    - full protocol support incl. gRPC (recommended)${RESET}"
echo -e "  ${YELLOW}6) OpenResty  - WS/HTTPUpgrade/XHTTP/SSH-WS only, NO gRPC/H2 (nginx limitation)${RESET}"
echo -e "  ${YELLOW}7) SSH        - standalone SSH-over-WS (+ UDPGW), not the VLESS/etc stack${RESET}"
echo -e "  ${YELLOW}8) OVPN       - standalone WS relay to a REAL OpenVPN server on a VM${RESET}"
echo ""
read -r -p "$(echo -e "  ${CYAN}SELECT PROXY ENGINE [1-8] (Default 1): ${RESET}")" ENGINE_CHOICE

STANDALONE=0
case "$ENGINE_CHOICE" in
    2) ENGINE="Envoy";      PROXY_ENV="envoy";;
    3) ENGINE="Caddy";      PROXY_ENV="caddy";;
    4) ENGINE="H2O";        PROXY_ENV="h2o";;
    5) ENGINE="Traefik";    PROXY_ENV="traefik";;
    6) ENGINE="OpenResty";  PROXY_ENV="openresty";;
    7) ENGINE="SSH Gateway"; PROXY_ENV="ssh";        STANDALONE=1;;
    8) ENGINE="OVPN Relay";  PROXY_ENV="ovpn-relay"; STANDALONE=1;;
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

PANEL_KEY="${PANEL_KEY:-}"
PANEL_BUCKET=""
ADS_MODE="n/a"
if [ "$STANDALONE" -eq 0 ]; then
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
fi

if [ -f "./regions.sh" ]; then
    source ./regions.sh
else
    echo -e "  ${RED}ERROR: regions.sh not found. Please ensure it is in the same directory.${RESET}"
    exit 1
fi

warn() { echo -e "  ${YELLOW}$*${RESET}"; }

read -r -p "$(echo -e "  ${CYAN}SERVICE NAME [saeka]: ${RESET}")" INPUT_NAME
SERVICE_NAME=${INPUT_NAME:-saeka}
# Cloud Run names: lowercase letters, digits and hyphens, must start with a
# letter, max 49 chars. Anything else (e.g. "My_Service") fails the deploy.
CLEAN_NAME=$(printf '%s' "$SERVICE_NAME" | tr 'A-Z_' 'a-z-' | tr -cd 'a-z0-9-' | sed 's/^[^a-z]*//' | cut -c1-49 | sed 's/-*$//')
[ -n "$CLEAN_NAME" ] || CLEAN_NAME="saeka"
if [ "$CLEAN_NAME" != "$SERVICE_NAME" ]; then
    warn "Service name '${SERVICE_NAME}' isn't valid for Cloud Run; using '${CLEAN_NAME}'."
fi
SERVICE_NAME="$CLEAN_NAME"
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
        case "$CPU" in 1|2|4|6|8) ;; *) warn "CPU '${CPU}' isn't valid (use 1/2/4); using 1."; CPU="1";; esac
        [[ "$RAM" =~ ^[0-9]+(Mi|Gi)$ ]] || { warn "RAM '${RAM}' isn't valid (use e.g. 2Gi); using 2Gi."; RAM="2Gi"; }
        if ! [[ "$MAX_INSTANCES" =~ ^[0-9]+$ ]] || [ "$MAX_INSTANCES" -lt 1 ]; then
            warn "MAX INSTANCES '${MAX_INSTANCES}' isn't valid; using 4."; MAX_INSTANCES="4"
        fi
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

# ------------------------------------------------------------------------
# PREFLIGHT
#   1. Enable the APIs this script needs. A fresh project has none of them on,
#      and gcloud can't prompt for it inside run_quiet (stdin is detached), so
#      the build used to die with a bare "API not enabled" error.
#   2. Keep images in Artifact Registry. Container Registry (gcr.io) is shut
#      down; a project that never used it rejects the push with
#      "createOnPush" permission errors.
#   3. Know the runtime service account, so the panel bucket grant goes to the
#      identity the service really runs as.
# ------------------------------------------------------------------------
PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)' 2>/dev/null | tr -d '[:space:]' || true)
DEFAULT_SA=""
[ -n "$PROJECT_NUMBER" ] && DEFAULT_SA="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"

if ! run_quiet "Enabling required Google APIs" preflight.log \
        gcloud services enable run.googleapis.com cloudbuild.googleapis.com \
            artifactregistry.googleapis.com storage.googleapis.com --project="$PROJECT_ID"; then
    warn "Couldn't enable one or more APIs (they may already be on, or this account may not be allowed to). Continuing."
fi
rm -f preflight.log

AR_REPO="saeka"
IMAGE_URI="${REGION}-docker.pkg.dev/${PROJECT_ID}/${AR_REPO}/${IMAGE_TAG}"

ensure_ar_repo() {
    local out attempt
    for attempt in 1 2 3; do
        gcloud artifacts repositories describe "$AR_REPO" --location="$REGION" --project="$PROJECT_ID" >/dev/null 2>&1 && return 0
        if out=$(gcloud artifacts repositories create "$AR_REPO" --repository-format=docker \
                    --location="$REGION" --description="404script images" --project="$PROJECT_ID" 2>&1); then
            return 0
        fi
        printf '%s' "$out" | grep -qi 'already exists' && return 0
        sleep 5     # a just-enabled API can take a few seconds to be usable
    done
    printf '%s\n' "$out" | tail -n 4 >&2
    return 1
}

echo -e "  ${CYAN}Preparing Artifact Registry (${AR_REPO} in ${REGION})...${RESET}"
if ensure_ar_repo; then
    echo -e "  ${GREEN}Image repository ready.${RESET}"
else
    IMAGE_URI="gcr.io/${PROJECT_ID}/${IMAGE_TAG}"
    warn "Couldn't create an Artifact Registry repo; falling back to ${IMAGE_URI}."
fi
echo ""

# Cloud Build now runs as the project's default compute service account, which
# a new project/org may not have given build rights. Only touched if a build
# actually fails with a permission error (see below), so the normal path stays fast.
heal_build_permissions() {
    [ -n "$PROJECT_NUMBER" ] || return 1
    local granted=0 sa role
    for sa in "$DEFAULT_SA" "${PROJECT_NUMBER}@cloudbuild.gserviceaccount.com"; do
        for role in roles/cloudbuild.builds.builder roles/artifactregistry.writer \
                    roles/logging.logWriter roles/storage.objectViewer; do
            if gcloud projects add-iam-policy-binding "$PROJECT_ID" \
                    --member="serviceAccount:${sa}" --role="$role" --condition=None --quiet >/dev/null 2>&1; then
                granted=$((granted + 1))
            fi
        done
    done
    if [ "$granted" -eq 0 ]; then
        warn "This account isn't allowed to change project IAM, so Cloud Build permissions can't be fixed from here."
        warn "A project owner can run:"
        warn "  gcloud projects add-iam-policy-binding ${PROJECT_ID} --member=serviceAccount:${DEFAULT_SA} --role=roles/cloudbuild.builds.builder"
        return 1
    fi
    echo -e "  ${GREEN}Granted Cloud Build build/push rights (${granted} bindings).${RESET}"
    return 0
}

CB_CONFIG=$(mktemp)
cat > "$CB_CONFIG" <<YAML
timeout: '1200s'
steps:
  - name: 'gcr.io/cloud-builders/docker'
    args: ['build', '-f', '${DOCKERFILE}', '-t', '${IMAGE_URI}', '.']
images:
  - '${IMAGE_URI}'
options:
  logging: CLOUD_LOGGING_ONLY
YAML

build_image() { gcloud builds submit . --config "$CB_CONFIG" --project="$PROJECT_ID"; }

if ! run_quiet "Building ${ENGINE} image" build.log build_image; then
    if grep -qiE 'permission|denied|forbidden|not have access|service account|\<iam\>' build.log \
            && heal_build_permissions; then
        echo -e "  ${YELLOW}Retrying the build once (IAM changes take a few seconds to apply)...${RESET}"
        sleep 20
        if ! run_quiet "Building ${ENGINE} image (retry)" build.log build_image; then
            rm -f "$CB_CONFIG"
            exit 1
        fi
    else
        rm -f "$CB_CONFIG"
        exit 1
    fi
fi
rm -f "$CB_CONFIG"

SSH_USERS_CSV=""
if [ "$PROXY_ENV" == "ssh" ]; then
    echo -e "  ${CYAN}==================================================${RESET}"
    echo -e "  ${GREEN}           SSH GATEWAY - TUNNEL USERS${RESET}"
    echo -e "  ${CYAN}==================================================${RESET}"
    echo -e "  ${YELLOW}Path: /saeka-ssh (fake-WS-handshake + raw passthrough, matching${RESET}"
    echo -e "  ${YELLOW}HTTP Injector / NPV Tunnel style clients - not real RFC6455 WS).${RESET}"
    echo ""
    SSH_USER_LIST=()
    read -r -p "$(echo -e "  ${CYAN}Add an SSH user? [y/N]: ${RESET}")" ADD_SSH
    while [[ "$ADD_SSH" =~ ^[Yy] ]]; do
        read -r -p "$(echo -e "  ${CYAN}Username [saeka]: ${RESET}")" SSH_UNAME
        SSH_UNAME=$(printf '%s' "${SSH_UNAME:-saeka}" | tr -dc 'A-Za-z0-9_-')
        read -r -p "$(echo -e "  ${CYAN}Password (blank = auto-generate): ${RESET}")" SSH_PW
        if [ -z "$SSH_PW" ]; then
            SSH_PW=$(< /dev/urandom tr -dc 'A-Za-z0-9' | head -c16)
            echo -e "  ${GREEN}Generated password for ${SSH_UNAME}: ${SSH_PW}${RESET}"
            echo -e "  ${YELLOW}(shown once - write it down now)${RESET}"
        fi
        SSH_USER_LIST+=("${SSH_UNAME}:${SSH_PW}")
        read -r -p "$(echo -e "  ${CYAN}Add another? [y/N]: ${RESET}")" ADD_SSH
    done
    if [ "${#SSH_USER_LIST[@]}" -gt 0 ]; then
        SSH_USERS_CSV=$(IFS=,; echo "${SSH_USER_LIST[*]}")
    fi
    echo ""
    ENV_VARS="^@^SSH_USERS=${SSH_USERS_CSV}"
elif [ "$PROXY_ENV" == "ovpn-relay" ]; then
    echo -e "  ${CYAN}==================================================${RESET}"
    echo -e "  ${GREEN}           OVPN RELAY - UPSTREAM VM${RESET}"
    echo -e "  ${CYAN}==================================================${RESET}"
    echo -e "  ${YELLOW}This does NOT run OpenVPN itself - it forwards /saeka-ovpn to a${RESET}"
    echo -e "  ${YELLOW}real OpenVPN server on a VM (see deploy_vm.py). Deploy that VM${RESET}"
    echo -e "  ${YELLOW}FIRST and have its static IP ready.${RESET}"
    echo ""
    read -r -p "$(echo -e "  ${CYAN}OpenVPN VM static IP: ${RESET}")" OVPN_HOST
    read -r -p "$(echo -e "  ${CYAN}OpenVPN port [1194]: ${RESET}")" OVPN_PORT
    OVPN_PORT=${OVPN_PORT:-1194}
    if [ -z "$OVPN_HOST" ]; then
        echo -e "  ${RED}No IP given - the relay will start but every connection will fail.${RESET}"
    fi
    echo ""
    ENV_VARS="^@^OVPN_UPSTREAM_HOST=${OVPN_HOST}@OVPN_UPSTREAM_PORT=${OVPN_PORT}"
else
    # ------------------------------------------------------------------
    # SAEKA PANEL (served at /saeka-panel by every Xray engine above).
    #   PANEL_KEY    - access key that unlocks credentials / links in the UI.
    #                  Pre-set it with `PANEL_KEY=... ./deploy.sh`, type one
    #                  below, or let this script generate one.
    #   PANEL_BUCKET - Cloud Storage bucket holding the shared visitor counter,
    #                  so totals survive restarts and every Cloud Run instance
    #                  adds to the same number. Optional: if it can't be
    #                  created the panel still works with per-instance counters.
    # ------------------------------------------------------------------
    echo -e "  ${CYAN}==================================================${RESET}"
    echo -e "  ${GREEN}                  WEB PANEL${RESET}"
    echo -e "  ${CYAN}==================================================${RESET}"
    PANEL_KEY="${PANEL_KEY:-}"
    if [ -z "$PANEL_KEY" ]; then
        read -r -p "$(echo -e "  ${CYAN}Panel access key (blank = auto-generate): ${RESET}")" PANEL_KEY_IN
        PANEL_KEY=$(printf '%s' "$PANEL_KEY_IN" | tr -dc 'A-Za-z0-9_-')
    fi
    if [ -z "$PANEL_KEY" ]; then
        PANEL_KEY=$( (openssl rand -hex 8 2>/dev/null || date +%s%N | sha256sum) | tr -dc 'a-f0-9' | cut -c1-16 || true)
    fi
    # The service account the Cloud Run service actually runs as: whatever an
    # existing revision uses, else the project's default compute account.
    resolve_runtime_sa() {
        local sa
        sa=$(gcloud run services describe "$SERVICE_NAME" --region "$REGION" --project="$PROJECT_ID" \
                --format='value(spec.template.spec.serviceAccountName)' 2>/dev/null | tr -d '[:space:]' || true)
        printf '%s' "${sa:-$DEFAULT_SA}"
    }

    # Give a service account read/write on the counter bucket. Retries (a new
    # account or bucket can take a few seconds to be visible) and keeps the
    # real error in BUCKET_IAM_ERR instead of throwing it away.
    BUCKET_IAM_ERR=""
    bucket_grant() {
        local sa="$1" out="" attempt
        [ -n "$sa" ] || { BUCKET_IAM_ERR="runtime service account unknown"; return 1; }
        for attempt in 1 2 3; do
            if out=$(gcloud storage buckets add-iam-policy-binding "gs://${PANEL_BUCKET}" \
                        --member="serviceAccount:${sa}" --role="roles/storage.objectAdmin" --quiet 2>&1); then
                BUCKET_IAM_ERR=""
                return 0
            fi
            sleep 4
        done
        BUCKET_IAM_ERR=$(printf '%s' "$out" | grep -v '^$' | tail -n 2 | tr '\n' ' ')
        return 1
    }

    PANEL_BUCKET=$(printf '%s' "${PROJECT_ID}-${SERVICE_NAME}-panel" | tr 'A-Z_' 'a-z-' | tr -cd 'a-z0-9-' | cut -c1-63 | sed 's/-*$//')
    if gcloud storage buckets describe "gs://${PANEL_BUCKET}" --project="$PROJECT_ID" >/dev/null 2>&1 \
        || run_quiet "Creating visitor-counter bucket" panel-bucket.log \
            gcloud storage buckets create "gs://${PANEL_BUCKET}" --project="$PROJECT_ID" \
                --location="$REGION" --uniform-bucket-level-access \
                --public-access-prevention --quiet; then
        rm -f panel-bucket.log
        RUNTIME_SA=$(resolve_runtime_sa)
        if bucket_grant "$RUNTIME_SA"; then
            echo -e "  ${GREEN}Bucket access granted to ${RUNTIME_SA}.${RESET}"
        else
            warn "Couldn't grant bucket access to ${RUNTIME_SA:-the runtime service account}: ${BUCKET_IAM_ERR}"
            warn "Continuing - many projects already give that account access through the Editor role."
            warn "The check after deploy will confirm whether the counter really syncs."
        fi
        echo -e "  ${GREEN}Visitor counter store: gs://${PANEL_BUCKET}${RESET}"
    else
        PANEL_BUCKET=""
        warn "Could not create a counter bucket - the panel will count per instance only."
    fi
    echo ""
    ENV_VARS="ADS_MODE=${ADS_MODE},PANEL_KEY=${PANEL_KEY},PANEL_BUCKET=${PANEL_BUCKET}"
fi

# --allow-unauthenticated makes the service public by granting allUsers the
# invoker role. An org policy (domain-restricted sharing) can refuse that; gcloud
# then exits non-zero even though the revision deployed. PUBLIC_FLAG is flipped to
# --no-invoker-iam-check in that case, which makes the service public without an
# IAM binding.
PUBLIC_FLAG="--allow-unauthenticated"

deploy_attempt() {
    local cpu="$1" mem="$2" maxi="$3"
    shift 3
    gcloud run deploy "$SERVICE_NAME" \
        --image "$IMAGE_URI" \
        --platform managed --region "$REGION" \
        --cpu "$cpu" --memory "$mem" --port 8080 \
        --max-instances "$maxi" \
        --timeout 3600 "$PUBLIC_FLAG" --project="$PROJECT_ID" \
        --set-env-vars "$ENV_VARS" \
        --quiet "$@"
}

deploy_tier() {
    case "$1" in
        1) deploy_attempt "$CPU" "$RAM" "$MAX_INSTANCES" --concurrency 100 --cpu-boost --no-cpu-throttling --min-instances 1;;
        2) deploy_attempt 1 2Gi 2 --concurrency 50 --no-cpu-throttling --min-instances 1;;
        *) deploy_attempt 1 2Gi 2 --concurrency 25 --min-instances 0;;
    esac
}

echo ""
DEPLOY_NOTE=""
deployed=0
for tier in 1 2 3; do
    case "$tier" in
        1) tier_label="full tier";    tier_note="full stability tuning (always-on CPU, concurrency 100)";;
        2) tier_label="reduced tier"; tier_note="reduced tier - project quota couldn't fit ${MODE} (concurrency 50)";;
        *) tier_label="minimal tier"; tier_note="minimal tier, no always-on CPU - expect cold-start delay after idle (concurrency 25)";;
    esac
    for pass in 1 2; do
        if run_quiet "Deploying to Cloud Run in ${REGION} (${tier_label})" deploy.log deploy_tier "$tier"; then
            deployed=1
            DEPLOY_NOTE="$tier_note"
            break 2
        fi
        if [ "$pass" -eq 1 ] && [ "$PUBLIC_FLAG" = "--allow-unauthenticated" ] \
                && grep -qiE 'Setting IAM policy failed|allowedPolicyMemberDomains|allUsers' deploy.log; then
            warn "An organization policy blocks public (allUsers) access - retrying with --no-invoker-iam-check."
            PUBLIC_FLAG="--no-invoker-iam-check"
            continue
        fi
        break
    done
done
if [ "$deployed" -ne 1 ]; then
    echo -e "  ${RED}DEPLOYMENT FAILED on every tier.${RESET}"
    echo -e "  ${YELLOW}The error from the last attempt is shown above; the full log is ./deploy.log.${RESET}"
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
if [ "$STANDALONE" -eq 0 ]; then
    echo -e "  ${CYAN}ADS MODE   ${GREEN}${ADS_MODE}${RESET}"
fi
echo -e "  ${CYAN}CPU / RAM  ${GREEN}${CPU} vCPU / ${RAM}${RESET}"
echo ""

if [ "$STANDALONE" -eq 0 ]; then
    PANEL_URL="https://${CLEAN_HOST}/saeka-panel"
    PANEL_UP="no"
    for _ in 1 2 3 4 5 6 7 8; do
        if [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "${PANEL_URL}/api/health" 2>/dev/null || true)" = "200" ]; then
            PANEL_UP="yes"; break
        fi
        sleep 4
    done
    # Does the panel really read/write the bucket? /api/public reports
    # store=gcs + synced=true only after a successful round trip to GCS.
    counter_synced() {
        local i
        for i in 1 2 3 4 5 6; do
            if curl -s --max-time 8 "${PANEL_URL}/api/public" 2>/dev/null | python3 -I -c '
import json, sys
try:
    s = json.load(sys.stdin)["stats"]
except Exception:
    sys.exit(1)
sys.exit(0 if s.get("store") == "gcs" and s.get("synced") is True else 1)'; then
                return 0
            fi
            sleep 8
        done
        return 1
    }

    COUNTER_STATE="none"
    FINAL_SA=""
    if [ -n "$PANEL_BUCKET" ]; then
        COUNTER_STATE="unverified"
        if [ "$PANEL_UP" = "yes" ]; then
            echo -e "  ${CYAN}Checking the visitor counter can reach gs://${PANEL_BUCKET}...${RESET}"
            # The grant before deploy went to the account we predicted; now the
            # service exists, make sure the account it really runs as has it too.
            FINAL_SA=$(resolve_runtime_sa)
            if counter_synced; then
                COUNTER_STATE="shared"
            else
                warn "Counter isn't syncing yet - re-applying bucket access for ${FINAL_SA:-the runtime account} and checking again."
                bucket_grant "$FINAL_SA" || warn "Grant failed: ${BUCKET_IAM_ERR}"
                if counter_synced; then COUNTER_STATE="shared"; else COUNTER_STATE="broken"; fi
            fi
        fi
    fi

    echo -e "  ${YELLOW}------------------------------------------------------------${RESET}"
    echo -e "  ${CYAN}                      WEB PANEL${RESET}"
    echo -e "  ${YELLOW}------------------------------------------------------------${RESET}"
    echo -e "  ${CYAN}PANEL URL  ${GREEN}${PANEL_URL}${RESET}"
    echo -e "  ${CYAN}ACCESS KEY ${GREEN}${PANEL_KEY}${RESET}   ${YELLOW}(save it - needed to unlock credentials)${RESET}"
    if [ "$PANEL_UP" = "yes" ]; then
        echo -e "  ${CYAN}STATUS     ${GREEN}panel is answering${RESET}"
    else
        echo -e "  ${CYAN}STATUS     ${YELLOW}no answer yet - give a cold start 30s, then open the URL.${RESET}"
        echo -e "  ${YELLOW}            If it stays down: gcloud run services logs read ${SERVICE_NAME} --region ${REGION}${RESET}"
    fi
    case "$COUNTER_STATE" in
        shared)
            echo -e "  ${CYAN}COUNTERS   ${GREEN}shared in gs://${PANEL_BUCKET} (sync verified)${RESET}";;
        broken)
            echo -e "  ${CYAN}COUNTERS   ${YELLOW}bucket not writable yet - counting per instance only${RESET}"
            echo -e "  ${YELLOW}            The runtime account needs access. A project owner can run:${RESET}"
            echo -e "  ${YELLOW}            gcloud storage buckets add-iam-policy-binding gs://${PANEL_BUCKET} --member=serviceAccount:${FINAL_SA:-<runtime-service-account>} --role=roles/storage.objectAdmin${RESET}"
            echo -e "  ${YELLOW}            The exact reason is in: gcloud run services logs read ${SERVICE_NAME} --region ${REGION}${RESET}";;
        unverified)
            echo -e "  ${CYAN}COUNTERS   ${YELLOW}gs://${PANEL_BUCKET} (not verified - the panel wasn't answering yet)${RESET}";;
        *)
            echo -e "  ${CYAN}COUNTERS   ${YELLOW}per instance (no bucket)${RESET}";;
    esac
    echo ""
fi
echo -e "  ${YELLOW}------------------------------------------------------------${RESET}"
if [ "$PROXY_ENV" == "ssh" ]; then
    echo -e "  ${CYAN}                  SSH GATEWAY${RESET}"
    echo -e "  ${YELLOW}------------------------------------------------------------${RESET}"
    echo -e "  ${GREEN}Path: /saeka-ssh${RESET}  (fake-handshake WS, not real RFC6455 -"
    echo -e "  matches HTTP Injector / NPV Tunnel style clients)"
    if [ -n "$SSH_USERS_CSV" ]; then
        echo -e "  ${CYAN}Users configured: ${GREEN}$(echo "$SSH_USERS_CSV" | tr ',' '\n' | cut -d: -f1 | paste -sd, -)${RESET}"
    else
        echo -e "  ${YELLOW}No users were added - a one-off random account was generated in${RESET}"
        echo -e "  ${YELLOW}the container logs (won't survive a redeploy). Re-run and add one.${RESET}"
    fi
    echo -e "  ${CYAN}Point your SSH-over-WS client at:${RESET}"
    echo -e "  ${CYAN}  wss://${CLEAN_HOST}/saeka-ssh${RESET}"
elif [ "$PROXY_ENV" == "ovpn-relay" ]; then
    echo -e "  ${CYAN}                  OVPN RELAY${RESET}"
    echo -e "  ${YELLOW}------------------------------------------------------------${RESET}"
    echo -e "  ${GREEN}Path: /saeka-ovpn${RESET}  -> forwards to ${OVPN_HOST}:${OVPN_PORT}"
    echo -e "  ${YELLOW}This is only useful once that VM is actually running OpenVPN${RESET}"
    echo -e "  ${YELLOW}(deploy_vm.py). This service does not run OpenVPN itself.${RESET}"
    echo -e "  ${CYAN}Point your client-side WS wrapper at:${RESET}"
    echo -e "  ${CYAN}  wss://${CLEAN_HOST}/saeka-ovpn${RESET}"
else
    echo -e "  ${CYAN}                    PATHS & PROTOCOLS${RESET}"
    echo -e "  ${YELLOW}------------------------------------------------------------${RESET}"
    echo -e "  ${GREEN}VLESS${RESET}        | WS: /vless-saeka   | HU: /vless-saeka-hu   | XH: /vless-saeka-xh   | gRPC: /vless-saeka-grpc   | H2: /vless-saeka-h2"
    echo -e "  ${GREEN}VMess${RESET}        | WS: /vmess-saeka   | HU: /vmess-saeka-hu   | XH: /vmess-saeka-xh   | gRPC: /vmess-saeka-grpc   | H2: /vmess-saeka-h2"
    echo -e "  ${GREEN}TROJAN${RESET}       | WS: /saeka-tojirp  | HU: /saeka-tojirp-hu  | XH: /saeka-tojirp-xh  | gRPC: /saeka-tojirp-grpc  | H2: /saeka-tojirp-h2"
    echo -e "  ${GREEN}Shadowsocks${RESET}  | WS: /ss-saeka      | HU: /ss-saeka-hu      | XH: /ss-saeka-xh      | gRPC: /ss-saeka-grpc      | H2: /ss-saeka-h2"
    echo -e "  ${GREEN}For SSH-WS or an OpenVPN relay, deploy engines 7/8 as their own${RESET}"
    echo -e "  ${GREEN}separate service instead of mixing them into this one.${RESET}"
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

echo -e "  ${CYAN}Generate client links / outbound JSON (WS + xHTTP) with:${RESET}"
echo -e "  ${GREEN}./generate-client-links.sh ${FINAL_HOST}${RESET}"
echo ""
echo -e "  ${CYAN}Behind a CDN (Cloudflare etc.)?${RESET} Proxy the domain, set SSL to Full, then:"
echo -e "  ${GREEN}CDN_ADDRESS=<edge ip or CDN domain> ./generate-client-links.sh ${FINAL_HOST}${RESET}"
echo -e "  ${YELLOW}Use the xHTTP links (mode packet-up). Cloud Run ends any single request at 3600s;${RESET}"
echo -e "  ${YELLOW}the client configs recycle connections before that so nothing is cut mid-transfer.${RESET}"
echo ""

rm -f build.log deploy.log lb.log panel-bucket.log preflight.log
echo -e "  ${GREEN}Deployer session complete.${RESET}"
