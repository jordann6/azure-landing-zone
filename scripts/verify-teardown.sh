#!/usr/bin/env bash
# Post-destroy verification: fail if any HOURLY-billed resource is still alive.
# The only standing residual after a clean destroy is the soft-deleted Key Vault
# (purge protection holds it for the soft-delete window, ~$1/mo), which is by
# design and is NOT counted as a failure here.
#
# Requires: az login, pointed at the same subscription.
set -uo pipefail

PROJECT="${PROJECT:-alz}"
survivors=0

check() {
  local label="$1" count="$2"
  if [[ "$count" =~ ^[1-9] ]]; then
    echo "  ALIVE ($count): $label  <-- still billing"
    survivors=$((survivors + count))
  else
    echo "  gone: $label"
  fi
}

echo "== Standing hourly-resource check =="

check "Azure Firewall" \
  "$(az network firewall list --query "[?contains(name,'${PROJECT}')] | length(@)" -o tsv 2>/dev/null)"
check "Azure Bastion" \
  "$(az network bastion list --query "[?contains(name,'${PROJECT}')] | length(@)" -o tsv 2>/dev/null)"
check "Standard public IPs" \
  "$(az network public-ip list --query "[?contains(name,'${PROJECT}') && sku.name=='Standard'] | length(@)" -o tsv 2>/dev/null)"
check "Virtual machines (FortiGate)" \
  "$(az vm list --query "[?contains(name,'${PROJECT}')] | length(@)" -o tsv 2>/dev/null)"
check "Private endpoints" \
  "$(az network private-endpoint list --query "[?contains(name,'${PROJECT}')] | length(@)" -o tsv 2>/dev/null)"

echo ""
if [ "$survivors" -eq 0 ]; then
  echo "== Clean. No hourly resources standing. =="
  echo "   (A soft-deleted Key Vault may remain for its retention window by design.)"
  exit 0
fi
echo "== $survivors hourly resource(s) still alive. Investigate before walking away. =="
exit 1
