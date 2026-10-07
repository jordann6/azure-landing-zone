#!/usr/bin/env bash
# Prove the control-plane change alerts exist and actually fire.
# Creates and deletes one network security group in a throwaway resource group,
# which should trip the nsg-write and nsg-delete alerts, then polls the Azure
# Monitor alert store for both. Activity log alerts fire within a few minutes.
#
# Requires: az login, and the base plus observability/ roots deployed.
set -uo pipefail

PROJECT="${PROJECT:-alz}"
LOCATION="${LOCATION:-centralus}"
WAIT_MINUTES="${WAIT_MINUTES:-15}"
RG_TEST="rg-${PROJECT}-observability-test"
pass=0
fail=0

ok()  { echo "  PASS: $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL: $1"; fail=$((fail + 1)); }

SUB=$(az account show --query id -o tsv) || exit 1
cleanup() { az group delete -n "$RG_TEST" -y --no-wait >/dev/null 2>&1; }
trap cleanup EXIT

echo "== Observability proofs =="

echo "-- change alerts are deployed --"
count=$(az monitor activity-log alert list --query "[?starts_with(name, 'alert-${PROJECT}-')] | length(@)" -o tsv 2>/dev/null || echo 0)
# 13 change alerts here plus the Deny alert from the base root.
if [ "${count:-0}" -ge 14 ]; then ok "${count} activity log alerts present"; else bad "expected at least 14 alerts, found ${count:-0}"; fi

echo "-- Defender export and HIGH alert --"
if az rest --method get \
  --url "https://management.azure.com/subscriptions/${SUB}/providers/Microsoft.Security/automations?api-version=2023-12-01-preview" \
  --query "value[?name=='export-${PROJECT}-defender'] | length(@)" -o tsv 2>/dev/null | grep -q '^1$'; then
  ok "Defender continuous export is configured"
else
  echo "  SKIP: export not found (enable_findings_export may be off)"
fi

echo "-- trigger: create then delete a network security group --"
az group create -n "$RG_TEST" -l "$LOCATION" \
  --tags owner=observability-test cost_center=platform environment=test data_classification=internal \
  >/dev/null || exit 1
start=$(date -u +%Y-%m-%dT%H:%M:%SZ)
az network nsg create -g "$RG_TEST" -n "nsg-should-alert" -l "$LOCATION" >/dev/null 2>&1 || { bad "could not create the test NSG"; exit 1; }
az network nsg delete -g "$RG_TEST" -n "nsg-should-alert" >/dev/null 2>&1

fired() {
  az rest --method get \
    --url "https://management.azure.com/subscriptions/${SUB}/providers/Microsoft.AlertsManagement/alerts?api-version=2019-05-05-preview&timeRange=1d" \
    -o json 2>/dev/null \
    | jq -r --arg rule "alert-${PROJECT}-$1" --arg start "$start" \
      '[.value[] | select(.properties.essentials.alertRule | endswith($rule)) | select(.properties.essentials.startDateTime >= $start)] | length'
}

echo "-- alerts fire (up to ${WAIT_MINUTES} min) --"
deadline=$((SECONDS + WAIT_MINUTES * 60))
w=0; d=0
while [ "$SECONDS" -lt "$deadline" ]; do
  w=$(fired nsg-write); d=$(fired nsg-delete)
  [ "${w:-0}" -gt 0 ] && [ "${d:-0}" -gt 0 ] && break
  sleep 30
done
[ "${w:-0}" -gt 0 ] && ok "nsg-write alert fired" || bad "nsg-write alert did not fire"
[ "${d:-0}" -gt 0 ] && ok "nsg-delete alert fired" || bad "nsg-delete alert did not fire"

echo ""
echo "== $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
