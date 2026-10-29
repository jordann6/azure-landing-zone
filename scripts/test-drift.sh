#!/usr/bin/env bash
# Prove the scheduled drift check on ci-proof/ catches an out-of-band change and
# clears itself after recovery. Three dispatched runs of drift.yml on main:
#
#   1. clean      the run succeeds and no drift issue is open
#   2. drifted    after a CLI tag change on vnet-alz-ci, the run fails and one
#                 `drift` issue names the resource and the `tags` attribute,
#                 and does not contain the tag value
#   3. recovered  after the tag is removed, the run succeeds and the issue closes
#
# The probe tag is removed on exit, even after a failure, so the root never stays
# drifted. Prints run IDs and the issue number as receipts.
#
# Requires: az login (write on rg-alz-ci, for the tag), gh auth for the repo,
# drift.yml merged to main, and ci-proof/ applied.
set -uo pipefail

REPO="${REPO:-jordann6/azure-landing-zone}"
RG="${RG:-rg-alz-ci}"
VNET="${VNET:-vnet-alz-ci}"
WORKFLOW="drift.yml"
ISSUE_TITLE="Drift detected in ci-proof"
PROBE_KEY="drift_probe"
PROBE_VALUE="probe-$(date -u +%Y%m%d%H%M%S)"
pass=0
fail=0

ok()  { echo "  PASS: $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL: $1"; fail=$((fail + 1)); }

VNET_ID=$(az network vnet show -g "$RG" -n "$VNET" --query id -o tsv 2>/dev/null) || {
  echo "vnet $VNET not found in $RG; apply ci-proof/ first" >&2
  exit 1
}
gh workflow view "$WORKFLOW" -R "$REPO" >/dev/null 2>&1 || {
  echo "$WORKFLOW is not on the default branch of $REPO yet" >&2
  exit 1
}

remove_probe() {
  az tag update --resource-id "$VNET_ID" --operation Delete \
    --tags "${PROBE_KEY}=${PROBE_VALUE}" >/dev/null 2>&1 || true
}
trap remove_probe EXIT

# Dispatch on main, find the run it created, wait for it, print its conclusion.
dispatch() {
  local since id
  since=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  gh workflow run "$WORKFLOW" -R "$REPO" --ref main >/dev/null || return 1
  for _ in $(seq 1 30); do
    sleep 5
    id=$(gh run list -R "$REPO" --workflow "$WORKFLOW" --event workflow_dispatch \
      --json databaseId,createdAt \
      --jq "[.[] | select(.createdAt >= \"${since}\")] | sort_by(.createdAt) | .[0].databaseId // empty")
    [ -n "$id" ] && break
  done
  [ -n "${id:-}" ] || { echo "run did not appear" >&2; return 1; }
  gh run watch "$id" -R "$REPO" >/dev/null 2>&1 || true
  echo "$id $(gh run view "$id" -R "$REPO" --json conclusion --jq .conclusion)"
}

open_issue() {
  gh issue list -R "$REPO" --state open --label drift \
    --search "in:title \"${ISSUE_TITLE}\"" --json number --jq '.[0].number // empty'
}

echo "== Drift detection proof (ci-proof/) =="

echo "-- run 1: clean --"
read -r run1 c1 < <(dispatch) || { bad "dispatch failed"; exit 1; }
echo "  run ${run1}: ${c1}"
if [ "$c1" = "success" ]; then ok "clean run succeeded"; else bad "clean run concluded ${c1}"; fi
if [ -z "$(open_issue)" ]; then ok "no drift issue open"; else bad "a drift issue is already open before the probe"; fi

echo "-- run 2: drift (tag ${PROBE_KEY} added outside Terraform) --"
az tag update --resource-id "$VNET_ID" --operation Merge \
  --tags "${PROBE_KEY}=${PROBE_VALUE}" >/dev/null || { bad "could not add the probe tag"; exit 1; }
read -r run2 c2 < <(dispatch) || { bad "dispatch failed"; exit 1; }
echo "  run ${run2}: ${c2}"
if [ "$c2" = "failure" ]; then ok "drift run failed (fail_on_drift)"; else bad "drift run concluded ${c2}"; fi
issue=$(open_issue)
if [ -n "$issue" ]; then
  ok "drift issue #${issue} open"
  body=$(gh issue view "$issue" -R "$REPO" --json body --jq .body)
  if grep -q 'azurerm_virtual_network.ci' <<<"$body" && grep -q 'tags' <<<"$body"; then
    ok "issue names azurerm_virtual_network.ci and the tags attribute"
  else
    bad "issue does not name the drifted resource and attribute"
  fi
  if grep -q "$PROBE_VALUE" <<<"$body"; then bad "issue leaks the drifted value"; else ok "issue carries no drifted value"; fi
else
  bad "no drift issue opened"
fi

echo "-- run 3: recovered (probe tag removed) --"
remove_probe
read -r run3 c3 < <(dispatch) || { bad "dispatch failed"; exit 1; }
echo "  run ${run3}: ${c3}"
if [ "$c3" = "success" ]; then ok "recovered run succeeded"; else bad "recovered run concluded ${c3}"; fi
if [ -n "${issue:-}" ]; then
  state=$(gh issue view "$issue" -R "$REPO" --json state --jq .state)
  if [ "$state" = "CLOSED" ]; then ok "drift issue #${issue} closed by the clean run"; else bad "drift issue #${issue} is ${state}"; fi
fi

echo ""
echo "Receipts: runs ${run1} ${run2} ${run3}, issue #${issue:-none}"
echo "${pass} passed, ${fail} failed"
[ "$fail" -eq 0 ]
