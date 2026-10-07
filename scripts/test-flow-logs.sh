#!/usr/bin/env bash
# Prove VNet flow logs are configured as designed and actually delivering.
# Config checks run immediately. The delivery check polls the central workspace for
# traffic-analytics rows, which lag real traffic by 10 to 30 minutes, so run this
# after the stack has been up for a while (Bastion or firewall traffic is enough).
#
# Requires: az login, and the base deployed with enable_flow_logs = true.
set -uo pipefail

PROJECT="${PROJECT:-alz}"
LOCATION="${LOCATION:-centralus}"
WAIT_MINUTES="${WAIT_MINUTES:-30}"
LAW="log-${PROJECT}-central"
LAW_RG="rg-${PROJECT}-logging"
pass=0
fail=0

ok()  { echo "  PASS: $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL: $1"; fail=$((fail + 1)); }

echo "== Flow log proofs =="

echo "-- hub flow log is enabled and targets the VNet --"
hub=$(az network watcher flow-log show --location "$LOCATION" --name "fl-${PROJECT}-hub" -o json 2>/dev/null) \
  || { echo "  FAIL: fl-${PROJECT}-hub not found (is enable_flow_logs on?)"; exit 1; }
[ "$(jq -r '.enabled' <<<"$hub")" = "true" ] && ok "hub flow log enabled" || bad "hub flow log disabled"
jq -r '.targetResourceId' <<<"$hub" | grep -qi '/virtualNetworks/' \
  && ok "target is a virtual network, not an NSG" || bad "target is not a virtual network"
[ "$(jq -r '.flowAnalyticsConfiguration.networkWatcherFlowAnalyticsConfiguration.enabled' <<<"$hub")" = "true" ] \
  && ok "traffic analytics enabled" || bad "traffic analytics disabled"

echo "-- prod flow log (workload) --"
if prod=$(az network watcher flow-log show --location "$LOCATION" --name "fl-${PROJECT}-prod" -o json 2>/dev/null); then
  [ "$(jq -r '.enabled' <<<"$prod")" = "true" ] && ok "prod flow log enabled" || bad "prod flow log disabled"
else
  echo "  SKIP: fl-${PROJECT}-prod not found (workload not deployed or flow logs off there)"
fi

echo "-- storage account is locked down --"
sa_id=$(jq -r '.storageId' <<<"$hub")
sa=$(az storage account show --ids "$sa_id" -o json 2>/dev/null) || { bad "cannot read flow storage account"; sa=""; }
if [ -n "$sa" ]; then
  [ "$(jq -r '.networkRuleSet.defaultAction' <<<"$sa")" = "Deny" ] && ok "network rules default-Deny" || bad "network rules not default-Deny"
  [ "$(jq -r '.minimumTlsVersion' <<<"$sa")" = "TLS1_2" ] && ok "TLS 1.2 minimum" || bad "TLS minimum not 1.2"
  [ "$(jq -r '.encryption.keySource' <<<"$sa")" = "Microsoft.Keyvault" ] && ok "encrypted with the customer-managed key" || bad "not using the customer-managed key"
  [ "$(jq -r '.allowBlobPublicAccess' <<<"$sa")" = "false" ] && ok "blob public access off" || bad "blob public access on"
fi

echo "-- traffic analytics rows reach the workspace (up to ${WAIT_MINUTES} min) --"
cust=$(az monitor log-analytics workspace show -g "$LAW_RG" -n "$LAW" --query customerId -o tsv 2>/dev/null)
deadline=$((SECONDS + WAIT_MINUTES * 60))
rows=0
while [ "$SECONDS" -lt "$deadline" ]; do
  rows=$(az monitor log-analytics query -w "$cust" --analytics-query \
    "NTANetAnalytics | where TimeGenerated > ago(2h) | where FlowType != '' | count" \
    --query '[0].Count' -o tsv 2>/dev/null || echo 0)
  [ "${rows:-0}" -gt 0 ] && break
  sleep 60
done
[ "${rows:-0}" -gt 0 ] && ok "NTANetAnalytics has ${rows} rows" || bad "no NTANetAnalytics rows after ${WAIT_MINUTES} min"

echo ""
echo "== $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
