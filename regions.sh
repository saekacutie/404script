#!/bin/bash
# ==============================================================================
# REGION SELECTION MODULE  (sourced by deploy.sh; needs PROJECT_ID)
# ==============================================================================
# Builds the region list live from Cloud Run (so you only see regions your
# project can really deploy to), removes regions forbidden by an organization
# location policy (constraints/gcp.resourceLocations), then either:
#   - auto-selects REGION_HINT (--region, XGCPX_REGION, CLOUDSDK_COMPUTE_REGION
#     or `gcloud config compute/region`), or
#   - shows a numbered menu (default: us-central1).
# Exports REGION.

DIM="${DIM:-\033[2m}"

region_label() {
    case "$1" in
        us-central1) printf 'Iowa, USA' ;;
        us-east1) printf 'South Carolina, USA' ;;
        us-east4) printf 'Northern Virginia, USA' ;;
        us-east5) printf 'Columbus, USA' ;;
        us-south1) printf 'Dallas, USA' ;;
        us-west1) printf 'Oregon, USA' ;;
        us-west2) printf 'Los Angeles, USA' ;;
        us-west3) printf 'Salt Lake City, USA' ;;
        us-west4) printf 'Las Vegas, USA' ;;
        northamerica-northeast1) printf 'Montreal, Canada' ;;
        northamerica-northeast2) printf 'Toronto, Canada' ;;
        northamerica-south1) printf 'Mexico' ;;
        southamerica-east1) printf 'Sao Paulo, Brazil' ;;
        southamerica-west1) printf 'Santiago, Chile' ;;
        europe-west1) printf 'Belgium' ;;
        europe-west2) printf 'London, UK' ;;
        europe-west3) printf 'Frankfurt, Germany' ;;
        europe-west4) printf 'Netherlands' ;;
        europe-west6) printf 'Zurich, Switzerland' ;;
        europe-west8) printf 'Milan, Italy' ;;
        europe-west9) printf 'Paris, France' ;;
        europe-west10) printf 'Berlin, Germany' ;;
        europe-west12) printf 'Turin, Italy' ;;
        europe-north1) printf 'Finland' ;;
        europe-north2) printf 'Stockholm, Sweden' ;;
        europe-central2) printf 'Warsaw, Poland' ;;
        europe-southwest1) printf 'Madrid, Spain' ;;
        asia-east1) printf 'Taiwan' ;;
        asia-east2) printf 'Hong Kong' ;;
        asia-northeast1) printf 'Tokyo, Japan' ;;
        asia-northeast2) printf 'Osaka, Japan' ;;
        asia-northeast3) printf 'Seoul, South Korea' ;;
        asia-south1) printf 'Mumbai, India' ;;
        asia-south2) printf 'Delhi, India' ;;
        asia-southeast1) printf 'Singapore' ;;
        asia-southeast2) printf 'Jakarta, Indonesia' ;;
        asia-southeast3) printf 'Bangkok, Thailand' ;;
        australia-southeast1) printf 'Sydney, Australia' ;;
        australia-southeast2) printf 'Melbourne, Australia' ;;
        me-central1) printf 'Doha, Qatar' ;;
        me-central2) printf 'Dammam, Saudi Arabia' ;;
        me-west1) printf 'Tel Aviv, Israel' ;;
        africa-south1) printf 'Johannesburg, South Africa' ;;
        *) printf '%s' "$1" ;;
    esac
}

_region_fail() { echo -e "  ${RED}ERROR: $*${RESET}" >&2; exit 1; }

_RG_TMP_RUN="$(mktemp "${TMPDIR:-/tmp}/404-run-regions.XXXXXX")"
_RG_TMP_POLICY="$(mktemp "${TMPDIR:-/tmp}/404-location-policy.XXXXXX")"

echo -e "  ${CYAN}Checking which regions ${PROJECT_ID} can deploy Cloud Run to...${RESET}"

REGIONS=()
# A just-enabled API can take a few seconds to answer, so try twice, and keep the
# real error to show if it still fails.
_RG_ERR="${_RG_TMP_RUN}.err"
_regions_ok=0
for _try in 1 2; do
    if gcloud run regions list --project="$PROJECT_ID" --format=json >"$_RG_TMP_RUN" 2>"$_RG_ERR"; then
        _regions_ok=1
        break
    fi
    [ "$_try" -eq 1 ] && sleep 5
done
if [ "$_regions_ok" -eq 1 ]; then
    {
        gcloud org-policies describe gcp.resourceLocations --effective --project="$PROJECT_ID" --format=json 2>/dev/null \
            || gcloud resource-manager org-policies describe gcp.resourceLocations --effective --project="$PROJECT_ID" --format=json 2>/dev/null \
            || printf '{}'
    } >"$_RG_TMP_POLICY"

    # Output: one region name per line, sorted; REMOVED=<n> on stderr if the
    # location policy filtered anything out.
    REGION_ROWS="$(python3 -I - "$_RG_TMP_RUN" "$_RG_TMP_POLICY" 2>"${_RG_TMP_POLICY}.err" <<'PY' || true
import json
import sys

def load(path, default):
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return default

run_regions = load(sys.argv[1], [])
policy = load(sys.argv[2], {})

def location_name(item):
    if isinstance(item, str):
        return item.rsplit("/locations/", 1)[-1]
    if not isinstance(item, dict):
        return ""
    for key in ("locationId", "name", "uri"):
        value = item.get(key, "")
        if "/locations/" in value:
            return value.rsplit("/locations/", 1)[1]
        if value and "/" not in value:
            return value
    return ""

names = sorted({n for n in map(location_name, run_regions) if n})

allowed, denied = set(), set()
def collect(node):
    if isinstance(node, dict):
        for key, value in node.items():
            if key == "allowedValues":
                allowed.update(value)
            elif key == "deniedValues":
                denied.update(value)
            else:
                collect(value)
    elif isinstance(node, list):
        for entry in node:
            collect(entry)
collect(policy)

def matches(region, values):
    for value in values:
        value = value.strip()
        if value.startswith("in:"):
            value = value[3:]
        if value.endswith("-locations"):
            group = value[: -len("-locations")]
            group = "europe" if group == "eu" else group
            if region == group or region.startswith(group + "-"):
                return True
        elif value == region:
            return True
    return False

kept = [n for n in names
        if not (allowed and not matches(n, allowed)) and not matches(n, denied)]
print("\n".join(kept))
if len(kept) != len(names):
    print("REMOVED=%d" % (len(names) - len(kept)), file=sys.stderr)
PY
)"
    if grep -q '^REMOVED=' "${_RG_TMP_POLICY}.err" 2>/dev/null; then
        echo -e "  ${YELLOW}An organization location policy applies; regions it forbids were removed from the list.${RESET}"
    fi
    rm -f -- "${_RG_TMP_POLICY}.err"
    if [ -n "$REGION_ROWS" ]; then mapfile -t REGIONS <<<"$REGION_ROWS"; fi
else
    _why="$(grep -m1 -iE 'denied|forbidden|not been used|disabled|not enabled|error' "$_RG_ERR" 2>/dev/null | cut -c1-150 || true)"
    echo -e "  ${YELLOW}Could not query Cloud Run regions${_why:+ ($_why)}; using the built-in list.${RESET}"
fi
rm -f -- "$_RG_TMP_RUN" "$_RG_TMP_POLICY" "$_RG_ERR"

if [ "${#REGIONS[@]}" -eq 0 ]; then
    REGIONS=(us-central1 us-east1 us-west1 asia-east1 asia-southeast1 europe-west1 europe-west4)
fi

# --- Resolve a configured region, if any ------------------------------------
REGION_HINT="${REGION_HINT:-${XGCPX_REGION:-${CLOUDSDK_COMPUTE_REGION:-}}}"
REGION_HINT_SOURCE="${REGION_HINT_SOURCE:-}"
if [ -n "$REGION_HINT" ] && [ -z "$REGION_HINT_SOURCE" ]; then REGION_HINT_SOURCE="environment"; fi
if [ -z "$REGION_HINT" ]; then
    _cfg="$(gcloud config get-value compute/region 2>/dev/null || true)"
    if [ -n "$_cfg" ] && [ "$_cfg" != "(unset)" ]; then
        REGION_HINT="$_cfg"; REGION_HINT_SOURCE="gcloud config"
    fi
fi

REGION=""
if [ -n "$REGION_HINT" ]; then
    for _r in "${REGIONS[@]}"; do
        if [ "$_r" == "$REGION_HINT" ]; then REGION="$_r"; break; fi
    done
    if [ -n "$REGION" ]; then
        echo -e "  ${GREEN}Auto-selected ${REGION} from ${REGION_HINT_SOURCE} ($(region_label "$REGION")).${RESET}"
    elif [ "$REGION_HINT_SOURCE" == "--region" ] || [ "$REGION_HINT_SOURCE" == "environment" ]; then
        _region_fail "Configured region '${REGION_HINT}' is not available for project ${PROJECT_ID}."
    else
        echo -e "  ${YELLOW}Configured gcloud region '${REGION_HINT}' is not available here; choose one below.${RESET}"
    fi
fi

# --- Otherwise ask ------------------------------------------------------------
if [ -z "$REGION" ]; then
    _default_idx=-1
    for _i in "${!REGIONS[@]}"; do
        if [ "${REGIONS[_i]}" == "us-central1" ]; then _default_idx="$_i"; break; fi
    done

    if [ -t 0 ]; then
        [ "$_default_idx" -lt 0 ] && _default_idx=0
        echo ""
        echo -e "  ${CYAN}SELECT A REGION. You cannot change it afterwards, and make sure your lab/project supports it.${RESET}"
        echo ""
        for _i in "${!REGIONS[@]}"; do
            _suffix=""
            [ "$_i" -eq "$_default_idx" ] && _suffix=" (default)"
            printf '  %b%2d)%b %-26s %b%s%s%b\n' "$YELLOW" "$((_i + 1))" "$RESET" "${REGIONS[_i]}" \
                "$DIM" "$(region_label "${REGIONS[_i]}")" "$_suffix" "$RESET"
        done
        echo ""
        while :; do
            read -r -p "$(echo -e "  ${CYAN}CHOICE [1-${#REGIONS[@]}, default $((_default_idx + 1))]: ${RESET}")" REGION_CHOICE || REGION_CHOICE=""
            REGION_CHOICE="${REGION_CHOICE:-$((_default_idx + 1))}"
            if [[ "$REGION_CHOICE" =~ ^[0-9]+$ ]] && [ "$REGION_CHOICE" -ge 1 ] && [ "$REGION_CHOICE" -le "${#REGIONS[@]}" ]; then
                break
            fi
            echo -e "  ${YELLOW}Enter a number from 1 to ${#REGIONS[@]}.${RESET}"
        done
        REGION="${REGIONS[$((REGION_CHOICE - 1))]}"
    elif [ "$_default_idx" -ge 0 ]; then
        REGION="us-central1"
        echo -e "  ${YELLOW}No region configured; using us-central1. Pass --region or set XGCPX_REGION to choose another.${RESET}"
    else
        _region_fail "No region configured and us-central1 is unavailable. Pass --region or set XGCPX_REGION."
    fi
fi

export REGION
echo -e "  ${GREEN}REGION: ${REGION} ($(region_label "$REGION"))${RESET}"
echo ""
