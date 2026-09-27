#!/usr/bin/env bash
# Prove the preventive guardrails DENY, not just that the apply succeeded.
# Each check runs an action that a Deny policy should block and passes only when
# Azure refuses it (RequestDisallowedByPolicy). Read-only otherwise; any resource
# a check does manage to create is cleaned up immediately.
#
# Requires: az login, and the landing zone deployed (at least the free layer).
set -uo pipefail

PROJECT="${PROJECT:-alz}"
LOCATION="${LOCATION:-eastus}"
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
