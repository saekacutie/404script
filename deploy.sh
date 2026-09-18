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

# Center a single plain-text line (no color codes counted in width).
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

# Content-centered line inside the box. $1 = plain text, $2 = optional color.
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

# ------------------------------------------------------------------------
# GREETING POOL - 10 openers x 10 closers = exactly 100 combinations,
# picked at random each run.
# ------------------------------------------------------------------------
GREET_OPEN=(
    "Welcome back,"     "Good to see you,"   "Hello again,"      "Systems nominal,"
    "Standing by,"      "Greetings,"         "All clear,"        "Access point live,"
    "Terminal awake,"   "Ready when you are,"
)
GREET_CLOSE=(
    "operator."         "commander."         "engineer."         "deployer."
    "let's ship something." "the grid awaits."  "your keys, please." "time to deploy."
    "stay sharp."       "no rush."
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
    box_line "WebSocket · HTTPUpgrade · XHTTP · gRPC*"
    box_line "(*gRPC unsupported on OpenResty)" "${YELLOW}"
    box_blank
    box_line "This tool provisions real GCP billing resources." "${YELLOW}"
    box_line "Authorized use only." "${YELLOW}"
    box_bottom
    echo ""
}

# ------------------------------------------------------------------------
# ACCESS GATE
# Only SHA-256 hashes live in this file - never the plaintext password.
# Generate a hash for a new password on your own machine (never on a
# shared/public one) with:
#     printf '%s' 'your-new-password' | sha256sum | cut -d' ' -f1
# then paste ONLY the hash below and throw away the plaintext.
#
# This is a "don't run this by accident / don't let a casual passerby run
# it" gate, not encryption - there is nothing to decrypt here, a hash is
# one-way by design. The real risk to a hash like this isn't decryption,
# it's brute force against a short/guessable password - use long, random
# passwords if you want this to actually resist that. Real access control
# still belongs in your cloud IAM / repo permissions, not a bash script.
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
        [ -z "$h" ] && continue   # skip empty/unused slots
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
echo -e "  ${GREEN}             CHOOSE PROXY ENGINE${RESET}"
echo -e "  ${CYAN}==================================================${RESET}"
echo -e "  ${YELLOW}1) HAProxy    - full protocol support incl. gRPC (not available)${RESET}"
echo -e "  ${YELLOW}2) Envoy      - full protocol support incl. gRPC${RESET}"
echo -e "  ${YELLOW}3) Caddy      - full protocol support incl. gRPC${RESET}"
echo -e "  ${YELLOW}4) H2O        - full protocol support incl. gRPC (not available)${RESET}"
echo -e "  ${YELLOW}5) Traefik    - full protocol support incl. gRPC (less tested)${RESET}"
echo -e "  ${YELLOW}6) OpenResty  - WS/HTTPUpgrade/XHTTP only, NO gRPC (nginx limitation)${RESET}"
echo ""
read -r -p "$(echo -e "  ${CYAN}SELECT PROXY ENGINE [1-6] (Default 1): ${RESET}")" ENGINE_CHOICE

case "$ENGINE_CHOICE" in
    2) ENGINE="Envoy";      PROXY_ENV="envoy";;
    3) ENGINE="Caddy";      PROXY_ENV="caddy";;
    4) ENGINE="H2O";        PROXY_ENV="h2o";;
    5) ENGINE="Traefik";    PROXY_ENV="traefik";;
    6) ENGINE="OpenResty";  PROXY_ENV="openresty";;
    *) ENGINE="HAProxy";    PROXY_ENV="haproxy";;
esac
DOCKERFILE="proxies/${PROXY_ENV}/Dockerfile"
if [ ! -f "$DOCKERFILE" ]; then
    echo -e "  ${RED}ERROR: ${DOCKERFILE} not found - repo layout looks wrong.${RESET}"
    exit 1
fi
echo -e "  ${GREEN}SELECTED PROXY ENGINE: ${ENGINE}${RESET}"
if [ "$PROXY_ENV" == "openresty" ]; then
    echo -e "  ${YELLOW}Note: gRPC endpoints will return 501 on this engine - nginx cannot${RESET}"
    echo -e "  ${YELLOW}multiplex HTTP/1.1 and cleartext HTTP/2 on one port. Pick another${RESET}"
    echo -e "  ${YELLOW}engine if you need the gRPC transport.${RESET}"
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

if [ -f "./regions.sh" ]; then
    source ./regions.sh
else
    echo -e "  ${RED}ERROR: regions.sh not found. Please ensure it is in the same directory.${RESET}"
    exit 1
fi

read -r -p "$(echo -e "  ${CYAN}SERVICE NAME [saeka]: ${RESET}")" INPUT_NAME
SERVICE_NAME=${INPUT_NAME:-saeka}
# Cloud Run service names are per-region/per-project, but different engines
# sharing one name would overwrite each other's image - suffix it.
IMAGE_TAG="${SERVICE_NAME}-${PROXY_ENV}"

echo ""
echo -e "  ${CYAN}SELECT MODE:${RESET}"
echo -e "  ${YELLOW}1) BROWSING     (1 vCPU / 2Gi  RAM)${RESET}"
echo -e "  ${YELLOW}2) STREAMING    (2 vCPU / 4Gi  RAM)${RESET}"
echo -e "  ${YELLOW}3) GAMING       (4 vCPU / 8Gi  RAM)${RESET}"
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

# ------------------------------------------------------------------------
# QUIET RUNNER
# Runs a command with its stdout/stderr fully captured to a log file and
# NOTHING streamed to the terminal - just a small animated "working" line
# while it runs. On success the line is replaced with a one-line OK and
# the log file is deleted. On failure the line is replaced with a FAILED
# marker and the last 30 lines of the log are printed so you still get a
# real error message, not a silent black box.
#
# Usage: run_quiet "Building Traefik image" build.log gcloud builds submit ...
# ------------------------------------------------------------------------
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
# BUILD - a small generated cloudbuild.yaml points Cloud Build at the
# chosen engine's Dockerfile while the build context stays the repo root
# (so proxies/<engine>/* and common/* are both reachable via COPY).
# Output is fully suppressed unless the build fails (see run_quiet above)
# - no wall of Docker/Cloud Build log lines on a normal run.
# ------------------------------------------------------------------------
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

# Quota-safe deploy: try the chosen tier, step down automatically rather
# than failing outright on restrictive quotas. Each attempt is quiet too -
# only the final failure (after all tiers are exhausted) prints its log.
deploy_attempt() {
    local cpu="$1" mem="$2" maxi="$3"
    shift 3
    gcloud run deploy "$SERVICE_NAME" \
        --image "gcr.io/${PROJECT_ID}/${IMAGE_TAG}" \
        --platform managed --region "$REGION" \
        --cpu "$cpu" --memory "$mem" --port 8080 \
        --max-instances "$maxi" \
        --timeout 3600 --allow-unauthenticated --project="$PROJECT_ID" \
        --set-env-vars "ADS_MODE=${ADS_MODE}" \
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
echo -e "  ${GREEN}VLESS${RESET}        | WS: /vless-saeka   | HU: /vless-saeka-hu   | XH: /vless-saeka-xh   | gRPC: /vless-saeka-grpc"
echo -e "  ${GREEN}VMess${RESET}        | WS: /vmess-saeka   | HU: /vmess-saeka-hu   | XH: /vmess-saeka-xh   | gRPC: /vmess-saeka-grpc"
echo -e "  ${GREEN}TROJAN${RESET}       | WS: /saeka-tojirp  | HU: /saeka-tojirp-hu  | XH: /saeka-tojirp-xh  | gRPC: /saeka-tojirp-grpc"
echo -e "  ${GREEN}Shadowsocks${RESET}  | WS: /ss-saeka      | HU: /ss-saeka-hu      | XH: /ss-saeka-xh      | gRPC: /ss-saeka-grpc"
echo -e "  ${YELLOW}------------------------------------------------------------${RESET}"
if [ "$PROXY_ENV" == "openresty" ]; then
    echo -e "  ${YELLOW}gRPC paths above will return 501 on OpenResty - see engine note.${RESET}"
fi
echo ""

# ------------------------------------------------------------------------
# CUSTOM DOMAIN (optional) - Global HTTPS Load Balancer, not domain-mappings
#
# `gcloud run domain-mappings create` requires proving ownership through
# Search Console first, which is the friction point this replaces. This
# instead puts a Global External HTTPS Load Balancer (static IP + serverless
# NEG + backend service + URL map + Google-managed cert) in front of the
# SAME Cloud Run service. Google issues the cert automatically once your
# domain's DNS A record resolves to the static IP - no manual verification
# step. This is purely additive: the plain *.run.app URL and a normal
# `gcloud run deploy` keep working exactly as before, untouched by any of
# this. Re-run the script with the same SERVICE_NAME to add more domains -
# each one gets appended to the same load balancer and cert.
#
# Every domain that's ever been added for this service is tracked in a
# local file (.domains-<service>.list) so re-runs know the full set to put
# on the certificate. Managed certs are immutable once created, so adding
# a domain mints a new cert and repoints the HTTPS proxy at it, then drops
# the old one - the load balancer, static IP and backend stay the same.
# ------------------------------------------------------------------------
echo -e "  ${CYAN}==================================================${RESET}"
echo -e "  ${GREEN}             CUSTOM DOMAIN (OPTIONAL)${RESET}"
echo -e "  ${CYAN}==================================================${RESET}"
echo -e "  ${YELLOW}Sets up a Global HTTPS Load Balancer in front of Cloud Run.${RESET}"
echo -e "  ${YELLOW}No Search Console ownership verification - point the domain's${RESET}"
echo -e "  ${YELLOW}DNS A record at the static IP printed below and Google issues${RESET}"
echo -e "  ${YELLOW}the cert automatically once DNS resolves.${RESET}"
echo ""
read -r -p "$(echo -e "  ${CYAN}Domain to map (blank to skip): ${RESET}")" CUSTOM_DOMAIN

FINAL_HOST="$CLEAN_HOST"
if [ -n "$CUSTOM_DOMAIN" ]; then
    DOMAINS_FILE="${SCRIPT_DIR}/.domains-${SERVICE_NAME}.list"
    touch "$DOMAINS_FILE"
    grep -qxF "$CUSTOM_DOMAIN" "$DOMAINS_FILE" || echo "$CUSTOM_DOMAIN" >> "$DOMAINS_FILE"
    DOMAINS_CSV=$(paste -sd, "$DOMAINS_FILE")

    IP_NAME="${SERVICE_NAME}-ip"
    NEG_NAME="${SERVICE_NAME}-neg"
    BACKEND_NAME="${SERVICE_NAME}-backend"
    URLMAP_NAME="${SERVICE_NAME}-urlmap"
    HTTPS_PROXY_NAME="${SERVICE_NAME}-https-proxy"
    FWD_RULE_NAME="${SERVICE_NAME}-https-fwd"
    CERT_NAME="${SERVICE_NAME}-cert-$(date +%s)"
    lb_setup_failed=0

    echo -e "  ${CYAN}Provisioning load balancer for: ${GREEN}${DOMAINS_CSV}${RESET}"

    gcloud services enable compute.googleapis.com --project="$PROJECT_ID" >/dev/null 2>&1 || true

    # 1. Static global IP - reused across runs/domains once reserved.
    if ! gcloud compute addresses describe "$IP_NAME" --global --project="$PROJECT_ID" >/dev/null 2>&1; then
        run_quiet "Reserving static IP" lb.log \
            gcloud compute addresses create "$IP_NAME" --global --project="$PROJECT_ID" || lb_setup_failed=1
    fi
    STATIC_IP=$(gcloud compute addresses describe "$IP_NAME" --global --project="$PROJECT_ID" --format='value(address)' 2>/dev/null)

    # 2. Serverless NEG pointing straight at this Cloud Run service.
    if ! gcloud compute network-endpoint-groups describe "$NEG_NAME" --region="$REGION" --project="$PROJECT_ID" >/dev/null 2>&1; then
        run_quiet "Creating serverless NEG" lb.log \
            gcloud compute network-endpoint-groups create "$NEG_NAME" \
                --region="$REGION" --network-endpoint-type=serverless \
                --cloud-run-service="$SERVICE_NAME" --project="$PROJECT_ID" || lb_setup_failed=1
    fi

    # 3. Backend service wrapping the NEG.
    if ! gcloud compute backend-services describe "$BACKEND_NAME" --global --project="$PROJECT_ID" >/dev/null 2>&1; then
        run_quiet "Creating backend service" lb.log \
            gcloud compute backend-services create "$BACKEND_NAME" --global --project="$PROJECT_ID" || lb_setup_failed=1
        run_quiet "Attaching NEG to backend" lb.log \
            gcloud compute backend-services add-backend "$BACKEND_NAME" --global \
                --network-endpoint-group="$NEG_NAME" --network-endpoint-group-region="$REGION" \
                --project="$PROJECT_ID" || lb_setup_failed=1
    fi

    # 4. URL map - single default service, every domain shares it.
    if ! gcloud compute url-maps describe "$URLMAP_NAME" --global --project="$PROJECT_ID" >/dev/null 2>&1; then
        run_quiet "Creating URL map" lb.log \
            gcloud compute url-maps create "$URLMAP_NAME" --default-service="$BACKEND_NAME" \
                --global --project="$PROJECT_ID" || lb_setup_failed=1
    fi

    # 5. Google-managed cert covering every domain seen so far.
    run_quiet "Requesting managed cert for ${DOMAINS_CSV}" lb.log \
        gcloud compute ssl-certificates create "$CERT_NAME" \
            --domains="$DOMAINS_CSV" --global --project="$PROJECT_ID" || lb_setup_failed=1

    # 6. Target HTTPS proxy - create once, repoint at the new cert on
    #    later runs (and drop the now-unused old cert).
    if ! gcloud compute target-https-proxies describe "$HTTPS_PROXY_NAME" --global --project="$PROJECT_ID" >/dev/null 2>&1; then
        run_quiet "Creating HTTPS proxy" lb.log \
            gcloud compute target-https-proxies create "$HTTPS_PROXY_NAME" \
                --url-map="$URLMAP_NAME" --ssl-certificates="$CERT_NAME" \
                --global --project="$PROJECT_ID" || lb_setup_failed=1
    else
        OLD_CERT=$(gcloud compute target-https-proxies describe "$HTTPS_PROXY_NAME" --global --project="$PROJECT_ID" --format='value(sslCertificates)' 2>/dev/null | sed 's|.*/||')
        run_quiet "Repointing HTTPS proxy at new cert" lb.log \
            gcloud compute target-https-proxies update "$HTTPS_PROXY_NAME" \
                --ssl-certificates="$CERT_NAME" --global --project="$PROJECT_ID" || lb_setup_failed=1
        if [ -n "$OLD_CERT" ] && [ "$OLD_CERT" != "$CERT_NAME" ]; then
            gcloud compute ssl-certificates delete "$OLD_CERT" --global --project="$PROJECT_ID" --quiet >/dev/null 2>&1 || true
        fi
    fi

    # 7. Forwarding rule - the actual :443 entry point on the static IP.
    if ! gcloud compute forwarding-rules describe "$FWD_RULE_NAME" --global --project="$PROJECT_ID" >/dev/null 2>&1; then
        run_quiet "Creating forwarding rule" lb.log \
            gcloud compute forwarding-rules create "$FWD_RULE_NAME" \
                --global --target-https-proxy="$HTTPS_PROXY_NAME" \
                --address="$IP_NAME" --ports=443 --project="$PROJECT_ID" || lb_setup_failed=1
    fi

    if [ "$lb_setup_failed" -eq 0 ]; then
        echo ""
        echo -e "  ${GREEN}Load balancer ready. Point this domain's DNS A record at:${RESET}"
        echo -e "  ${GREEN}${STATIC_IP}${RESET}"
        echo -e "  ${CYAN}Domains currently on the cert: ${GREEN}${DOMAINS_CSV}${RESET}"
        echo -e "  ${YELLOW}No Search Console verification needed - once DNS resolves,${RESET}"
        echo -e "  ${YELLOW}Google auto-issues the cert (usually 15-60 min, sometimes longer).${RESET}"
        echo -e "  ${YELLOW}Check status with:${RESET}"
        echo -e "  ${GREEN}gcloud compute ssl-certificates describe ${CERT_NAME} --global --project=${PROJECT_ID} --format='value(managed.status)'${RESET}"
        echo -e "  ${YELLOW}Re-run this script with SERVICE_NAME=${SERVICE_NAME} and a new domain${RESET}"
        echo -e "  ${YELLOW}to add it to this same load balancer/cert later.${RESET}"
        FINAL_HOST="$CUSTOM_DOMAIN"
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
