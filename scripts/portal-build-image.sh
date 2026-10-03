#!/usr/bin/env bash
# Build the portal image in Azure (ACR Tasks) from app/ and print the tfvars
# line to deploy it. No local Docker needed.
#
# Requires: az login, the portal deployed (for the registry).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ACR="$(terraform -chdir="$ROOT/portal" output -raw acr_name)"
TAG="$(git -C "$ROOT" rev-parse --short HEAD)"

echo "==> Building ${ACR}.azurecr.io/portal:${TAG} with ACR Tasks"
az acr build --registry "$ACR" --image "portal:${TAG}" "$ROOT/app"

echo ""
echo "==> Add to portal/terraform.tfvars, then re-apply:"
echo "app_image = \"${ACR}.azurecr.io/portal:${TAG}\""
