#!/usr/bin/env bash
# Shared helpers for the SRE demo drills (sourced, not run).
#
# The cluster is private with local accounts disabled, so every kubectl call goes
# through the AKS runCommand API (the control plane runs it in a short-lived
# pod); see kx below. PromQL goes to the Azure Monitor workspace query endpoint with the
# operator's Entra token. Receipts go to a private directory outside the repo,
# because they hold subscription and resource IDs.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RECEIPTS_DIR="${RECEIPTS_DIR:-$HOME/sre-demo-receipts/$(date -u +%Y-%m-%d)}"
mkdir -p "$RECEIPTS_DIR" && chmod 700 "$RECEIPTS_DIR"

# A missing or null output makes terraform print a warning box on stdout, so
# only a clean single-line value counts.
tf_out() {
  local v
  v="$(terraform -chdir="$ROOT/workload" output -raw "$1" 2>/dev/null)" || return 0
  [[ "$v" == *$'\n'* || "$v" == *"Warning"* ]] && return 0
  printf '%s' "$v"
}

# Sets globals the drill scripts read.
# shellcheck disable=SC2034
load_outputs() {
  RG="$(tf_out resource_group_name)"
  AKS="$(tf_out aks_cluster_name)"
  ACR="$(tf_out acr_name)"
  PROM="$(tf_out monitor_workspace_query_endpoint)"
  FLUX_CONFIG="$(tf_out flux_configuration_name)"
  SUB="$(az account show --query id -o tsv)"
  if [ -z "$RG" ] || [ -z "$AKS" ]; then
    echo "workload outputs missing; is workload/ applied?" >&2
    return 1
  fi
}

now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
epoch() { date -u +%s; }

# kx "<shell command run with kubectl available>"; prints the logs, returns the
# command's exit code.
#
# Calls the AKS runCommand REST API directly. `az aks command invoke` in Azure
# CLI 2.83.0 fails every call with "Operation returned an invalid status 'OK'".
# Entra-enabled clusters need a clusterToken: a token for the AKS Entra server
# application (6dae42f8-4368-4678-94ff-3960e28e3630).
kx() {
  local id tok ct body loc r st
  id="/subscriptions/${SUB}/resourceGroups/${RG}/providers/Microsoft.ContainerService/managedClusters/${AKS}"
  tok="$(az account get-access-token --query accessToken -o tsv)" || return 1
  ct="$(az account get-access-token --resource 6dae42f8-4368-4678-94ff-3960e28e3630 --query accessToken -o tsv)" || return 1
  body="$(jq -n --arg c "$1" --arg t "$ct" '{command: $c, clusterToken: $t}')"
  loc="$(curl -s -D - -o /dev/null -X POST -H "Authorization: Bearer $tok" -H 'Content-Type: application/json' \
    "https://management.azure.com${id}/runCommand?api-version=2024-09-01" -d "$body" |
    tr -d '\r' | awk 'tolower($1) == "location:" {print $2}')"
  [ -n "$loc" ] || { echo "runCommand was not accepted" >&2; return 1; }
  for _ in $(seq 1 90); do
    r="$(curl -s -H "Authorization: Bearer $tok" "$loc")"
    st="$(jq -r '.properties.provisioningState // empty' <<<"$r" 2>/dev/null)"
    case "$st" in
      Succeeded)
        jq -r '.properties.logs // ""' <<<"$r"
        return "$(jq -r '.properties.exitCode // 1' <<<"$r")"
        ;;
      Failed)
        jq -r '.properties.reason // "runCommand failed"' <<<"$r" >&2
        return 1
        ;;
    esac
    sleep 3
  done
  echo "runCommand timed out" >&2
  return 1
}

# promq "<PromQL>"; prints the first result value, or "none".
promq() {
  local token
  token="$(az account get-access-token --resource https://prometheus.monitor.azure.com --query accessToken -o tsv)"
  curl -sf -H "Authorization: Bearer $token" "${PROM%/}/api/v1/query" \
    --data-urlencode "query=$1" | jq -r '.data.result[0].value[1] // "none"'
}

# Azure Monitor alerts for one alert name over the last few hours, newest first,
# one line each: <id> <monitorCondition> <startDateTime> <lastModifiedDateTime>.
alerts_for() {
  az rest --method get \
    --url "https://management.azure.com/subscriptions/${SUB}/providers/Microsoft.AlertsManagement/alerts?api-version=2019-05-05-preview&timeRange=1d" \
    -o json 2>/dev/null |
    jq -r --arg name "$1" '
      [.value[] | select(tostring | contains($name))]
      | sort_by(.properties.essentials.startDateTime) | reverse | .[]
      | "\(.name) \(.properties.essentials.monitorCondition) \(.properties.essentials.startDateTime) \(.properties.essentials.lastModifiedDateTime)"'
}

# receipt <file> <key> <value>: append one key to a JSON receipt.
receipt() {
  local file="$RECEIPTS_DIR/$1"
  [ -f "$file" ] || echo '{}' >"$file"
  jq --arg k "$2" --arg v "$3" '.[$k] = $v' "$file" >"$file.tmp" && mv "$file.tmp" "$file"
  chmod 600 "$file"
  echo "  receipt $2 = $3"
}

# wait_until <timeout-seconds> <interval-seconds> '<condition>'
# The condition is a single-quoted string, evaluated fresh on every poll. Passing
# `test -n "$(f)"` unquoted would expand $(f) once, at the call, and re-test that
# same value forever: on 2026-10-29 that hid a fired alert and a Flux revert.
wait_until() {
  local timeout="$1" interval="$2" start
  shift 2
  start="$(epoch)"
  until eval "$*"; do
    if [ $(($(epoch) - start)) -ge "$timeout" ]; then return 1; fi
    sleep "$interval"
  done
}
