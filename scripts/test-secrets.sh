#!/usr/bin/env bash
# Prove the secrets scanner wiring: the identity can list vault metadata and
# cannot read a value, the seeded positive control is a real finding, and the
# near-expiry alert path fires.
#
# The value-read denial is proven two ways. checkAccess asks Azure for the
# scanner identity's effective data actions. A throwaway service principal that
# holds the same Key Vault Reader role then makes the real calls, because a
# managed identity cannot be exercised from a workstation. The principal and its
# credential are deleted on exit.
#
# Requires: az login as the deployer on an allow-listed IP, jq, and the base plus
# secrets/ roots deployed.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="${PROJECT:-alz}"
WAIT_MINUTES="${WAIT_MINUTES:-20}"
pass=0
fail=0

ok()   { echo "  PASS: $1"; pass=$((pass + 1)); }
bad()  { echo "  FAIL: $1"; fail=$((fail + 1)); }
skip() { echo "  SKIP: $1"; }

tf() { terraform -chdir="$ROOT/$1" output -raw "$2" 2>/dev/null; }

SUB=$(az account show --query id -o tsv) || exit 1
TENANT=$(az account show --query tenantId -o tsv)
PRINCIPAL=$(tf secrets scanner_identity_principal_id) || true
VAULT_ID=$(tf terraform key_vault_id) || true
if [ -z "$PRINCIPAL" ] || [ -z "$VAULT_ID" ]; then
  echo "secrets/ and the base root must both be applied first." >&2
  exit 1
fi
VAULT=$(basename "$VAULT_ID")
CONTROL=$(tf secrets control_secret_name) || true
STAMP=$(date -u +%Y%m%d%H%M%S)
NEAR="scanner-test-near-expiry-${STAMP}"
SP_APP=""
SP_DIR=""

cleanup() {
  [ -n "$SP_APP" ] && az ad app delete --id "$SP_APP" >/dev/null 2>&1
  [ -n "$SP_DIR" ] && rm -rf "$SP_DIR"
  az keyvault secret delete --vault-name "$VAULT" --name "$NEAR" >/dev/null 2>&1
}
trap cleanup EXIT

echo "== Secrets scanner proofs =="

echo "-- scanner holds Key Vault Reader on the vault, and not a secret-reading role --"
roles=$(az role assignment list --assignee "$PRINCIPAL" --all --query "[].roleDefinitionName" -o tsv 2>/dev/null)
echo "$roles" | grep -qx "Key Vault Reader" && ok "Key Vault Reader assigned" || bad "Key Vault Reader missing"
if echo "$roles" | grep -Eq "Key Vault (Secrets User|Secrets Officer|Administrator)"; then
  bad "scanner holds a role that can read secret values"
else
  ok "no secret-reading role assigned"
fi

echo "-- role definition: metadata yes, value no --"
actions=$(az role definition list --name "Key Vault Reader" --query "[0].permissions[0].dataActions" -o tsv 2>/dev/null)
echo "$actions" | grep -q "secrets/readMetadata/action" && ok "role grants secrets/readMetadata" || bad "role lacks secrets/readMetadata"
echo "$actions" | grep -Eq "secrets/getSecret/action|secrets/\*" && bad "role grants getSecret" || ok "role does not grant getSecret"

echo "-- effective access (checkAccess) for the scanner identity --"
check=$(az rest --method post \
  --url "https://management.azure.com${VAULT_ID}/providers/Microsoft.Authorization/checkAccess?api-version=2022-04-01" \
  --body "{\"Subject\":{\"Attributes\":{\"ObjectId\":\"${PRINCIPAL}\"}},\"Actions\":[{\"Id\":\"Microsoft.KeyVault/vaults/secrets/readMetadata/action\",\"IsDataAction\":true},{\"Id\":\"Microsoft.KeyVault/vaults/secrets/getSecret/action\",\"IsDataAction\":true}],\"Resource\":{\"Id\":\"${VAULT_ID}\"}}" \
  -o json 2>/dev/null)
meta=$(echo "$check" | jq -r '[(if type=="array" then . else .value end)[] | select(.actionId | endswith("readMetadata/action")) | .accessDecision] | first')
getv=$(echo "$check" | jq -r '[(if type=="array" then . else .value end)[] | select(.actionId | endswith("getSecret/action")) | .accessDecision] | first')
[ "$meta" = "Allowed" ] && ok "readMetadata Allowed" || bad "readMetadata decision: ${meta:-none}"
[ "$getv" = "NotAllowed" ] && ok "getSecret NotAllowed" || bad "getSecret decision: ${getv:-none}"

echo "-- positive control is a finding --"
if [ -n "$CONTROL" ] && [ "$CONTROL" != "null" ]; then
  exp=$(az keyvault secret show --vault-name "$VAULT" --name "$CONTROL" --query "attributes.expires" -o tsv 2>/dev/null)
  rc=$?
  if [ "$rc" -ne 0 ]; then
    bad "could not read the control secret as the deployer (role propagation or firewall)"
  elif [ -z "$exp" ] || [ "$exp" = "None" ]; then
    ok "control secret has no expiry, the same criterion the scanner flags (CIS 8.3)"
  else
    bad "control secret has an expiry, so it is not a positive control"
  fi
else
  skip "enable_control_secret is off"
fi

echo "-- real calls as a Key Vault Reader principal --"
if ! SP_JSON=$(az ad sp create-for-rbac --name "alz-secrets-test-${STAMP}" --skip-assignment -o json 2>/dev/null); then
  skip "cannot create a throwaway service principal in this tenant; checkAccess above is the proof"
else
  SP_APP=$(echo "$SP_JSON" | jq -r .appId)
  SP_PW=$(echo "$SP_JSON" | jq -r .password)
  az role assignment create --assignee "$SP_APP" --role "Key Vault Reader" --scope "$VAULT_ID" >/dev/null 2>&1
  SP_DIR=$(mktemp -d)
  listed=0
  deadline=$((SECONDS + 240))
  while [ "$SECONDS" -lt "$deadline" ]; do
    AZURE_CONFIG_DIR="$SP_DIR" az login --service-principal -u "$SP_APP" -p "$SP_PW" --tenant "$TENANT" --allow-no-subscriptions -o none 2>/dev/null
    if AZURE_CONFIG_DIR="$SP_DIR" az keyvault secret list --vault-name "$VAULT" -o none 2>/dev/null; then listed=1; break; fi
    sleep 20
  done
  [ "$listed" -eq 1 ] && ok "secret list (metadata) succeeds" || bad "secret list failed for the Reader principal"
  if [ -n "$CONTROL" ] && [ "$CONTROL" != "null" ]; then
    err=$(AZURE_CONFIG_DIR="$SP_DIR" az keyvault secret show --vault-name "$VAULT" --name "$CONTROL" 2>&1 >/dev/null)
    if echo "$err" | grep -Eqi "Forbidden|403"; then ok "secret value read returns 403"; else bad "value read was not refused: ${err:-no error}"; fi
  fi
fi

echo "-- near-expiry event reaches the workspace and the alert fires (up to ${WAIT_MINUTES} min) --"
az role assignment list --assignee "$(az ad signed-in-user show --query id -o tsv 2>/dev/null)" --scope "$VAULT_ID" \
  --query "[?roleDefinitionName=='Key Vault Secrets Officer'] | length(@)" -o tsv 2>/dev/null | grep -q '^[1-9]' \
  || skip "deployer lacks Secrets Officer (enable_control_secret is off), cannot seed the near-expiry secret"
start=$(date -u +%Y-%m-%dT%H:%M:%SZ)
expiry=$(date -u -v+10d '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -d '+10 days' '+%Y-%m-%dT%H:%M:%SZ')
if az keyvault secret set --vault-name "$VAULT" --name "$NEAR" --value "not-a-real-secret-near-expiry" \
     --expires "$expiry" --tags purpose=scanner-test -o none 2>/dev/null; then
  LAW=$(tf secrets scanner_env | sed -n 's/.*LOG_ANALYTICS_WORKSPACE_ID=//p')
  seen=0
  deadline=$((SECONDS + WAIT_MINUTES * 60))
  while [ "$SECONDS" -lt "$deadline" ]; do
    n=$(az monitor log-analytics query -w "$LAW" --analytics-query \
      "AzureDiagnostics | where ResourceProvider == 'MICROSOFT.KEYVAULT' | where OperationName has 'NearExpiry' | where TimeGenerated >= datetime(${start}) | count" \
      --query "[0].Count" -o tsv 2>/dev/null)
    [ "${n:-0}" -gt 0 ] && { seen=1; break; }
    sleep 60
  done
  [ "$seen" -eq 1 ] && ok "a NearExpiry audit event reached the workspace" || bad "no NearExpiry event within ${WAIT_MINUTES} min (OperationName or trigger timing differs)"
  fired=$(az rest --method get \
    --url "https://management.azure.com/subscriptions/${SUB}/providers/Microsoft.AlertsManagement/alerts?api-version=2019-05-05-preview&timeRange=1d" \
    -o json 2>/dev/null | jq -r --arg rule "alert-${PROJECT}-secret-near-expiry" --arg start "$start" \
    '[.value[] | select(.properties.essentials.alertRule | endswith($rule)) | select(.properties.essentials.startDateTime >= $start)] | length')
  [ "${fired:-0}" -gt 0 ] && ok "near-expiry alert fired" || bad "near-expiry alert has not fired yet (log alerts evaluate every 15 min; rerun)"
else
  bad "could not create the near-expiry test secret"
fi

echo ""
echo "== $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
