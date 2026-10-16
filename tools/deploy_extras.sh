#!/usr/bin/env bash
# Deployment helpers kept in deploy.sh-compatible form.
# This file is intentionally sourceable by deploy.sh and by local deployment wrappers.

valid_hostname() {
    [[ "$1" =~ ^[A-Za-z0-9.-]+$ && "$1" != .* && "$1" != *..* && "$1" != *. && "$1" != -* ]]
}

prompt_custom_banner() {
    local engine="$1" banner_file="${SCRIPT_DIR}/proxies/${engine}/banner.txt"
    local answer editor before
    BANNER_FILE=""
    BANNER_ENABLED="false"
    [[ -f "$banner_file" ]] || return 0

    if [[ "$AUTO" -eq 1 ]]; then
        answer="${DEPLOY_CUSTOM_BANNER:-n}"
        echo -e "  ${CYAN}Custom SSH banner${RESET} -> ${GREEN}${answer}${RESET}"
    else
        read -r -p "  Enable custom SSH banner editing? [y/N]: " answer
    fi
    [[ "$answer" =~ ^[Yy]$ ]] || return 0

    editor="${EDITOR:-${VISUAL:-nano}}"
    if ! command -v "${editor%% *}" >/dev/null 2>&1; then
        echo -e "  ${YELLOW}Editor '$editor' was not found; banner unchanged.${RESET}"
        return 0
    fi
    before=$(mktemp)
    cp -- "$banner_file" "$before"
    echo -e "  ${CYAN}Opening ${banner_file}.${RESET} Save with Ctrl+O, confirm, then exit with Ctrl+X."
    "$editor" "$banner_file"

    if cmp -s "$before" "$banner_file"; then
        echo -e "  ${YELLOW}Banner unchanged.${RESET}"
    elif [[ ! -s "$banner_file" ]]; then
        echo -e "  ${RED}Banner is empty; restoring the previous banner.${RESET}"
        cp -- "$before" "$banner_file"
    else
        BANNER_FILE="$banner_file"
        BANNER_ENABLED="true"
        echo -e "  ${GREEN}Banner saved and detected: ${banner_file}${RESET}"
    fi
    rm -f "$before"
}

check_proxy_domain() {
    local domain="$1" expected_ip="${2:-}" port="${3:-443}"
    local ips cert_file http_code
    DOMAIN_CHECK_STATUS="INVALID"
    DOMAIN_CHECK_DETAILS=""
    valid_hostname "$domain" || { DOMAIN_CHECK_DETAILS="invalid hostname syntax"; return 1; }

    ips=$(getent ahostsv4 "$domain" 2>/dev/null | awk '{print $1}' | sort -u | paste -sd, -)
    [[ -n "$ips" ]] || { DOMAIN_CHECK_DETAILS="no IPv4 DNS answer"; return 1; }
    if [[ -n "$expected_ip" && ",$ips," != *",$expected_ip,"* ]]; then
        DOMAIN_CHECK_DETAILS="DNS=$ips; expected=$expected_ip"
        return 1
    fi

    cert_file=$(mktemp)
    if ! timeout 12 openssl s_client -connect "${domain}:${port}" -servername "$domain" -showcerts </dev/null 2>/dev/null \
        | openssl x509 -outform PEM >"$cert_file" 2>/dev/null; then
        rm -f "$cert_file"
        DOMAIN_CHECK_DETAILS="TLS handshake failed"
        return 1
    fi
    if ! openssl x509 -in "$cert_file" -noout -checkhost "$domain" >/dev/null 2>&1; then
        DOMAIN_CHECK_DETAILS="certificate does not match SNI ${domain}"
        rm -f "$cert_file"
        return 1
    fi
    http_code=$(curl -kLsS -o /dev/null -w '%{http_code}' --connect-timeout 8 --max-time 15 "https://${domain}/health" 2>/dev/null || true)
    rm -f "$cert_file"
    DOMAIN_CHECK_STATUS="MATCH"
    DOMAIN_CHECK_DETAILS="DNS=$ips; certificate matches SNI; HTTPS /health=${http_code:-000}"
    return 0
}

prompt_proxy_domain() {
    local answer
    PROXY_DOMAIN=""
    PROXY_SNI=""
    PROXY_HOST=""
    PROXY_PORT="443"
    DOMAIN_CHECK_STATUS="SKIPPED"
    DOMAIN_CHECK_DETAILS=""

    if [[ "$AUTO" -eq 1 ]]; then
        PROXY_DOMAIN="${DEPLOY_PROXY_DOMAIN:-}"
        [[ -n "$PROXY_DOMAIN" ]] || return 0
        echo -e "  ${CYAN}Proxy domain/SNI${RESET} -> ${GREEN}${PROXY_DOMAIN}${RESET}"
    else
        read -r -p "  Optional proxy domain/SNI (blank = use the Cloud Run host): " PROXY_DOMAIN
    fi
    [[ -n "$PROXY_DOMAIN" ]] || return 0

    if check_proxy_domain "$PROXY_DOMAIN" "${PROXY_EXPECTED_IP:-}" 443; then
        echo -e "  ${GREEN}Domain check: MATCH — ${DOMAIN_CHECK_DETAILS}${RESET}"
    else
        echo -e "  ${RED}Domain check: ${DOMAIN_CHECK_STATUS} — ${DOMAIN_CHECK_DETAILS}${RESET}"
        if [[ "$AUTO" -eq 1 ]]; then
            answer="${DEPLOY_USE_UNVERIFIED_PROXY_DOMAIN:-n}"
        else
            read -r -p "  Use this domain anyway? [y/N]: " answer
        fi
        if [[ ! "$answer" =~ ^[Yy]$ ]]; then
            PROXY_DOMAIN=""
            return 1
        fi
        echo -e "  ${YELLOW}Using an unverified domain; TLS verification should remain enabled.${RESET}"
    fi
    PROXY_SNI="${DEPLOY_PROXY_SNI:-$PROXY_DOMAIN}"
    PROXY_HOST="${DEPLOY_PROXY_HOST:-$PROXY_DOMAIN}"
}

append_env_var() {
    local key="$1" value="$2"
    [[ -n "$value" ]] && ENV_VARS="${ENV_VARS}@${key}=${value}"
}

wire_proxy_env() {
    [[ -n "${PROXY_DOMAIN:-}" ]] || return 0
    append_env_var PROXY_DOMAIN "$PROXY_DOMAIN"
    append_env_var PROXY_SNI "${PROXY_SNI:-$PROXY_DOMAIN}"
    append_env_var PROXY_HOST "${PROXY_HOST:-$PROXY_DOMAIN}"
    append_env_var PROXY_PORT "${PROXY_PORT:-443}"
    append_env_var PROXY_DOMAIN_STATUS "${DOMAIN_CHECK_STATUS:-SKIPPED}"
}

wire_banner_env() {
    [[ "${BANNER_ENABLED:-false}" == "true" && -n "${BANNER_FILE:-}" ]] || return 0
    local encoded
    encoded=$(base64 -w0 < "$BANNER_FILE")
    append_env_var DROPBEAR_BANNER_B64 "$encoded"
    append_env_var DROPBEAR_BANNER_ENABLED true
}
