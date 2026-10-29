#!/usr/bin/env bash
# Pin the SRE demo images by digest in gitops/ and print the ACR imports.
#
# Usage: scripts/sre-pin-images.sh <slo-demo digest> <slo-grafana digest> <git sha>
# Digests and the SHA come from the "SRE demo images" workflow run summary.
#
# Edits gitops/apps/kustomization.yaml and gitops/data/kustomization.yaml in
# place (commit and push them so Flux deploys the pinned images), then prints the
# `az acr import` commands for the operator to run. The private registry is the
# only one the cluster can pull from; import runs on the registry's control
# plane, so it works with public network access disabled.
#
# ghcr.io packages start private. If the import is refused, either make the two
# packages public once (repository Packages settings), or add
#   --username <github user> --password <token with read:packages>
# to the ghcr imports.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[ $# -eq 3 ] || { sed -n 3,4p "$0" >&2; exit 2; }
APP="$1" GRAFANA="$2" SHA="$3"
for d in "$APP" "$GRAFANA"; do
  [[ "$d" =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "not a digest: $d" >&2; exit 2; }
done

pin() { # file image digest
  python3 - "$1" "$2" "$3" <<'PY'
import re, sys
path, image, digest = sys.argv[1:]
text = open(path).read()
pattern = rf"(- name: {re.escape(image)}\n\s+newName: [^\n]+\n\s+digest: )sha256:[0-9a-f]{{64}}"
new, n = re.subn(pattern, rf"\g<1>{digest}", text)
if n != 1:
    sys.exit(f"{path}: expected one {image} entry, found {n}")
open(path, "w").write(new)
PY
}
pin "$ROOT/gitops/apps/kustomization.yaml" slo-demo "$APP"
pin "$ROOT/gitops/apps/kustomization.yaml" slo-grafana "$GRAFANA"
pin "$ROOT/gitops/data/kustomization.yaml" slo-demo "$APP"
PG="$(awk '/name: postgres/{getline; getline; print $2}' "$ROOT/gitops/data/kustomization.yaml")"

# A missing output prints a warning box on stdout, so accept only a registry name.
ACR="$(terraform -chdir="$ROOT/workload" output -raw acr_name 2>/dev/null)" || true
[[ "$ACR" =~ ^[a-z0-9]+$ ]] || ACR='<acr>'
echo "Pinned. Commit and push gitops/, then run:"
echo "  az acr import --name $ACR --source ghcr.io/jordann6/slo-demo@$APP --image slo-demo:$SHA"
echo "  az acr import --name $ACR --source ghcr.io/jordann6/slo-grafana@$GRAFANA --image slo-grafana:$SHA"
echo "  az acr import --name $ACR --source ghcr.io/jordann6/postgres@$PG --image postgres:16.14"
