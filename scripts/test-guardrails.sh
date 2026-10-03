#!/usr/bin/env bash
# Prove the preventive guardrails DENY, not just that the apply succeeded.
# Each check runs an action that a Deny policy should block and passes only when
# Azure refuses it (RequestDisallowedByPolicy). Read-only otherwise; any resource
# a check does manage to create is cleaned up immediately.
#
# Requires: az login, and the landing zone deployed (at least the free layer).
set -uo pipefail

PROJECT="${PROJECT:-alz}"
LOCATION="${LOCATION:-centralus}"
BAD_LOCATION="${BAD_LOCATION:-westus2}"
RG_TEST="rg-${PROJECT}-guardrail-test"
# The CIS initiative is assigned at the root management group; a subscription-scope
# policy-assignment list does not surface MG-scoped assignments, so query the MG.
ROOT_MG="${ROOT_MG:-mg-jordann6}"
pass=0
fail=0

ok()   { echo "  PASS: $1"; pass=$((pass + 1)); }
bad()  { echo "  FAIL: $1"; fail=$((fail + 1)); }

denied() {
  # A policy denial surfaces as RequestDisallowedByPolicy / disallowed by policy.
  grep -qiE 'RequestDisallowedByPolicy|disallowed by policy|was denied by policy' <<<"$1"
}

echo "== Guardrail proofs =="

# A compliant RG so the public-IP test isolates the deny_public_ip policy rather
# than tripping the tag policies.
az group create -n "$RG_TEST" -l "$LOCATION" \
  --tags owner=guardrail-test cost_center=platform environment=test data_classification=internal \
  >/dev/null 2>&1

echo "-- deny public IP --"
out=$(az network public-ip create -g "$RG_TEST" -n "pip-should-fail" -l "$LOCATION" 2>&1)
if denied "$out"; then ok "public IP creation blocked by policy"; else
  bad "public IP was NOT blocked"; az network public-ip delete -g "$RG_TEST" -n "pip-should-fail" >/dev/null 2>&1
fi

echo "-- deny disallowed location --"
out=$(az group create -n "rg-${PROJECT}-badloc" -l "$BAD_LOCATION" \
  --tags owner=t cost_center=t environment=t data_classification=t 2>&1)
if denied "$out"; then ok "RG in $BAD_LOCATION blocked by allowed-locations"; else
  bad "RG in $BAD_LOCATION was NOT blocked"; az group delete -n "rg-${PROJECT}-badloc" -y >/dev/null 2>&1
fi

echo "-- deny missing required tags --"
out=$(az group create -n "rg-${PROJECT}-notags" -l "$LOCATION" 2>&1)
if denied "$out"; then ok "untagged RG blocked by require-tag policies"; else
  bad "untagged RG was NOT blocked"; az group delete -n "rg-${PROJECT}-notags" -y >/dev/null 2>&1
fi

echo "-- deny unknown data_classification value --"
out=$(az group create -n "rg-${PROJECT}-badclass" -l "$LOCATION" \
  --tags owner=t cost_center=t environment=t data_classification=secret 2>&1)
if denied "$out"; then ok "data_classification=secret blocked by allowed-values policy"; else
  bad "unknown data_classification was NOT blocked"; az group delete -n "rg-${PROJECT}-badclass" -y >/dev/null 2>&1
fi

echo "-- deny public network access in a phi resource group --"
RG_PHI="rg-${PROJECT}-phi-test"
az group create -n "$RG_PHI" -l "$LOCATION" \
  --tags owner=guardrail-test cost_center=platform environment=test data_classification=phi \
  >/dev/null 2>&1
SA_NAME="stphi$(LC_ALL=C tr -dc 'a-z0-9' </dev/urandom | head -c 12)"
out=$(az storage account create -g "$RG_PHI" -n "$SA_NAME" -l "$LOCATION" \
  --sku Standard_LRS --public-network-access Enabled 2>&1)
if denied "$out"; then ok "public storage account in a phi RG blocked by phi policy"; else
  bad "public storage account in a phi RG was NOT blocked"; az storage account delete -g "$RG_PHI" -n "$SA_NAME" -y >/dev/null 2>&1
fi
az group delete -n "$RG_PHI" -y --no-wait >/dev/null 2>&1

echo "-- HITRUST/HIPAA initiative assigned (scoring only) --"
if az policy assignment list \
     --scope "/providers/Microsoft.Management/managementGroups/${ROOT_MG}" \
     --query "[?name=='hitrust-hipaa'] | length(@)" -o tsv 2>/dev/null | grep -q '^[1-9]'; then
  ok "HITRUST/HIPAA initiative is assigned"
else
  bad "HITRUST/HIPAA initiative assignment not found"
fi

echo "-- CIS initiative assigned --"
if az policy assignment list \
     --scope "/providers/Microsoft.Management/managementGroups/${ROOT_MG}" \
     --query "[?name=='cis-azure-foundations'] | length(@)" -o tsv 2>/dev/null | grep -q '^[1-9]'; then
  ok "CIS Microsoft Azure Foundations initiative is assigned"
else
  bad "CIS initiative assignment not found"
fi

echo "-- Bastion is the admin path (no public VM IPs expected) --"
if az network bastion list --query "[?contains(name, '${PROJECT}')] | length(@)" -o tsv 2>/dev/null | grep -q '^[1-9]'; then
  ok "Azure Bastion present (browser admin path)"
else
  echo "  SKIP: Bastion not deployed (enable_bastion=false); no public admin path either way"
fi

# Cleanup the compliant test RG.
az group delete -n "$RG_TEST" -y --no-wait >/dev/null 2>&1

echo ""
echo "== $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
