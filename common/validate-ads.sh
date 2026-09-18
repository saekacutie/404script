#!/bin/bash
# Local syntax/config smoke test for the shared ad policy.
set -euo pipefail

command -v bash >/dev/null
bash -n common/ads-mode.sh
for file in common/config-ads.json common/config-noads.json; do
  if command -v jq >/dev/null 2>&1; then jq empty "$file"; fi
done
printf '%s\n' 'Shell syntax checks passed.'
printf '%s\n' 'Run the container entrypoint or xray run -test with geosite.dat for full validation.'
