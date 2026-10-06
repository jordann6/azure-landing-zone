#!/usr/bin/env bash
# Move every root's state from the shared backend into this landing zone's own
# backend (bootstrap/). Run phase 1 first, apply its plan, then run phase 2.
#
#   scripts/migrate-state-backend.sh plan-bootstrap   # phase 1: saved plan only
#   terraform -chdir=bootstrap apply bootstrap.tfplan # you apply it
#   scripts/migrate-state-backend.sh migrate          # phase 2: copy + verify
#
# Phase 2 records each root's resource count on the old backend, copies the
# state, then fails unless the root is initialised against the new account, the
# state blob exists there, and the resource count matches. Old blobs are never
# deleted; they are the rollback (re-point the backend block and init again).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

OLD_RG="rg-tfbackend-jordprojs"
OLD_SA="sttfbejordprojs8557"
NEW_RG="rg-alz-tfstate"
NEW_SA="stalztfstatejn"
CONTAINER="tfstate"

# root directory -> state key (keys are unchanged by the move)
ROOTS=(
  "bootstrap:azure-landing-zone/bootstrap.terraform.tfstate"
  "terraform:azure-landing-zone/dev.terraform.tfstate"
  "compute:azure-landing-zone/compute.terraform.tfstate"
  "workload:azure-landing-zone/workload.terraform.tfstate"
  "portal:azure-landing-zone/portal.terraform.tfstate"
)

init_old() {
  local dir="$1" key="$2"
  terraform -chdir="$ROOT/$dir" init -reconfigure -input=false \
    -backend-config="resource_group_name=$OLD_RG" \
    -backend-config="storage_account_name=$OLD_SA" \
    -backend-config="container_name=$CONTAINER" \
    -backend-config="key=$key" \
    -backend-config="use_azuread_auth=false" >/dev/null
}

old_blob_exists() {
  az storage blob exists --auth-mode key --account-name "$OLD_SA" \
    --container-name "$CONTAINER" --name "$1" --query exists -o tsv 2>/dev/null
}

new_blob_exists() {
  az storage blob exists --auth-mode login --account-name "$NEW_SA" \
    --container-name "$CONTAINER" --name "$1" --query exists -o tsv 2>/dev/null
}

# Terraform caches -backend-config values from the previous init, so the
# migration must name the new backend explicitly or it "migrates" to the old one.
migrate_new() {
  terraform -chdir="$ROOT/$1" init -migrate-state -force-copy -input=false \
    -backend-config="resource_group_name=$NEW_RG" \
    -backend-config="storage_account_name=$NEW_SA" \
    -backend-config="container_name=$CONTAINER" \
    -backend-config="key=$2" \
    -backend-config="use_azuread_auth=true" >/dev/null
}

active_account() {
  python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["backend"]["config"]["storage_account_name"])' \
    "$ROOT/$1/.terraform/terraform.tfstate"
}

count() { terraform -chdir="$ROOT/$1" state list | wc -l | tr -d ' '; }

case "${1:-}" in
  plan-bootstrap)
    init_old bootstrap "azure-landing-zone/bootstrap.terraform.tfstate"
    terraform -chdir="$ROOT/bootstrap" plan -input=false -out=bootstrap.tfplan
    echo "==> Review, then: terraform -chdir=$ROOT/bootstrap apply bootstrap.tfplan"
    ;;
  migrate)
    failed=0
    for entry in "${ROOTS[@]}"; do
      dir="${entry%%:*}" key="${entry#*:}"
      if [[ "$(old_blob_exists "$key")" != "true" ]]; then
        echo "-- $dir: no state on the old backend, skipping"
        continue
      fi
      init_old "$dir" "$key"
      before="$(count "$dir")"
      # Entra RBAC on the new account can lag a fresh assignment; retry once.
      if ! migrate_new "$dir" "$key"; then
        echo "   retrying $dir in 60s (RBAC propagation)"
        sleep 60
        migrate_new "$dir" "$key"
      fi
      # Prove the move happened, not just that the counts agree.
      if [[ "$(active_account "$dir")" != "$NEW_SA" ]]; then
        echo "NOT MOVED $dir: still initialised against $(active_account "$dir")" >&2
        failed=1
        continue
      fi
      if [[ "$(new_blob_exists "$key")" != "true" ]]; then
        echo "MISSING $dir: no $key in $NEW_SA" >&2
        failed=1
        continue
      fi
      after="$(count "$dir")"
      if [[ "$before" == "$after" ]]; then
        echo "OK $dir: $after resources"
      else
        echo "MISMATCH $dir: $before on old backend, $after on new" >&2
        failed=1
      fi
    done
    exit "$failed"
    ;;
  *)
    echo "usage: $0 plan-bootstrap | migrate" >&2
    exit 2
    ;;
esac
