#!/bin/bash
# 4N1 FAST DEPLOYER v2 - engineered by Saeka Tojirp
# Each engine builds from its own proxies/<engine>/Dockerfile.
set -euo pipefail

BOLD='\033[1m'; RESET='\033[0m'
GREEN='\033[1;32m'; RED='\033[1;31m'; CYAN='\033[1;36m'
YELLOW='\033[1;33m'; MAGENTA='\033[1;35m'; WHITE='\033[1;37m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Non-interactive mode: pass --auto or set DEPLOY_AUTO=1. Every prompt below
# then uses the matching DEPLOY_* env var if set, else the documented
# default, instead of asking. See the "auto defaults" comment on each prompt
# for its env var name.
AUTO=0
for a in "$@"; do [ "$a" = "--auto" ] && AUTO=1; done
[ "${DEPLOY_AUTO:-0}" = "1" ] && AUTO=1

auto_ask() {
    # auto_ask VAR "prompt text" "default" -> sets VAR, printing what it used
    local __var="$1" __prompt="$2" __default="${3:-}"
    if [ "$AUTO" -eq 1 ]; then
        local __envname="DEPLOY_${__var}"
        local __val="${!__envname:-$__default}"
        printf -v "$__var" '%s' "$__val"
        echo -e "  ${CYAN}${__prompt}${RESET} -> ${GREEN}${__val}${RESET}"
    else
        read -r -p "$(echo -e "  ${CYAN}${__prompt}${RESET}")" "$__var"
        [ -z "${!__var}" ] && printf -v "$__var" '%s' "$__default"
    fi
}

# Terminal layout helpers (cosmetic only).
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
    if [ "$AUTO" -eq 1 ]; then
        INPUT_PW="${DEPLOY_PASSWORD:-}"
    else
        printf "%s" "$BPAD"
        read -r -s -p "$(echo -e "  ${CYAN}${BOLD}ENTER PASSWORD ›${RESET} ")" INPUT_PW
        echo ""
    fi
    INPUT_HASH=$(printf '%s' "$INPUT_PW" | sha256sum | cut -d' ' -f1)
    for h in "${ALLOWED_HASHES[@]}"; do
        [ -z "$h" ] && continue
        if [ "$INPUT_HASH" == "$h" ]; then
            authorized=1
            break 2
        fi
    done
    if [ "$AUTO" -eq 1 ]; then
        echo -e "  ${RED}DEPLOY_PASSWORD did not match (attempt ${attempt}/${MAX_ATTEMPTS}).${RESET}"
        break
    fi
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
echo -e "  ${YELLOW}7) SSH Gateway - standalone SSH-over-WS (+ UDPGW), optional OpenVPN relay + /cert${RESET}"
echo -e "  ${YELLOW}8) OVPN Relay  - standalone WS relay to a REAL OpenVPN server on a VM (+ /cert)${RESET}"
echo -e "  ${YELLOW}9) Reality Combo - VLESS+XHTTP+REALITY on a VM + Cloud Run relay (+ SSH-WS, OpenVPN-WS, /cert)${RESET}"
echo ""
if [ "$AUTO" -eq 1 ]; then
    ENGINE_CHOICE="${DEPLOY_ENGINE_CHOICE:-7}"
    echo -e "  ${CYAN}SELECT PROXY ENGINE [1-9]${RESET} -> ${GREEN}${ENGINE_CHOICE}${RESET}"
else
    read -r -p "$(echo -e "  ${CYAN}SELECT PROXY ENGINE [1-9] (Default 1): ${RESET}")" ENGINE_CHOICE
fi

STANDALONE=0
case "$ENGINE_CHOICE" in
    2) ENGINE="Envoy";      PROXY_ENV="envoy";;
    3) ENGINE="Caddy";      PROXY_ENV="caddy";;
    4) ENGINE="H2O";        PROXY_ENV="h2o";;
    5) ENGINE="Traefik";    PROXY_ENV="traefik";;
    6) ENGINE="OpenResty";  PROXY_ENV="openresty";;
    7) ENGINE="SSH Gateway"; PROXY_ENV="ssh";        STANDALONE=1;;
    8) ENGINE="OVPN Relay";  PROXY_ENV="ovpn-relay"; STANDALONE=1;;
    9) ENGINE="Reality Combo"; PROXY_ENV="reality";  STANDALONE=1;;
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

ADS_MODE="n/a"
if [ "$STANDALONE" -eq 0 ]; then
    echo -e "  ${CYAN}==================================================${RESET}"
    echo -e "  ${GREEN}                  ADS MODE${RESET}"
    echo -e "  ${CYAN}==================================================${RESET}"
    echo -e "  ${YELLOW}1) No ads   - blocks known ad/tracker domains via DNS${RESET}"
    echo -e "  ${YELLOW}2) Ads      - normal DNS, no blocking${RESET}"
    if [ "$AUTO" -eq 1 ]; then
        ADS_CHOICE="${DEPLOY_ADS_CHOICE:-1}"
        echo -e "  ${CYAN}CHOICE [1-2]${RESET} -> ${GREEN}${ADS_CHOICE}${RESET}"
    else
        read -r -p "$(echo -e "  ${CYAN}CHOICE [1-2] (Default 1): ${RESET}")" ADS_CHOICE
    fi
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
if [ -z "${REGION:-}" ]; then
    echo -e "  ${RED}ERROR: regions.sh did not set REGION.${RESET}"
    exit 1
fi

if [ "$AUTO" -eq 1 ]; then
    INPUT_NAME="${DEPLOY_SERVICE_NAME:-saeka}"
    echo -e "  ${CYAN}SERVICE NAME${RESET} -> ${GREEN}${INPUT_NAME}${RESET}"
else
    read -r -p "$(echo -e "  ${CYAN}SERVICE NAME [saeka]: ${RESET}")" INPUT_NAME
fi
SERVICE_NAME=${INPUT_NAME:-saeka}
IMAGE_TAG="${SERVICE_NAME}-${PROXY_ENV}"

echo ""
echo -e "  ${CYAN}SELECT MODE:${RESET}"
echo -e "  ${YELLOW}1) BROWSING      (1 vCPU / 2Gi  RAM)${RESET}"
echo -e "  ${YELLOW}2) STREAMING     (2 vCPU / 4Gi  RAM)${RESET}"
echo -e "  ${YELLOW}3) GAMING        (4 vCPU / 8Gi  RAM)${RESET}"
echo -e "  ${YELLOW}4) CUSTOM${RESET}"
echo ""
if [ "$AUTO" -eq 1 ]; then
    MODE_CHOICE="${DEPLOY_MODE_CHOICE:-1}"
    echo -e "  ${CYAN}CHOICE${RESET} -> ${GREEN}${MODE_CHOICE}${RESET}"
else
    read -r -p "$(echo -e "  ${CYAN}CHOICE: ${RESET}")" MODE_CHOICE
fi

case "$MODE_CHOICE" in
    2) CPU="2"; RAM="4Gi"; MODE="STREAMING"; MAX_INSTANCES="4";;
    3) CPU="4"; RAM="8Gi"; MODE="GAMING";    MAX_INSTANCES="4";;
    4)
        if [ "$AUTO" -eq 1 ]; then
            CPU="${DEPLOY_CPU:-1}"; RAM="${DEPLOY_RAM:-2Gi}"; MAX_INSTANCES="${DEPLOY_MAX_INSTANCES:-4}"
        else
            read -r -p "$(echo -e "  ${CYAN}CPU (1/2/4): ${RESET}")" CPU
            read -r -p "$(echo -e "  ${CYAN}RAM (2Gi/4Gi/8Gi): ${RESET}")" RAM
            read -r -p "$(echo -e "  ${CYAN}MAX INSTANCES (1/2/4): ${RESET}")" MAX_INSTANCES
        fi
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

# ------------------------------------------------------------------------
# Prompts shared by the SSH gateway (7), OVPN relay (8) and Reality Combo (9)
# ------------------------------------------------------------------------
prompt_ovpn_upstream() {
    OVPN_HOST=""
    OVPN_PORT=""

    # Auto-discover a VM provisioned by deploy_vm.py so its IP never has to
    # be typed in here. Each such VM leaves ~/.deploy_vm/<name>-info.json.
    local info_dir="$HOME/.deploy_vm"
    local candidates=()
    if [ -d "$info_dir" ]; then
        while IFS= read -r f; do candidates+=("$f"); done < <(ls -t "$info_dir"/*-info.json 2>/dev/null)
    fi

    if [ "${#candidates[@]}" -gt 0 ] && command -v jq >/dev/null 2>&1; then
        local chosen="${candidates[0]}"
        if [ "${#candidates[@]}" -gt 1 ]; then
            echo -e "  ${CYAN}Found multiple VMs from deploy_vm.py:${RESET}"
            local i=1
            for f in "${candidates[@]}"; do
                echo -e "  ${YELLOW}${i}) $(jq -r '.vm_name' "$f") - $(jq -r '.host' "$f")${RESET}"
                i=$((i + 1))
            done
            if [ "$AUTO" -eq 1 ]; then
                pick="${DEPLOY_VM_PICK:-1}"
                echo -e "  ${CYAN}Pick one${RESET} -> ${GREEN}${pick}${RESET}"
            else
                read -r -p "$(echo -e "  ${CYAN}Pick one [1]: ${RESET}")" pick
            fi
            pick=${pick:-1}
            chosen="${candidates[$((pick - 1))]}"
        fi
        local ovpn_enabled
        ovpn_enabled=$(jq -r '.ovpn_enabled' "$chosen")
        if [ "$ovpn_enabled" == "true" ]; then
            OVPN_HOST=$(jq -r '.host' "$chosen")
            OVPN_PORT=$(jq -r '.ovpn_port' "$chosen")
            echo -e "  ${GREEN}Using $(jq -r '.vm_name' "$chosen") from deploy_vm.py: ${OVPN_HOST}:${OVPN_PORT}${RESET}"
        else
            echo -e "  ${YELLOW}$(jq -r '.vm_name' "$chosen") didn't have OpenVPN enabled - falling back to manual entry.${RESET}"
        fi
    fi

    # Nothing usable on disk. Cloud Run itself cannot run OpenVPN - it only
    # takes HTTP/HTTPS on one port, no raw TCP/UDP ingress - so there is no
    # IP to "auto-detect" until an actual VM exists. Offer to provision one
    # right now instead of just asking you to type an IP from nowhere.
    if [ -z "$OVPN_HOST" ] && [ -f "${SCRIPT_DIR}/deploy_vm.py" ] && command -v python3 >/dev/null 2>&1; then
        local provision="N"
        if [ "$AUTO" -eq 1 ]; then
            provision="${DEPLOY_PROVISION_VM:-Y}"
            echo -e "  ${YELLOW}No OpenVPN VM found.${RESET} ${CYAN}Provisioning one now via deploy_vm.py --auto${RESET} -> ${GREEN}${provision}${RESET}"
        else
            echo -e "  ${YELLOW}No OpenVPN VM found on this machine yet.${RESET}"
            read -r -p "$(echo -e "  ${CYAN}Provision one automatically now (deploy_vm.py --auto)? [Y/n]: ${RESET}")" provision
            provision=${provision:-Y}
        fi
        if [[ "$provision" =~ ^[Yy] ]]; then
            echo -e "  ${CYAN}Running deploy_vm.py --auto (SSH tunnel off, OpenVPN on, proto tcp)...${RESET}"
            (
                cd "$SCRIPT_DIR"
                DEPLOY_VM_AUTO=1 \
                DEPLOY_VM_ENABLE_SSH="${DEPLOY_VM_ENABLE_SSH:-n}" \
                DEPLOY_VM_ENABLE_OVPN=y \
                DEPLOY_VM_ENABLE_REALITY="${DEPLOY_VM_ENABLE_REALITY:-n}" \
                DEPLOY_VM_OVPN_PROTO=tcp \
                SSH_USERS="${SSH_USERS:-$SSH_USERS_CSV}" \
                python3 deploy_vm.py --auto
            )
            local new_info
            new_info=$(ls -t "$info_dir"/*-info.json 2>/dev/null | head -n1 || true)
            if [ -n "$new_info" ] && command -v jq >/dev/null 2>&1; then
                OVPN_HOST=$(jq -r '.host' "$new_info")
                OVPN_PORT=$(jq -r '.ovpn_port' "$new_info")
                echo -e "  ${GREEN}VM ready: ${OVPN_HOST}:${OVPN_PORT}${RESET}"
            else
                echo -e "  ${RED}deploy_vm.py finished but no info file was found - falling back to manual entry.${RESET}"
            fi
        fi
    fi

    while [ -z "$OVPN_HOST" ]; do
        if [ "$AUTO" -eq 1 ]; then
            if [ -z "${DEPLOY_OVPN_HOST:-}" ]; then
                echo -e "  ${RED}No deploy_vm.py info file found and DEPLOY_OVPN_HOST isn't set - can't continue in --auto mode.${RESET}"
                echo -e "  ${YELLOW}Run 'python3 deploy_vm.py --auto' first, or set DEPLOY_OVPN_HOST yourself.${RESET}"
                exit 1
            fi
            OVPN_HOST="$DEPLOY_OVPN_HOST"
            continue
        fi
        read -r -p "$(echo -e "  ${CYAN}OpenVPN VM static IP or hostname: ${RESET}")" OVPN_HOST
        if ! [[ "$OVPN_HOST" =~ ^[A-Za-z0-9.-]+$ ]]; then
            echo -e "  ${RED}Enter a valid IP or hostname.${RESET}"
            OVPN_HOST=""
        fi
    done
    while [ -z "$OVPN_PORT" ]; do
        if [ "$AUTO" -eq 1 ]; then
            OVPN_PORT="${DEPLOY_OVPN_PORT:-1194}"
            continue
        fi
        read -r -p "$(echo -e "  ${CYAN}OpenVPN TCP port [1194]: ${RESET}")" OVPN_PORT
        OVPN_PORT=${OVPN_PORT:-1194}
        if ! [[ "$OVPN_PORT" =~ ^[0-9]+$ ]] || [ "$OVPN_PORT" -lt 1 ] || [ "$OVPN_PORT" -gt 65535 ]; then
            echo -e "  ${RED}Port must be 1-65535.${RESET}"
            OVPN_PORT=""
        fi
    done
}

# Embeds the client .ovpn written by deploy_vm.py so /cert can serve it.
# OVPN_PROFILE_FILE (set by engine 9) pins it to that VM's profile; otherwise
# the newest ~/.deploy_vm/*-client1.ovpn is used.
prompt_ovpn_profile() {
    OVPN_PROFILE_B64=""
    local f
    f="${OVPN_PROFILE_FILE:-}"
    if [ -z "$f" ] || [ ! -f "$f" ]; then
        f=$(ls -t "$HOME"/.deploy_vm/*-client1.ovpn 2>/dev/null | head -n1 || true)
    fi
    if [ -z "$f" ]; then
        echo -e "  ${YELLOW}No profile from deploy_vm.py found in ~/.deploy_vm - /cert stays disabled.${RESET}"
        return 0
    fi
    echo -e "  ${CYAN}Found OpenVPN profile: ${GREEN}${f}${RESET}"
    if ! grep -q "^remote ${OVPN_HOST} " "$f"; then
        echo -e "  ${YELLOW}Warning: its 'remote' line doesn't match ${OVPN_HOST}.${RESET}"
    fi
    if grep -q "^proto udp" "$f"; then
        echo -e "  ${YELLOW}Warning: profile is proto udp - the Cloud Run relay needs an OpenVPN server on tcp.${RESET}"
    fi
    local yn
    if [ "$AUTO" -eq 1 ]; then
        yn="${DEPLOY_CERT_SERVE:-Y}"
        echo -e "  ${CYAN}Serve it at /cert (login = your SSH users)?${RESET} -> ${GREEN}${yn}${RESET}"
    else
        read -r -p "$(echo -e "  ${CYAN}Serve it at /cert (login = your SSH users)? [Y/n]: ${RESET}")" yn
    fi
    if ! [[ "$yn" =~ ^[Nn] ]]; then
        OVPN_PROFILE_B64=$(base64 < "$f" | tr -d '\n')
        echo -e "  ${YELLOW}The profile holds the client private key - it is stored in the service's${RESET}"
        echo -e "  ${YELLOW}env vars, so limit who can view this Cloud Run service.${RESET}"
    fi
}

SSH_USERS_CSV=""
collect_users() {
    local purpose="$1" use_env=""
    SSH_USERS_CSV=""
    if [ -n "${SSH_USERS:-}" ]; then
        if [ "$AUTO" -eq 1 ]; then
            SSH_USERS_CSV="$SSH_USERS"
            echo -e "  ${GREEN}Using SSH_USERS from the environment for ${purpose}.${RESET}"
            return 0
        fi
        read -r -p "$(echo -e "  ${CYAN}Use SSH_USERS from your environment for ${purpose}? [Y/n]: ${RESET}")" use_env
        if ! [[ "$use_env" =~ ^[Nn] ]]; then
            SSH_USERS_CSV="$SSH_USERS"
            return 0
        fi
    fi
    if [ "$AUTO" -eq 1 ]; then
        # No SSH_USERS given: generate one login so the gateway is usable
        # and the account survives a redeploy, instead of leaving it empty.
        local uname="${DEPLOY_SSH_USERNAME:-saeka}"
        local pw
        pw=$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 16 || true)
        echo -e "  ${GREEN}Generated login for ${purpose} - ${uname}: ${pw}${RESET}"
        echo -e "  ${YELLOW}(shown once - write it down now; set SSH_USERS yourself to control this)${RESET}"
        SSH_USERS_CSV="${uname}:${pw}"
        return 0
    fi
    SSH_USER_LIST=()
    read -r -p "$(echo -e "  ${CYAN}Add a user for ${purpose}? [y/N]: ${RESET}")" ADD_SSH
    while [[ "$ADD_SSH" =~ ^[Yy] ]]; do
        read -r -p "$(echo -e "  ${CYAN}Username [saeka]: ${RESET}")" SSH_UNAME
        SSH_UNAME=$(printf '%s' "${SSH_UNAME:-saeka}" | tr 'A-Z' 'a-z' | tr -dc 'a-z0-9_-')
        if ! [[ "$SSH_UNAME" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
            echo -e "  ${RED}Invalid username: start with a letter, then a-z 0-9 _ - only.${RESET}"
        else
            read -r -p "$(echo -e "  ${CYAN}Password (blank = auto-generate): ${RESET}")" SSH_PW
            if [ -z "$SSH_PW" ]; then
                SSH_PW=$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 16 || true)
                echo -e "  ${GREEN}Generated password for ${SSH_UNAME}: ${SSH_PW}${RESET}"
                echo -e "  ${YELLOW}(shown once - write it down now)${RESET}"
            fi
            if [[ "$SSH_PW" =~ [,@[:space:]] ]]; then
                echo -e "  ${RED}Password can't contain commas, @ or spaces - user not added.${RESET}"
            else
                SSH_USER_LIST+=("${SSH_UNAME}:${SSH_PW}")
            fi
        fi
        read -r -p "$(echo -e "  ${CYAN}Add another? [y/N]: ${RESET}")" ADD_SSH
    done
    if [ "${#SSH_USER_LIST[@]}" -gt 0 ]; then
        SSH_USERS_CSV=$(IFS=,; echo "${SSH_USER_LIST[*]}")
    fi
}

# ---- Reality Combo (engine 9) helpers --------------------------------------

# jget FILE dotted.path -> value (strings raw, everything else as JSON); empty if missing
jget() {
    python3 - "$1" "$2" <<'PYEOF'
import json, sys
try:
    with open(sys.argv[1]) as f:
        node = json.load(f)
    for part in sys.argv[2].split("."):
        node = node[part]
except Exception:
    sys.exit(0)
print(node if isinstance(node, str) else json.dumps(node))
PYEOF
}

# "/vless-saeka-xh" -> "%2Fvless-saeka-xh" (paths are validated to [A-Za-z0-9._~/-])
urlenc_path() {
    local p="$1"
    printf '%s' "${p//\//%2F}"
}

# First UP zone in $REGION so the VM sits next to the Cloud Run service.
pick_zone() {
    local zones z
    zones=$(gcloud compute zones list --project="$PROJECT_ID" --filter="status=UP" --format='value(name)' 2>/dev/null || true)
    for z in $zones; do
        if [[ "$z" =~ ^${REGION}-[a-z]$ ]]; then
            printf '%s' "$z"
            return 0
        fi
    done
    printf '%s' "${REGION}-a"
}

# Finds (or provisions via deploy_vm.py --auto) the VM that runs VLESS+XHTTP+REALITY
# and loads everything Cloud Run needs from its ~/.deploy_vm/<name>-info.json.
prompt_reality_vm() {
    local info_dir="$HOME/.deploy_vm" f chosen="" pick provision ovpn_yn ovpn_flag vm_name zone
    local candidates=()
    R_VM_NAME=""; R_HOST=""; R_VM_IP=""; R_UUID=""; R_PBK=""; R_SID=""; R_SNI=""
    R_PORT=""; R_PATH=""; R_MODE=""; R_RELAY_PORT=""; R_RELAY_PATH=""; R_RELAY_CERT_B64=""
    OVPN_HOST=""; OVPN_PORT=""; OVPN_PROFILE_FILE=""

    if [ -d "$info_dir" ]; then
        while IFS= read -r f; do
            if [ "$(jget "$f" reality.transport)" = "xhttp" ] && [ "$(jget "$f" reality.relay.enabled)" = "true" ]; then
                candidates+=("$f")
            fi
        done < <(ls -t "$info_dir"/*-info.json 2>/dev/null)
    fi

    if [ "${#candidates[@]}" -gt 0 ]; then
        chosen="${candidates[0]}"
        if [ "${#candidates[@]}" -gt 1 ]; then
            echo -e "  ${CYAN}Found multiple REALITY+XHTTP VMs from deploy_vm.py:${RESET}"
            local i=1
            for f in "${candidates[@]}"; do
                echo -e "  ${YELLOW}${i}) $(jget "$f" vm_name) - $(jget "$f" host)${RESET}"
                i=$((i + 1))
            done
            if [ "$AUTO" -eq 1 ]; then
                pick="${DEPLOY_VM_PICK:-1}"
                echo -e "  ${CYAN}Pick one${RESET} -> ${GREEN}${pick}${RESET}"
            else
                read -r -p "$(echo -e "  ${CYAN}Pick one [1]: ${RESET}")" pick
            fi
            pick=${pick:-1}
            if ! [[ "$pick" =~ ^[0-9]+$ ]] || [ "$pick" -lt 1 ] || [ "$pick" -gt "${#candidates[@]}" ]; then
                pick=1
            fi
            chosen="${candidates[$((pick - 1))]}"
        fi
        echo -e "  ${GREEN}Using existing VM $(jget "$chosen" vm_name) from deploy_vm.py.${RESET}"
    else
        if [ ! -f "${SCRIPT_DIR}/deploy_vm.py" ]; then
            echo -e "  ${RED}deploy_vm.py not found next to deploy.sh - engine 9 needs it to create the VM.${RESET}"
            exit 1
        fi
        provision="Y"
        if [ "$AUTO" -eq 1 ]; then
            provision="${DEPLOY_PROVISION_VM:-Y}"
            echo -e "  ${YELLOW}No REALITY+XHTTP VM found.${RESET} ${CYAN}Provisioning one via deploy_vm.py --auto${RESET} -> ${GREEN}${provision}${RESET}"
        else
            echo -e "  ${YELLOW}No REALITY+XHTTP VM found on this machine yet.${RESET}"
            read -r -p "$(echo -e "  ${CYAN}Provision one automatically now (deploy_vm.py --auto)? [Y/n]: ${RESET}")" provision
            provision=${provision:-Y}
        fi
        if ! [[ "$provision" =~ ^[Yy] ]]; then
            echo -e "  ${RED}Engine 9 needs the VM. Run 'python3 deploy_vm.py' first, then re-run this.${RESET}"
            exit 1
        fi
        if [ "$AUTO" -eq 1 ]; then
            ovpn_yn="${DEPLOY_VM_ENABLE_OVPN:-y}"
            echo -e "  ${CYAN}Also run OpenVPN on the VM (for /saeka-ovpn + /cert)?${RESET} -> ${GREEN}${ovpn_yn}${RESET}"
        else
            read -r -p "$(echo -e "  ${CYAN}Also run OpenVPN on the VM (for /saeka-ovpn + /cert)? [Y/n]: ${RESET}")" ovpn_yn
        fi
        ovpn_flag="y"
        if [[ "$ovpn_yn" =~ ^[Nn] ]]; then
            ovpn_flag="n"
        fi
        vm_name="${DEPLOY_VM_VM_NAME:-${SERVICE_NAME}-tcp}"
        zone="${DEPLOY_VM_GCE_ZONE:-$(pick_zone)}"
        echo -e "  ${CYAN}Running deploy_vm.py --auto: ${vm_name} in ${zone} (REALITY+XHTTP, relay on, OpenVPN ${ovpn_flag})...${RESET}"
        if ! (
            cd "$SCRIPT_DIR"
            DEPLOY_VM_AUTO=1 \
            DEPLOY_VM_VM_NAME="$vm_name" \
            DEPLOY_VM_GCE_ZONE="$zone" \
            DEPLOY_VM_ENABLE_REALITY=y \
            DEPLOY_VM_REALITY_TRANSPORT=xhttp \
            DEPLOY_VM_ENABLE_RELAY=y \
            DEPLOY_VM_ENABLE_OVPN="$ovpn_flag" \
            DEPLOY_VM_ENABLE_SSH="${DEPLOY_VM_ENABLE_SSH:-n}" \
            DEPLOY_VM_OVPN_PROTO=tcp \
            SSH_USERS="$SSH_USERS_CSV" \
            python3 deploy_vm.py --auto
        ); then
            echo -e "  ${RED}deploy_vm.py failed - see its output above.${RESET}"
            exit 1
        fi
        chosen="$info_dir/${vm_name}-info.json"
        if [ ! -f "$chosen" ]; then
            echo -e "  ${RED}deploy_vm.py finished but ${chosen} was not written.${RESET}"
            exit 1
        fi
    fi

    if [ "$(jget "$chosen" reality.transport)" != "xhttp" ] || [ "$(jget "$chosen" reality.relay.enabled)" != "true" ]; then
        echo -e "  ${RED}$(jget "$chosen" vm_name) is not running REALITY+XHTTP with the relay listener.${RESET}"
        echo -e "  ${YELLOW}It was built earlier (or REALITY failed). Delete it and re-run so it is rebuilt:${RESET}"
        echo -e "  ${YELLOW}  gcloud compute instances delete $(jget "$chosen" vm_name) --zone $(jget "$chosen" zone)${RESET}"
        exit 1
    fi

    R_VM_NAME=$(jget "$chosen" vm_name)
    R_HOST=$(jget "$chosen" host)
    R_VM_IP=$(jget "$chosen" ip)
    R_UUID=$(jget "$chosen" reality.uuid)
    R_PBK=$(jget "$chosen" reality.publicKey)
    R_SID=$(jget "$chosen" reality.shortId)
    R_SNI=$(jget "$chosen" reality.serverName)
    R_PORT=$(jget "$chosen" reality.port)
    R_PATH=$(jget "$chosen" reality.path)
    R_MODE=$(jget "$chosen" reality.mode)
    R_RELAY_PORT=$(jget "$chosen" reality.relay.port)
    R_RELAY_PATH=$(jget "$chosen" reality.relay.path)
    R_RELAY_CERT_B64=$(jget "$chosen" reality.relay.certB64)
    if [ -z "$R_VM_IP" ] || [ -z "$R_UUID" ] || [ -z "$R_PBK" ] || [ -z "$R_RELAY_CERT_B64" ]; then
        echo -e "  ${RED}${chosen} is missing REALITY/relay details - delete the VM and re-run.${RESET}"
        exit 1
    fi
    echo -e "  ${GREEN}VM ${R_VM_NAME}: ${R_VM_IP}  REALITY tcp/${R_PORT}  relay tcp/${R_RELAY_PORT}${RESET}"

    # OpenVPN on the same VM feeds /saeka-ovpn and /cert (tcp only).
    if [ "$(jget "$chosen" ovpn_enabled)" = "true" ]; then
        if [ "$(jget "$chosen" ovpn_proto)" = "tcp" ]; then
            OVPN_HOST="$R_VM_IP"
            OVPN_PORT=$(jget "$chosen" ovpn_port)
            OVPN_PROFILE_FILE="$info_dir/${R_VM_NAME}-client1.ovpn"
        else
            echo -e "  ${YELLOW}The VM's OpenVPN is proto udp - the Cloud Run relay needs tcp, so /saeka-ovpn is skipped.${RESET}"
        fi
    fi
}

OVPN_HOST=""
OVPN_PORT=""
OVPN_PROFILE_B64=""
if [ "$PROXY_ENV" == "ssh" ]; then
    echo -e "  ${CYAN}==================================================${RESET}"
    echo -e "  ${GREEN}           SSH GATEWAY - TUNNEL USERS${RESET}"
    echo -e "  ${CYAN}==================================================${RESET}"
    echo -e "  ${YELLOW}Path /saeka-ssh: HTTP Upgrade handshake, then raw SSH (for HTTP${RESET}"
    echo -e "  ${YELLOW}Injector / NPV Tunnel style clients, not RFC6455 framing).${RESET}"
    echo ""
    collect_users "the SSH gateway"
    echo ""
    ENV_VARS="^@^SSH_USERS=${SSH_USERS_CSV}"
    if [ "$AUTO" -eq 1 ]; then
        ADD_OVPN="${DEPLOY_ADD_OVPN:-N}"
        echo -e "  ${CYAN}Also relay OpenVPN (/saeka-ovpn) to a VM on this same service?${RESET} -> ${GREEN}${ADD_OVPN}${RESET}"
    else
        read -r -p "$(echo -e "  ${CYAN}Also relay OpenVPN (/saeka-ovpn) to a VM on this same service? [y/N]: ${RESET}")" ADD_OVPN
    fi
    if [[ "$ADD_OVPN" =~ ^[Yy] ]]; then
        echo -e "  ${YELLOW}The OpenVPN server on the VM must use proto tcp.${RESET}"
        prompt_ovpn_upstream
        ENV_VARS="${ENV_VARS}@OVPN_UPSTREAM_HOST=${OVPN_HOST}@OVPN_UPSTREAM_PORT=${OVPN_PORT}"
        prompt_ovpn_profile
        if [ -n "$OVPN_PROFILE_B64" ]; then
            ENV_VARS="${ENV_VARS}@OVPN_PROFILE_B64=${OVPN_PROFILE_B64}"
            if [ -z "$SSH_USERS_CSV" ]; then
                echo -e "  ${YELLOW}No users were added, so /cert will stay locked (503). Re-run with a user.${RESET}"
            fi
        fi
    fi
    echo ""
elif [ "$PROXY_ENV" == "ovpn-relay" ]; then
    echo -e "  ${CYAN}==================================================${RESET}"
    echo -e "  ${GREEN}           OVPN RELAY - UPSTREAM VM${RESET}"
    echo -e "  ${CYAN}==================================================${RESET}"
    echo -e "  ${YELLOW}This forwards /saeka-ovpn to a real OpenVPN server on a VM${RESET}"
    echo -e "  ${YELLOW}(deploy_vm.py). That server must use proto tcp, and the VM must${RESET}"
    echo -e "  ${YELLOW}already be running with its static IP ready.${RESET}"
    echo ""
    prompt_ovpn_upstream
    ENV_VARS="^@^OVPN_UPSTREAM_HOST=${OVPN_HOST}@OVPN_UPSTREAM_PORT=${OVPN_PORT}"
    prompt_ovpn_profile
    if [ -n "$OVPN_PROFILE_B64" ]; then
        echo -e "  ${CYAN}/cert needs a login - use the same user:pass as your OpenVPN users.${RESET}"
        collect_users "the /cert download login"
        if [ -n "$SSH_USERS_CSV" ]; then
            ENV_VARS="${ENV_VARS}@SSH_USERS=${SSH_USERS_CSV}@OVPN_PROFILE_B64=${OVPN_PROFILE_B64}"
        else
            echo -e "  ${YELLOW}No users given - /cert disabled (it never serves the key without a login).${RESET}"
            OVPN_PROFILE_B64=""
        fi
    fi
    echo ""
elif [ "$PROXY_ENV" == "reality" ]; then
    echo -e "  ${CYAN}==================================================${RESET}"
    echo -e "  ${GREEN}        REALITY COMBO - VM + CLOUD RUN RELAY${RESET}"
    echo -e "  ${CYAN}==================================================${RESET}"
    echo -e "  ${YELLOW}VM (deploy_vm.py): VLESS+XHTTP+REALITY on tcp/443 (direct), a TLS relay${RESET}"
    echo -e "  ${YELLOW}listener for Cloud Run, and optional OpenVPN (tcp).${RESET}"
    echo -e "  ${YELLOW}Cloud Run: SSH-WS, OpenVPN-WS, /cert and an XHTTP relay to the VM.${RESET}"
    echo ""
    if ! command -v python3 >/dev/null 2>&1; then
        echo -e "  ${RED}python3 is required for this engine (reads the VM info files).${RESET}"
        exit 1
    fi
    collect_users "SSH-WS, OpenVPN and the /cert download"
    if [ -z "$SSH_USERS_CSV" ]; then
        # OpenVPN logins and /cert both need at least one known user.
        pw=$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 16 || true)
        SSH_USERS_CSV="saeka:${pw}"
        echo -e "  ${GREEN}No user given - generated login saeka: ${pw}${RESET}"
        echo -e "  ${YELLOW}(shown once - write it down now)${RESET}"
    fi
    if [[ "$SSH_USERS_CSV" =~ [@[:space:]] ]]; then
        echo -e "  ${RED}SSH_USERS can't contain @ or whitespace (it is passed as a Cloud Run env var).${RESET}"
        exit 1
    fi
    echo ""
    prompt_reality_vm
    ENV_VARS="^@^SSH_USERS=${SSH_USERS_CSV}@XHTTP_UPSTREAM_HOST=${R_VM_IP}@XHTTP_UPSTREAM_PORT=${R_RELAY_PORT}@XHTTP_PATH=${R_RELAY_PATH}@XHTTP_RELAY_CERT_B64=${R_RELAY_CERT_B64}"
    if [ -n "$OVPN_HOST" ]; then
        ENV_VARS="${ENV_VARS}@OVPN_UPSTREAM_HOST=${OVPN_HOST}@OVPN_UPSTREAM_PORT=${OVPN_PORT}"
        prompt_ovpn_profile
        if [ -n "$OVPN_PROFILE_B64" ]; then
            ENV_VARS="${ENV_VARS}@OVPN_PROFILE_B64=${OVPN_PROFILE_B64}"
        fi
    fi
    echo ""
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

# Handshake check: a brand-new revision can 502/503 for a few seconds while
# the container finishes booting and IAM/routing settles, so poll instead of
# declaring victory on the first response. This only confirms Cloud Run is
# routing to a live container on *some* path (root 404 is fine - it means
# the proxy itself answered); it can't validate a specific VLESS/SSH login.
echo ""
echo -ne "  ${CYAN}Waiting for ${CLEAN_HOST} to answer (avoiding a cold-start 502)...${RESET}"
HANDSHAKE_OK=0
for _ in $(seq 1 15); do
    HS_CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 6 "https://${CLEAN_HOST}/" 2>/dev/null || echo "000")
    if [ "$HS_CODE" != "502" ] && [ "$HS_CODE" != "503" ] && [ "$HS_CODE" != "000" ]; then
        HANDSHAKE_OK=1
        break
    fi
    printf "."
    sleep 2
done
if [ "$HANDSHAKE_OK" -eq 1 ]; then
    echo -e "\r  ${GREEN}${CLEAN_HOST} is responding (HTTP ${HS_CODE}).${RESET}                                            "
else
    echo -e "\r  ${YELLOW}${CLEAN_HOST} is still returning ${HS_CODE} after ~30s.${RESET}                                            "
    echo -e "  ${YELLOW}Common causes: the container is crash-looping (check 'gcloud run services logs read ${SERVICE_NAME} --region ${REGION}'),${RESET}"
    echo -e "  ${YELLOW}or --port didn't match what the proxy actually listens on inside the image.${RESET}"
fi

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
echo -e "  ${YELLOW}------------------------------------------------------------${RESET}"
if [ "$PROXY_ENV" == "ssh" ]; then
    echo -e "  ${CYAN}                  SSH GATEWAY${RESET}"
    echo -e "  ${YELLOW}------------------------------------------------------------${RESET}"
    if [ -n "$SSH_USERS_CSV" ]; then
        echo -e "  ${CYAN}Users configured: ${GREEN}$(echo "$SSH_USERS_CSV" | tr ',' '\n' | cut -d: -f1 | paste -sd, -)${RESET}"
    else
        echo -e "  ${YELLOW}No users were added - a one-off random account was generated in${RESET}"
        echo -e "  ${YELLOW}the container logs (won't survive a redeploy). Re-run and add one.${RESET}"
    fi
    echo -e "  ${CYAN}Host    ${GREEN}${CLEAN_HOST}${CYAN}   Port ${GREEN}443 (TLS/SNI)${RESET}"
    echo -e "  ${CYAN}Payload ${GREEN}GET /saeka-ssh HTTP/1.1[crlf]Host: ${CLEAN_HOST}[crlf]Upgrade: websocket[crlf][crlf]${RESET}"
    echo -e "  ${CYAN}UDPGW   ${GREEN}127.0.0.1:7300${RESET}"
    if [ -n "$OVPN_HOST" ]; then
        echo -e "  ${CYAN}OpenVPN ${GREEN}GET /saeka-ovpn HTTP/1.1[crlf]Host: ${CLEAN_HOST}[crlf]Upgrade: websocket[crlf][crlf]${RESET}"
        echo -e "  ${CYAN}        ${GREEN}/saeka-ovpn -> ${OVPN_HOST}:${OVPN_PORT}${RESET}"
    fi
    if [ -n "$OVPN_PROFILE_B64" ] && [ -n "$SSH_USERS_CSV" ]; then
        echo -e "  ${CYAN}Profile ${GREEN}https://${CLEAN_HOST}/cert${CYAN}  (login: one of the users above)${RESET}"
    fi
elif [ "$PROXY_ENV" == "ovpn-relay" ]; then
    echo -e "  ${CYAN}                  OVPN RELAY${RESET}"
    echo -e "  ${YELLOW}------------------------------------------------------------${RESET}"
    echo -e "  ${CYAN}Forwards /saeka-ovpn to ${GREEN}${OVPN_HOST}:${OVPN_PORT}${RESET}"
    echo -e "  ${CYAN}Host    ${GREEN}${CLEAN_HOST}${CYAN}   Port ${GREEN}443 (TLS/SNI)${RESET}"
    echo -e "  ${CYAN}Payload ${GREEN}GET /saeka-ovpn HTTP/1.1[crlf]Host: ${CLEAN_HOST}[crlf]Upgrade: websocket[crlf][crlf]${RESET}"
    if [ -n "$OVPN_PROFILE_B64" ]; then
        echo -e "  ${CYAN}Profile ${GREEN}https://${CLEAN_HOST}/cert${CYAN}  (login: the /cert user you set)${RESET}"
    fi
elif [ "$PROXY_ENV" == "reality" ]; then
    REALITY_LINK="vless://${R_UUID}@${R_HOST}:${R_PORT}?encryption=none&security=reality&sni=${R_SNI}&fp=chrome&pbk=${R_PBK}&sid=${R_SID}&type=xhttp&path=$(urlenc_path "$R_PATH")&mode=${R_MODE}#saeka-reality-xhttp"
    RELAY_LINK="vless://${R_UUID}@${CLEAN_HOST}:443?encryption=none&security=tls&sni=${CLEAN_HOST}&fp=chrome&type=xhttp&host=${CLEAN_HOST}&path=$(urlenc_path "$R_RELAY_PATH")&mode=packet-up#saeka-cloudrun-xhttp"
    echo -e "  ${CYAN}              REALITY COMBO (VM + CLOUD RUN)${RESET}"
    echo -e "  ${YELLOW}------------------------------------------------------------${RESET}"
    echo -e "  ${CYAN}VM      ${GREEN}${R_VM_NAME} (${R_VM_IP})${RESET}"
    echo -e "  ${CYAN}Users   ${GREEN}$(echo "$SSH_USERS_CSV" | tr ',' '\n' | cut -d: -f1 | paste -sd, -)${RESET}"
    echo ""
    echo -e "  ${GREEN}1) DIRECT - VLESS + XHTTP + REALITY (VM, no Google in the path)${RESET}"
    echo -e "  ${WHITE}${REALITY_LINK}${RESET}"
    echo ""
    echo -e "  ${GREEN}2) VIA CLOUD RUN - VLESS + XHTTP + TLS (*.run.app, relayed to the VM)${RESET}"
    echo -e "  ${WHITE}${RELAY_LINK}${RESET}"
    echo ""
    echo -e "  ${GREEN}3) SSH-WS${RESET}   ${CYAN}Host ${CLEAN_HOST}  Port 443 (TLS/SNI)  UDPGW 127.0.0.1:7300${RESET}"
    echo -e "     ${CYAN}Payload ${GREEN}GET /saeka-ssh HTTP/1.1[crlf]Host: ${CLEAN_HOST}[crlf]Upgrade: websocket[crlf][crlf]${RESET}"
    if [ -n "$OVPN_HOST" ]; then
        echo -e "  ${GREEN}4) OpenVPN-WS${RESET}  ${CYAN}/saeka-ovpn -> ${OVPN_HOST}:${OVPN_PORT} (tcp)${RESET}"
        echo -e "     ${CYAN}Payload ${GREEN}GET /saeka-ovpn HTTP/1.1[crlf]Host: ${CLEAN_HOST}[crlf]Upgrade: websocket[crlf][crlf]${RESET}"
    fi
    if [ -n "$OVPN_PROFILE_B64" ]; then
        echo -e "  ${CYAN}Profile ${GREEN}https://${CLEAN_HOST}/cert${CYAN}  (login: one of the users above)${RESET}"
    fi

    # Keep everything in one private file so nothing is lost if the terminal scrolls.
    mkdir -p "$HOME/.deploy_vm"
    SUMMARY_FILE="$HOME/.deploy_vm/${SERVICE_NAME}-summary.txt"
    (
        umask 077
        {
            echo "Reality Combo - ${SERVICE_NAME} - $(date -u +%Y-%m-%dT%H:%M:%SZ)"
            echo "Cloud Run host : ${CLEAN_HOST}"
            echo "VM             : ${R_VM_NAME} (${R_VM_IP})"
            echo "Users          : $(echo "$SSH_USERS_CSV" | tr ',' '\n' | cut -d: -f1 | paste -sd, -)"
            echo ""
            echo "DIRECT (REALITY + XHTTP):"
            echo "${REALITY_LINK}"
            echo ""
            echo "VIA CLOUD RUN (TLS + XHTTP, packet-up):"
            echo "${RELAY_LINK}"
            echo ""
            echo "SSH-WS payload: GET /saeka-ssh HTTP/1.1[crlf]Host: ${CLEAN_HOST}[crlf]Upgrade: websocket[crlf][crlf]"
            if [ -n "$OVPN_HOST" ]; then
                echo "OpenVPN-WS payload: GET /saeka-ovpn HTTP/1.1[crlf]Host: ${CLEAN_HOST}[crlf]Upgrade: websocket[crlf][crlf]"
            fi
            if [ -n "$OVPN_PROFILE_B64" ]; then
                echo "OpenVPN profile: https://${CLEAN_HOST}/cert"
            fi
        } > "$SUMMARY_FILE"
    )
    echo ""
    echo -e "  ${CYAN}Saved to ${GREEN}${SUMMARY_FILE}${CYAN} (private, mode 600).${RESET}"
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

echo -e "  ${CYAN}==================================================${RESET}"
echo -e "  ${GREEN}       CUSTOM DOMAIN & UNIVERSAL SNI MANAGER${RESET}"
echo -e "  ${CYAN}==================================================${RESET}"
echo -e "  ${YELLOW}Google Managed Certs take 15-60 mins. To bypass the wait, you have options:${RESET}"
echo -e "  ${WHITE}1) Enter a Domain : ${YELLOW}Auto-generates Google cert (Stacks all past domains. Takes up to 1 hr)${RESET}"
echo -e "  ${WHITE}2) Type UNIVERSAL : ${YELLOW}Instant self-signed cert. (Use with Cloudflare 'Full' SSL for instant valid cert!)${RESET}"
echo -e "  ${WHITE}3) Type LOCAL     : ${YELLOW}Instantly uploads your own 'cert.pem' and 'key.pem' from this folder.${RESET}"
echo ""
if [ "$AUTO" -eq 1 ]; then
    # Default: skip the custom-domain/LB dance entirely and just use the
    # *.run.app host Cloud Run already gives you a valid TLS cert for - that
    # host works immediately with no propagation wait and no 502 from a
    # half-provisioned load balancer. Set DEPLOY_LB_INPUT if you actually
    # want a custom domain (Domain / UNIVERSAL / LOCAL).
    LB_INPUT="${DEPLOY_LB_INPUT:-}"
    if [ -n "$LB_INPUT" ]; then
        echo -e "  ${CYAN}Custom domain / LB input${RESET} -> ${GREEN}${LB_INPUT}${RESET}"
    else
        echo -e "  ${CYAN}Skipping custom domain/LB step - using the raw *.run.app host.${RESET}"
    fi
else
    read -r -p "$(echo -e "  ${CYAN}Input (Domain / UNIVERSAL / LOCAL) or blank to skip: ${RESET}")" LB_INPUT
fi

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

    CERT_DIR=$(mktemp -d)
    FINAL_CERTS=""
    CERT_TEMP="${SERVICE_NAME}-tmp-$(date +%s)"
    CERT_MANAGED="${SERVICE_NAME}-mng-$(date +%s)"

    if [ "$LB_INPUT" == "UNIVERSAL" ]; then
        echo -e "  ${CYAN}Provisioning Universal SNI (Self-Signed) Certificate...${RESET}"
        run_quiet "Generating self-signed cert" lb.log \
            openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
            -keyout "$CERT_DIR/key.pem" -out "$CERT_DIR/cert.pem" -subj "/CN=cloudfront.net" 2>/dev/null || lb_setup_failed=1

        run_quiet "Uploading self-managed cert to GCP" lb.log \
            gcloud compute ssl-certificates create "$CERT_TEMP" \
                --certificate="$CERT_DIR/cert.pem" --private-key="$CERT_DIR/key.pem" \
                --global --project="$PROJECT_ID" || lb_setup_failed=1

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
            -keyout "$CERT_DIR/key.pem" -out "$CERT_DIR/cert.pem" -subj "/CN=${LB_INPUT}" 2>/dev/null || lb_setup_failed=1
        run_quiet "Uploading instant temporary cert" lb.log \
            gcloud compute ssl-certificates create "$CERT_TEMP" \
                --certificate="$CERT_DIR/cert.pem" --private-key="$CERT_DIR/key.pem" \
                --global --project="$PROJECT_ID" || lb_setup_failed=1

        run_quiet "Requesting real managed cert for ${DOMAINS_CSV}" lb.log \
            gcloud compute ssl-certificates create "$CERT_MANAGED" \
                --domains="$DOMAINS_CSV" --global --project="$PROJECT_ID" || lb_setup_failed=1

        FINAL_CERTS="${CERT_TEMP},${CERT_MANAGED}"
        FINAL_HOST="$LB_INPUT"
    fi

    rm -rf "$CERT_DIR"
    if [ -z "$FINAL_CERTS" ]; then
        lb_setup_failed=1
    fi

    if [ "$lb_setup_failed" -ne 0 ]; then
        :
    elif ! gcloud compute target-https-proxies describe "$HTTPS_PROXY_NAME" --global --project="$PROJECT_ID" >/dev/null 2>&1; then
        run_quiet "Creating HTTPS proxy with cert(s)" lb.log \
            gcloud compute target-https-proxies create "$HTTPS_PROXY_NAME" \
                --url-map="$URLMAP_NAME" --ssl-certificates="$FINAL_CERTS" \
                --global --project="$PROJECT_ID" || lb_setup_failed=1
    else
        run_quiet "Repointing HTTPS proxy to new cert(s)" lb.log \
            gcloud compute target-https-proxies update "$HTTPS_PROXY_NAME" \
                --ssl-certificates="$FINAL_CERTS" --global --project="$PROJECT_ID" || lb_setup_failed=1
    fi

    if [ "$lb_setup_failed" -eq 0 ] && ! gcloud compute forwarding-rules describe "$FWD_RULE_NAME" --global --project="$PROJECT_ID" >/dev/null 2>&1; then
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
        if [ "$PROXY_ENV" == "reality" ]; then
            echo -e "  ${CYAN}Reality Combo: for the Cloud Run link (#2) swap the host and sni for ${GREEN}${FINAL_HOST}${CYAN} if you use this LB.${RESET}"
        fi
    else
        echo -e "  ${RED}Load balancer setup hit an error above - falling back to the raw Cloud Run host.${RESET}"
        FINAL_HOST="$CLEAN_HOST"
    fi
    rm -f lb.log
    echo ""
fi

if [ "$STANDALONE" -eq 0 ]; then
    echo -e "  ${CYAN}Generate client links / outbound JSON with:${RESET}"
    echo -e "  ${GREEN}./generate-client-links.sh ${FINAL_HOST}${RESET}"
    echo ""
fi

rm -f build.log deploy.log lb.log
echo -e "  ${GREEN}Deployer session complete.${RESET}"
