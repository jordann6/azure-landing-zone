#!/usr/bin/env bash
# Approve the Front Door private endpoint connections on each Container Apps
# environment. Front Door creates one managed private endpoint per origin, and
# the environment owner has to approve it before traffic flows. Front Door can
# create more than one request per origin; every pending one is approved.
#
# Requires: az login, the portal deployed.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
API="2024-10-02-preview"
ENV_IDS="$(terraform -chdir="$ROOT/portal" output -json aca_environment_ids | jq -r '.[]')"

for env_id in $ENV_IDS; do
  echo "== $(basename "$env_id")"
  pending="$(az rest --method get \
    --url "https://management.azure.com${env_id}/privateEndpointConnections?api-version=${API}" \
    --query "value[?properties.privateLinkServiceConnectionState.status=='Pending'].name" -o tsv)"
  if [ -z "$pending" ]; then
    echo "  nothing pending (already approved, or Front Door has not requested yet)"
    continue
  fi
  for name in $pending; do
    az rest --method put \
      --url "https://management.azure.com${env_id}/privateEndpointConnections/${name}?api-version=${API}" \
      --body '{"properties":{"privateLinkServiceConnectionState":{"status":"Approved","description":"Approved for Front Door"}}}' \
      >/dev/null
    echo "  approved $name"
  done
done

echo ""
echo "Connections can take a few minutes to become active. Then:"
echo "  curl -s \"\$(terraform -chdir=$ROOT/portal output -raw portal_url)/health\""
