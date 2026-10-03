#!/usr/bin/env bash
# End-to-end smoke test of the deployed portal: health through Front Door, a
# write and a read, the daily report, the WAF, and the partner API through APIM.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
URL="$(terraform -chdir="$ROOT/portal" output -raw portal_url)"
pass=0; fail=0
ok()  { echo "  PASS: $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL: $1"; fail=$((fail + 1)); }

echo "== Portal smoke test: $URL =="

health="$(curl -s -m 20 "$URL/health")"
if [ "$(jq -r .status <<<"$health" 2>/dev/null)" = "ok" ]; then
  ok "health via Front Door: $(jq -c '{region, sql_server, updateability}' <<<"$health")"
else
  bad "health via Front Door returned: $health"
fi

created="$(curl -s -m 20 -X POST "$URL/api/orders" -H 'Content-Type: application/json' \
  -d '{"pharmacy":"Smoke Test Pharmacy","item":"Amoxicillin 500mg","quantity":3}')"
id="$(jq -r .id <<<"$created" 2>/dev/null)"
if [[ "$id" =~ ^[0-9]+$ ]]; then ok "order written (id $id) in $(jq -r .region <<<"$created")"; else bad "order write: $created"; fi

if [ "$(curl -s -m 20 -o /dev/null -w '%{http_code}' "$URL/api/orders/$id")" = "200" ]; then
  ok "order read back"; else bad "order read back"; fi

if curl -s -m 20 "$URL/api/reports/daily" | jq -e .by_region >/dev/null 2>&1; then
  ok "daily report (Logic App target)"; else bad "daily report"; fi

# A classic SQL injection probe should be blocked by the managed rule set.
code="$(curl -s -m 20 -o /dev/null -w '%{http_code}' "$URL/api/orders?limit=1%27%20OR%201%3D1--")"
if [ "$code" = "403" ]; then ok "WAF blocked a SQL injection probe (403)"; else bad "WAF did not block the probe (HTTP $code)"; fi

APIM="$(terraform -chdir="$ROOT/portal" output -raw apim_gateway_url 2>/dev/null || true)"
if [ -n "$APIM" ] && [ "$APIM" != "null" ]; then
  KEY="$(terraform -chdir="$ROOT/portal" output -raw apim_demo_partner_key)"
  code="$(curl -s -m 30 -o /dev/null -w '%{http_code}' "$APIM/partners/orders" -H "Ocp-Apim-Subscription-Key: $KEY")"
  if [ "$code" = "200" ]; then ok "partner API through APIM with a key"; else bad "partner API with key (HTTP $code)"; fi
  code="$(curl -s -m 30 -o /dev/null -w '%{http_code}' "$APIM/partners/orders")"
  if [ "$code" = "401" ]; then ok "partner API without a key is rejected (401)"; else bad "partner API without key (HTTP $code)"; fi
fi

echo ""
echo "== $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
