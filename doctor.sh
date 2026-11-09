#!/bin/bash
# ==============================================================================
# doctor.sh - find out why Cloud Build / deploy fails on this Google Cloud account
# ==============================================================================
# Usage:   bash doctor.sh            full check, incl. 3 tiny throwaway test builds
#          bash doctor.sh --no-build read-only checks only
#
# Run it in Cloud Shell, in the project you deploy to. It prints a report and
# saves the same text to ./doctor-report.txt so you can paste it for help.
# The report contains your project id and account email, but no passwords/tokens.
#
# What it changes: nothing, except (without --no-build) a few ~20 second builds
# that only print a word. No image is pushed and nothing is deployed.
# ==============================================================================
set -uo pipefail

NO_BUILD=0
[ "${1:-}" = "--no-build" ] && NO_BUILD=1

OUT="doctor-report.txt"
: > "$OUT"
say()  { printf '%s\n' "$*" | tee -a "$OUT"; }
ok()   { say "  [ OK ] $*"; }
bad()  { say "  [FAIL] $*"; }
note() { say "  [ .. ] $*"; }
head2() { say ""; say "== $* =="; }
# print the first meaningful lines of a command's error output, indented
indent() { cut -c1-200 | sed 's/^/           /' | tee -a "$OUT"; }
errline() { grep -m "${2:-2}" -iE 'error|denied|forbidden|not been used|disabled|permission|not found|invalid' "$1" 2>/dev/null | indent; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/doctor.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

PROJECT_ID=$(gcloud config get-value project 2>/dev/null | tr -d '[:space:]')
ACCOUNT=$(gcloud config get-value account 2>/dev/null | tr -d '[:space:]')

say "404script doctor  ($(date -u +%Y-%m-%dT%H:%MZ))"
head2 "1. Environment"
say "  gcloud:        $(gcloud --version 2>/dev/null | head -n1)"
say "  account:       ${ACCOUNT:-<none>}"
say "  project:       ${PROJECT_ID:-<none>}"
say "  quota project: $(gcloud config get-value billing/quota_project 2>/dev/null | tr -d '[:space:]') (unset = CURRENT_PROJECT; env CLOUDSDK_BILLING_QUOTA_PROJECT='${CLOUDSDK_BILLING_QUOTA_PROJECT:-}')"
[ -n "${PROJECT_ID:-}" ] || { bad "No active project. Run: gcloud config set project <PROJECT_ID>"; exit 1; }
[ -n "${ACCOUNT:-}" ]    || { bad "Not logged in. Run: gcloud auth login"; exit 1; }

PROJECT_NUMBER=""
if gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)' >"$TMP/pd" 2>"$TMP/pd.err"; then
    PROJECT_NUMBER=$(tr -d '[:space:]' <"$TMP/pd")
    ok "project reachable (number ${PROJECT_NUMBER})"
else
    bad "can't read the project:"; errline "$TMP/pd.err"
fi

# ---------------------------------------------------------------- APIs
head2 "2. APIs (real enabled list)"
API_LIST_OK=0
if gcloud services list --enabled --project="$PROJECT_ID" --format='value(config.name)' >"$TMP/apis" 2>"$TMP/apis.err"; then
    API_LIST_OK=1
    for api in run cloudbuild artifactregistry storage serviceusage cloudresourcemanager iam logging; do
        if grep -qx "${api}.googleapis.com" "$TMP/apis"; then ok "${api}.googleapis.com enabled"
        else bad "${api}.googleapis.com NOT enabled"; fi
    done
else
    bad "can't list enabled APIs (needs serviceusage.services.list):"; errline "$TMP/apis.err"
fi

# ---------------------------------------------------------------- permissions
head2 "3. What this account is allowed to do (project level)"
PERMS=(
 "serviceusage.services.use|use the project for API quota - without it gcloud's default mode is refused (deploy.sh then uses LEGACY mode)"
 "serviceusage.services.enable|enable APIs"
 "cloudbuild.builds.create|start Cloud Build builds - REQUIRED to build"
 "cloudbuild.builds.get|read build status"
 "logging.logEntries.list|read build logs (without it a failed build shows no reason)"
 "storage.buckets.create|create buckets (visitor counter, build staging)"
 "storage.buckets.get|read bucket info"
 "storage.objects.create|upload build source"
 "artifactregistry.repositories.create|create an image repository"
 "artifactregistry.repositories.uploadArtifacts|push images"
 "run.services.create|create Cloud Run services - REQUIRED to deploy"
 "run.services.update|update Cloud Run services"
 "iam.serviceAccounts.actAs|deploy as the runtime service account - REQUIRED to deploy"
 "resourcemanager.projects.setIamPolicy|change project IAM"
)
TOKEN=$(gcloud auth print-access-token 2>/dev/null | tr -d '[:space:]')
test_perms() {   # '"a","b"' -> granted perms on stdout; exit 2 if the API call failed
    local hdr resp
    for hdr in "x-goog-user-project: ${PROJECT_ID}" "x-doctor: 1"; do
        resp=$(curl -s --max-time 15 -X POST -H "Authorization: Bearer ${TOKEN}" -H "$hdr" \
            -H "Content-Type: application/json" -d "{\"permissions\":[$1]}" \
            "https://cloudresourcemanager.googleapis.com/v1/projects/${PROJECT_ID}:testIamPermissions" 2>/dev/null || true)
        if printf '%s' "$resp" | python3 -I -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(2)
if "error" in d:
    sys.exit(2)
print(" ".join(d.get("permissions", [])))
' 2>/dev/null; then return 0; fi
    done
    return 2
}
HAVE=""
SCAN_OK=0
if [ -n "$TOKEN" ]; then
    list=""
    for e in "${PERMS[@]}"; do list="$list\"${e%%|*}\","; done
    if HAVE=$(test_perms "${list%,}"); then SCAN_OK=1
    else
        HAVE=""
        for e in "${PERMS[@]}"; do
            if out=$(test_perms "\"${e%%|*}\""); then SCAN_OK=1; HAVE="$HAVE $out"; fi
        done
    fi
fi
can() { [ "$SCAN_OK" -eq 1 ] && [[ " $HAVE " == *" $1 "* ]]; }
if [ "$SCAN_OK" -eq 1 ]; then
    for e in "${PERMS[@]}"; do
        p=${e%%|*}; why=${e#*|}
        if can "$p"; then ok "$p"; else bad "$p  - can't: $why"; fi
    done
else
    note "permission check unavailable (couldn't call testIamPermissions)"
fi

head2 "4. Roles granted to ${ACCOUNT}"
if gcloud projects get-iam-policy "$PROJECT_ID" --flatten='bindings[].members' \
     --filter="bindings.members:${ACCOUNT}" --format='value(bindings.role)' >"$TMP/roles" 2>"$TMP/roles.err"; then
    if [ -s "$TMP/roles" ]; then sed 's/^/  /' "$TMP/roles" | tee -a "$OUT"
    else note "no direct project roles (access may come from a group or a lab-specific policy)"; fi
else
    note "can't read the project IAM policy (needs resourcemanager.projects.getIamPolicy)"
fi

# ---------------------------------------------------------------- quota project / buckets
head2 "5. Does the quota-project mode matter? (the 'forbidden from accessing the bucket' error)"
QUOTA_DEFAULT_OK=0; QUOTA_LEGACY_OK=0
if gcloud storage ls --project="$PROJECT_ID" >"$TMP/q1" 2>"$TMP/q1.err"; then QUOTA_DEFAULT_OK=1; ok "bucket list works in default mode"
else bad "bucket list FAILS in default mode:"; errline "$TMP/q1.err"; fi
if CLOUDSDK_BILLING_QUOTA_PROJECT=LEGACY gcloud storage ls --project="$PROJECT_ID" >"$TMP/q2" 2>"$TMP/q2.err"; then QUOTA_LEGACY_OK=1; ok "bucket list works in LEGACY mode"
else bad "bucket list FAILS in LEGACY mode:"; errline "$TMP/q2.err"; fi
if grep -q "${PROJECT_ID}_cloudbuild" "$TMP/q1" "$TMP/q2" 2>/dev/null; then note "Cloud Build's default bucket gs://${PROJECT_ID}_cloudbuild exists"
else note "Cloud Build's default bucket gs://${PROJECT_ID}_cloudbuild does not exist yet (the first build creates it)"; fi

# ---------------------------------------------------------------- org policy / SAs / registry
head2 "6. Organization policies that affect builds"
for c in cloudbuild.useComputeServiceAccount cloudbuild.useBuildServiceAccount cloudbuild.disableCreateDefaultServiceAccount \
         iam.allowedPolicyMemberDomains gcp.resourceLocations; do
    if gcloud org-policies describe "constraints/$c" --effective --project="$PROJECT_ID" >"$TMP/op" 2>"$TMP/op.err"; then
        if grep -qE 'enforce: true|allowedValues|deniedValues|allowAll: false' "$TMP/op"; then note "$c: RESTRICTED"; else note "$c: not restricted"; fi
    else
        note "$c: not readable"
    fi
done

head2 "7. Service accounts and image registry"
if [ -n "$PROJECT_NUMBER" ]; then
    SA="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"
    if gcloud iam service-accounts describe "$SA" --project="$PROJECT_ID" >/dev/null 2>"$TMP/sa.err"; then ok "default compute service account exists ($SA)"
    else note "can't confirm the default compute service account:"; errline "$TMP/sa.err" 1; fi
fi
if gcloud artifacts repositories list --project="$PROJECT_ID" --format='value(name)' >"$TMP/ar" 2>"$TMP/ar.err"; then
    if [ -s "$TMP/ar" ]; then ok "Artifact Registry repos:"; sed 's#.*/##; s/^/           /' "$TMP/ar" | sort -u | head -n 8 | tee -a "$OUT"
    else note "no Artifact Registry repos yet"; fi
else
    bad "can't list Artifact Registry repos:"; errline "$TMP/ar.err"
fi

head2 "8. Recent builds"
if gcloud builds list --project="$PROJECT_ID" --limit=3 --format='table(id.slice(0:8),status,createTime.date("%m-%d %H:%M"))' >"$TMP/bl" 2>"$TMP/bl.err"; then
    if [ -s "$TMP/bl" ]; then sed 's/^/  /' "$TMP/bl" | tee -a "$OUT"; else note "no builds yet"; fi
    LAST_FAILED=$(gcloud builds list --project="$PROJECT_ID" --filter='status=FAILURE' --limit=1 --format='value(id)' 2>/dev/null | tr -d '[:space:]')
    if [ -n "$LAST_FAILED" ]; then
        note "most recent FAILED build ${LAST_FAILED:0:8}:"
        gcloud builds describe "$LAST_FAILED" --project="$PROJECT_ID" --format='value(statusDetail,failureInfo.type,failureInfo.detail)' 2>/dev/null | head -n 3 | indent
    fi
else
    bad "can't list builds:"; errline "$TMP/bl.err"
fi

# ---------------------------------------------------------------- test builds
BUILD_NOSRC_DEFAULT=skip; BUILD_UP_DEFAULT=skip; BUILD_UP_LEGACY=skip
if [ "$NO_BUILD" -eq 0 ]; then
    head2 "9. Test builds (print one word; no image, no deploy)"
    cat >"$TMP/cb.yaml" <<'YAML'
steps:
  - name: 'gcr.io/cloud-builders/gcloud'
    entrypoint: 'bash'
    args: ['-c', 'echo cloud-build-works']
options:
  logging: CLOUD_LOGGING_ONLY
timeout: '300s'
YAML
    mkdir -p "$TMP/src" && echo hello >"$TMP/src/hello.txt"

    try_build() {   # try_build LABEL RESULTVAR [env assignment] -- gcloud args...
        local label="$1" var="$2"; shift 2
        local envs=()
        while [ "${1:-}" != "--" ]; do envs+=("$1"); shift; done
        shift
        if env ${envs[@]+"${envs[@]}"} timeout 240 gcloud builds submit "$@" --config="$TMP/cb.yaml" --project="$PROJECT_ID" >"$TMP/b.out" 2>"$TMP/b.err"; then
            ok "$label"; printf -v "$var" '%s' pass
        else
            bad "$label"; printf -v "$var" '%s' fail
            errline "$TMP/b.err" 3
            id=$(grep -ohE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' "$TMP/b.out" "$TMP/b.err" 2>/dev/null | head -n1)
            if [ -n "$id" ]; then
                gcloud builds describe "$id" --project="$PROJECT_ID" --format='value(status,statusDetail,failureInfo.detail)' 2>/dev/null | head -n 2 | indent
                gcloud logging read "resource.type=\"build\" AND resource.labels.build_id=\"$id\"" --project="$PROJECT_ID" \
                    --order=asc --limit=40 --format='value(textPayload)' 2>/dev/null | grep -v '^$' | tail -n 8 | indent
            fi
        fi
    }
    try_build "build with no source upload (default mode)" BUILD_NOSRC_DEFAULT -- --no-source
    try_build "build WITH source upload (default mode)"    BUILD_UP_DEFAULT    -- "$TMP/src"
    try_build "build WITH source upload (LEGACY mode)"     BUILD_UP_LEGACY CLOUDSDK_BILLING_QUOTA_PROJECT=LEGACY -- "$TMP/src"
fi

# ---------------------------------------------------------------- verdict
head2 "VERDICT"
verdict() { say "  -> $*"; }
FOUND=0
if [ "$API_LIST_OK" -eq 1 ]; then
    for api in run cloudbuild artifactregistry storage; do
        grep -qx "${api}.googleapis.com" "$TMP/apis" || { verdict "Enable the ${api} API: gcloud services enable ${api}.googleapis.com"; FOUND=1; }
    done
fi
if [ "$SCAN_OK" -eq 1 ]; then
    can cloudbuild.builds.create || { verdict "This account CANNOT start Cloud Build builds (cloudbuild.builds.create). No script can fix that: an owner must grant roles/cloudbuild.builds.editor, or use a project where you are Editor/Owner."; FOUND=1; }
    can run.services.create || { verdict "This account CANNOT create Cloud Run services (run.services.create)."; FOUND=1; }
    can iam.serviceAccounts.actAs || { verdict "No iam.serviceAccounts.actAs: the deploy step can fail with an 'actAs' error. Needs roles/iam.serviceAccountUser from an owner."; FOUND=1; }
    can logging.logEntries.list || { verdict "Can't read build logs, so a failed build looks empty. deploy.sh will try to fetch the failure reason anyway."; FOUND=1; }
fi
if [ "$QUOTA_DEFAULT_OK" -eq 0 ] && [ "$QUOTA_LEGACY_OK" -eq 1 ]; then
    verdict "gcloud's default quota mode is refused but LEGACY works: deploy.sh switches to LEGACY automatically. Good."; FOUND=1
fi
if [ "$NO_BUILD" -eq 0 ]; then
    if [ "$BUILD_UP_DEFAULT" = pass ]; then verdict "Normal builds work here. If deploy.sh still fails, send this report together with build.log."; FOUND=1
    elif [ "$BUILD_UP_LEGACY" = pass ]; then verdict "Builds work only in LEGACY mode - deploy.sh does that automatically. Pull the latest version and rerun."; FOUND=1
    elif [ "$BUILD_NOSRC_DEFAULT" = pass ]; then verdict "Cloud Build runs, but uploading source is blocked. deploy.sh falls back to building from GitHub (committed + pushed code only)."; FOUND=1
    elif [ "$BUILD_NOSRC_DEFAULT" = fail ]; then verdict "Even a trivial build fails, so this account can't use Cloud Build at all here. See the errors above; it is an account/project limit, not a script bug."; FOUND=1; fi
fi
[ "$FOUND" -eq 1 ] || verdict "No problem found by these checks. Send this report if deploy.sh still fails."
say ""
say "Report saved to ./${OUT}"
