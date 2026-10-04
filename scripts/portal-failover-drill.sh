#!/usr/bin/env bash
# Failover drill for the member portal. Measures, rather than claims, how long
# each tier takes to fail over and whether any acknowledged write was lost.
#
#   app   Take the primary region's app out of service and time how long until
#         Front Door serves every request from the secondary region.
#   data  Write an order every second while the SQL failover group switches its
#         primary to the other region. Reports RTO (longest run of failed
#         writes) and RPO (acknowledged writes missing afterwards).
#
# Usage: scripts/portal-failover-drill.sh app|data [--failback]
# Requires: az login, jq, the portal deployed on the real app image.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODE="${1:-}"; FAILBACK="${2:-}"
out() { terraform -chdir="$ROOT/portal" output "$@"; }
now() { python3 -c 'import time; print(f"{time.time():.3f}")'; }
URL="$(out -raw portal_url)"

app_drill() {
  local primary_app primary_rg secondary_loc
  primary_app="$(out -json container_app_names | jq -r .primary)"
  primary_rg="$(out -json region_resource_groups | jq -r .primary)"
  secondary_loc="$(out -json region_locations | jq -r .secondary)"

  echo "== App-tier drill: disabling ingress on $primary_app"
  local t0 t1 served failed=0
  t0="$(now)"
  az containerapp ingress disable -n "$primary_app" -g "$primary_rg" >/dev/null
  while true; do
    served="$(curl -s -m 10 -D - -o /dev/null "$URL/health" | awk -F': ' 'tolower($1)=="x-served-by-region"{print $2}' | tr -d '\r')"
    if [ "$served" = "$secondary_loc" ]; then t1="$(now)"; break; fi
    failed=$((failed + 1)); sleep 2
  done
  printf "  Front Door moved traffic to %s in %.1fs (%d probes before switch)\n" \
    "$secondary_loc" "$(python3 -c "print($t1-$t0)")" "$failed"

  echo "== Restoring ingress on $primary_app (next terraform apply also reconciles it)"
  az containerapp ingress enable -n "$primary_app" -g "$primary_rg" \
    --type external --target-port 8080 --transport auto >/dev/null
}

data_drill() {
  local fog rg target log writer t0 t1
  fog="$(out -json sql_failover_group | jq -r .name)"
  rg="$(out -json sql_failover_group | jq -r .resource_group)"
  target="$(out -json sql_failover_group | jq -r .secondary)"
  [ "$FAILBACK" = "--failback" ] && target="$(out -json sql_failover_group | jq -r .primary)"
  log="$(mktemp)"

  echo "== Data-tier drill: before -> $(curl -s -m 10 "$URL/health" | jq -c '{sql_server, updateability}')"
  ( n=0; while true; do
      n=$((n + 1))
      ts="$(now)"
      body="$(curl -s -m 10 -w '\n%{http_code}' -X POST "$URL/api/orders" -H 'Content-Type: application/json' \
        -d "{\"pharmacy\":\"Failover Drill\",\"item\":\"seq-$n\",\"quantity\":1}")"
      code="$(tail -n1 <<<"$body")"; id="$(head -n1 <<<"$body" | jq -r '.id // empty' 2>/dev/null)"
      echo "$ts $code ${id:-none}" >>"$log"
      sleep 1
    done ) &
  writer=$!
  sleep 10

  echo "== Planned failover of $fog to $target (no data loss by design)"
  t0="$(now)"
  az sql failover-group set-primary --name "$fog" --resource-group "$rg" --server "$target" >/dev/null
  t1="$(now)"
  sleep 30
  kill "$writer" 2>/dev/null; wait "$writer" 2>/dev/null

  echo "== After -> $(curl -s -m 10 "$URL/health" | jq -c '{sql_server, updateability}')"
  python3 - "$log" "$t0" "$t1" "$URL" <<'PY'
import sys
log, t0, t1, url = sys.argv[1], float(sys.argv[2]), float(sys.argv[3]), sys.argv[4]
rows = [l.split() for l in open(log) if l.strip()]
rows = [(float(t), c, i) for t, c, i in rows]
ok = [r for r in rows if r[1] == "201"]
# RTO: longest stretch between consecutive successful writes during the drill.
gap, prev = 0.0, None
for t, c, _ in rows:
    if c == "201":
        if prev is not None:
            gap = max(gap, t - prev)
        prev = t
failed = sum(1 for r in rows if r[1] != "201")
# RPO: every acknowledged write must still exist after the failover. Checked
# with curl, not urllib: a python.org macOS install ships without CA
# certificates, so urllib fails TLS and would report every write as lost.
import subprocess
missing = 0
for _, _, i in ok:
    code = subprocess.run(["curl", "-s", "-o", "/dev/null", "-w", "%{http_code}", "-m", "10",
                           f"{url}/api/orders/{i}"], capture_output=True, text=True).stdout
    if code != "200":
        missing += 1
print(f"  failover command took      {t1 - t0:6.1f}s")
print(f"  writes attempted/failed    {len(rows)}/{failed}")
print(f"  RTO (longest write gap)    {gap:6.1f}s")
print(f"  RPO (acknowledged lost)    {missing} of {len(ok)} writes")
PY
  rm -f "$log"
}

case "$MODE" in
  app)  app_drill ;;
  data) data_drill ;;
  *) echo "usage: $0 app|data [--failback]"; exit 2 ;;
esac
