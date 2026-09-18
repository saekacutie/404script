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
# still belongs in your cloud IAM / repo permissions, not a bash script.
# ------------------------------------------------------------------------
ALLOWED_HASHES=(
    "2c443ca329d2d85d093b80349ee88cc23169eaec1698dea050920836773fb7ad"
    "718052c0d0866bb03f23d3d4f2488f2aa86c435b9fd658abecbfc4c7abf2de47"
    "57141b782821c05da2e2bcb1e2fa1253bce1a817c0d14f79bc899e1171ad7bb0"
    ""  # slot 4
    ""  # slot 5
    ""  # slot 6
    ""  # slot 7
    ""  # slot 8
    ""  # slot 9
    ""  # slot 10
)
MAX_ATTEMPTS=3
authorized=0
for ((attempt=1; attempt<=MAX_ATTEMPTS; attempt++)); do
    read -r -s -p "$(echo -e "  ${CYAN}DEPLOYER PASSWORD: ${RESET}")" INPUT_PW
    echo ""
    INPUT_HASH=$(printf '%s' "$INPUT_PW" | sha256sum | cut -d' ' -f1)
    for h in "${ALLOWED_HASHES[@]}"; do
        [ -z "$h" ] && continue   # skip empty/unused slots
        if [ "$INPUT_HASH" == "$h" ]; then
            authorized=1
            break 2
        fi
    done
    echo -e "  ${RED}Incorrect password (${attempt}/${MAX_ATTEMPTS}).${RESET}"
done
if [ "$authorized" -ne 1 ]; then
    echo -e "  ${RED}Access denied.${RESET}"
    exit 1
fi

clear
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
echo -e "  ${YELLOW}1) HAProxy    - full protocol support incl. gRPC (recommended)${RESET}"
echo -e "  ${YELLOW}2) Envoy      - full protocol support incl. gRPC${RESET}"
echo -e "  ${YELLOW}3) Caddy      - full protocol support incl. gRPC${RESET}"
echo -e "  ${YELLOW}4) H2O        - full protocol support incl. gRPC (least tested)${RESET}"
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
# BUILD - a small generated cloudbuild.yaml points Cloud Build at the
# chosen engine's Dockerfile while the build context stays the repo root
# (so proxies/<engine>/* and common/* are both reachable via COPY).
# Output streams live below - no fake spinner, no fixed sleep, no
# after-the-fact "done": you see gcloud's own build log lines as they
# happen, and the log is also kept on disk for the failure path.
# ------------------------------------------------------------------------
CB_CONFIG=$(mktemp)
cat > "$CB_CONFIG" <<YAML
steps:
  - name: 'gcr.io/cloud-builders/docker'
    args: ['build', '-f', '${DOCKERFILE}', '-t', 'gcr.io/${PROJECT_ID}/${IMAGE_TAG}', '.']
images:
  - 'gcr.io/${PROJECT_ID}/${IMAGE_TAG}'
YAML

# gcloud's own boilerplate (archive/tarball-upload/build-created/log-URL/

QUIET_FILTER='^(Creating temporary archive|Uploading tarball|Created \[|Logs are available at|Waiting for build to complete)'

echo -e "  ${CYAN}Building ${ENGINE} image...${RESET}"
if ! gcloud builds submit . --config "$CB_CONFIG" --project="$PROJECT_ID" 2>&1 \
        | tee build.log | sed -E "/${QUIET_FILTER}/d"; then
    echo -e "  ${RED}BUILD FAILED. Last 30 log lines:${RESET}"
    tail -n 30 build.log
    rm -f "$CB_CONFIG"
    exit 1
fi
rm -f "$CB_CONFIG"

# Quota-safe deploy: try the chosen tier, step down automatically rather
# than failing outright on restrictive quotas. Output streams live.
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
        --quiet "$@" 2>&1 | tee deploy.log | sed -E "/${QUIET_FILTER}/d"
    return "${PIPESTATUS[0]}"
}

echo ""
echo -e "  ${CYAN}Deploying to Cloud Run in ${REGION}...${RESET}"
if deploy_attempt "$CPU" "$RAM" "$MAX_INSTANCES" --concurrency 1000 --cpu-boost --no-cpu-throttling --min-instances 1; then
    DEPLOY_NOTE="full stability tuning (always-on CPU)"
elif deploy_attempt 1 2Gi 2 --concurrency 500 --no-cpu-throttling --min-instances 1; then
    DEPLOY_NOTE="reduced tier - project quota couldn't fit ${MODE}"
elif deploy_attempt 1 2Gi 2 --concurrency 250 --min-instances 0; then
    DEPLOY_NOTE="minimal tier, no always-on CPU - expect cold-start delay after idle"
else
    echo -e "  ${RED}DEPLOYMENT FAILED. Last 30 log lines:${RESET}"
    tail -n 30 deploy.log
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

# ----------------
# CUSTOM DOMAIN (optional)
#-----------------
echo -e "  ${CYAN}==================================================${RESET}"
echo -e "  ${GREEN}             CUSTOM DOMAIN (OPTIONAL)${RESET}"
echo -e "  ${CYAN}==================================================${RESET}"
echo -e "  ${YELLOW}Requires: domain already verified for this GCP project${RESET}"
echo -e "  ${YELLOW}(https://search.google.com/search-console -> Ownership verification,${RESET}"
echo -e "  ${YELLOW}then linked under 'gcloud domains verify DOMAIN' / Cloud Console).${RESET}"
echo ""
read -r -p "$(echo -e "  ${CYAN}Domain to map (blank to skip): ${RESET}")" CUSTOM_DOMAIN

FINAL_HOST="$CLEAN_HOST"
if [ -n "$CUSTOM_DOMAIN" ]; then
    echo -e "  ${CYAN}Creating domain mapping ${CUSTOM_DOMAIN} -> ${SERVICE_NAME} ...${RESET}"
    if MAP_OUT=$(gcloud run domain-mappings create \
            --service "$SERVICE_NAME" --domain "$CUSTOM_DOMAIN" \
            --region "$REGION" --project="$PROJECT_ID" --quiet 2>&1); then
        echo -e "  ${GREEN}Mapping created. Add these DNS records at your registrar/DNS host:${RESET}"
        echo "$MAP_OUT" | grep -E 'NAME|rrdata|TYPE|---' || echo "$MAP_OUT"
        echo ""
        echo -e "  ${YELLOW}Google issues a managed TLS cert automatically once DNS resolves -${RESET}"
        echo -e "  ${YELLOW}that can take anywhere from a few minutes to ~24h. Check status with:${RESET}"
        echo -e "  ${GREEN}gcloud run domain-mappings describe --domain ${CUSTOM_DOMAIN} --region ${REGION} --project ${PROJECT_ID}${RESET}"
        FINAL_HOST="$CUSTOM_DOMAIN"
    else
        echo -e "  ${RED}Domain mapping failed:${RESET}"
        echo "$MAP_OUT"
        echo -e "  ${YELLOW}Most common cause: the domain isn't verified for this project yet -${RESET}"
        echo -e "  ${YELLOW}see the note above. Falling back to the raw Cloud Run host.${RESET}"
    fi
    echo ""
fi

echo -e "  ${CYAN}Generate client links / outbound JSON with:${RESET}"
echo -e "  ${GREEN}./generate-client-links.sh ${FINAL_HOST}${RESET}"
echo ""

rm -f build.log deploy.log
echo -e "  ${GREEN}Deployer session complete.${RESET}"
