#!/usr/bin/env bash
# Always attempt each teardown root, then verify. Preserve failures for the caller.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
failed=0
for root in compute workload terraform; do
  if ! terraform -chdir="$ROOT/$root" init -input=false; then
    failed=1
    continue
  fi
  if terraform -chdir="$ROOT/$root" plan -destroy -input=false -out=tfplan; then
    terraform -chdir="$ROOT/$root" apply -input=false tfplan || failed=1
  else
    failed=1
  fi
  if [[ "$root" == compute ]]; then
    # Packer-created versions are not Terraform resources. Remove their billed
    # storage before Terraform attempts to delete the image definition.
    python3 "$ROOT/scripts/cleanup-images.py" || failed=1
  fi
done
"$ROOT/scripts/verify-teardown.sh" || failed=1
exit "$failed"
