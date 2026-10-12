#!/usr/bin/env bash
# =============================================================================
# Smoke test for the running stack:  docker compose up -d && tests/smoke.sh
# Works against the dev server too:  BASE=http://localhost:8080 tests/smoke.sh
# Exit code 0 = all checks passed.
# =============================================================================
set -uo pipefail
BASE=${BASE:-http://localhost:8080}
K1=cl01-demo-7f3a9c
K2=cl02-demo-41be07
FORGED_CL01='eyJhdXRoX3R5cCI6ImFhZCIsIm5hbWVfdHlwIjoibmFtZSIsInJvbGVfdHlwIjoicm9sZXMiLCJjbGFpbXMiOlt7InR5cCI6Im5hbWUiLCJ2YWwiOiJjbDAxLnZpZXdlckBwb3J0YWwuZGVtbyJ9LHsidHlwIjoicm9sZXMiLCJ2YWwiOiJjbGllbnRfcmVhZGVyIn0seyJ0eXAiOiJjbGllbnRfY29kZSIsInZhbCI6IkNMMDEifV19'
pass=0; fail=0

check() { # name expected got
  if [ "$2" = "$3" ]; then printf '  \033[32mPASS\033[0m %-48s %s\n' "$1" "$3"; pass=$((pass+1))
  else printf '  \033[31mFAIL\033[0m %-48s expected %s, got %s\n' "$1" "$2" "$3"; fail=$((fail+1)); fi
}
status() { curl -s -o /dev/null -w '%{http_code}' "$@"; }
rows()   { python3 -c 'import json,sys; d=json.load(sys.stdin); print(len(d.get("value", [])))'; }
field()  { python3 -c "import json,sys; d=json.load(sys.stdin); print(d['value'][0]['$1'] if d.get('value') else '')"; }
get()    { curl -s -H "Ocp-Apim-Subscription-Key: $1" "$BASE/api/$2"; }

echo "CIP smoke test against $BASE"

echo "- front door"
check "portal served"                                 200 "$(status "$BASE/")"
check "no subscription key -> 401"                    401 "$(status "$BASE/api/vw_estate")"
check "unknown key -> 401"                            401 "$(status -H 'Ocp-Apim-Subscription-Key: nope' "$BASE/api/vw_estate")"
check "write attempt -> 403"                          403 "$(status -X POST -H "Ocp-Apim-Subscription-Key: $K1" "$BASE/api/vw_estate")"
check "object outside the contract -> 404"            404 "$(status -H "Ocp-Apim-Subscription-Key: $K1" "$BASE/api/work_order")"

echo "- row-level isolation (decided by the database)"
check "CL01 sees 10 estates"                          10 "$(get $K1 vw_estate | rows)"
check "CL02 sees 3 estates"                           3  "$(get $K2 vw_estate | rows)"
check "CL02 filtering for a CL01 estate gets 0 rows"  0  "$(get $K2 "vw_service_delivery?\$filter=estate_code%20eq%20'SP11021'" | rows)"
check "CL02 key + forged CL01 principal still 3"      3  "$(curl -s -H "Ocp-Apim-Subscription-Key: $K2" -H "X-MS-CLIENT-PRINCIPAL: $FORGED_CL01" "$BASE/api/vw_estate" | rows)"
check "CL01 portfolio KPI row is CL01"                CL01 "$(get $K1 vw_portfolio_kpi | field client_code)"
check "CL02 portfolio KPI row is CL02"                CL02 "$(get $K2 vw_portfolio_kpi | field client_code)"

echo "- contract shape"
for v in vw_estate vw_service_delivery vw_invisible_care vw_asset_mgmt vw_finance vw_finance_monthly vw_finance_dimension \
         vw_hr vw_procurement vw_tender vw_tender_gate vw_works vw_exceptions vw_activity vw_data_health vw_portfolio_kpi; do
  check "GET /api/$v"                                 200 "$(status -H "Ocp-Apim-Subscription-Key: $K1" "$BASE/api/$v")"
done

if [ "${SKIP_GRAPHQL:-0}" != "1" ]; then
echo "- GraphQL through the same door"
gql=$(curl -s -X POST -H "Ocp-Apim-Subscription-Key: $K2" -H 'Content-Type: application/json' \
      -d '{"query":"{ estates { items { estate_code } } }"}' "$BASE/graphql" \
      | python3 -c 'import json,sys; d=json.load(sys.stdin); print(len(((d.get("data") or {}).get("estates") or {}).get("items", [])))' 2>/dev/null)
check "GraphQL estates as CL02"                       3 "${gql:-error}"
fi

echo "- live: source events are flowing"
e1=$(get $K1 "vw_activity?\$orderby=event_id%20desc&\$first=1" | field event_id)
sleep 12
e2=$(get $K1 "vw_activity?\$orderby=event_id%20desc&\$first=1" | field event_id)
check "new ingest events within 12 s"                 yes "$([ -n "$e1" ] && [ -n "$e2" ] && [ "$e2" -gt "$e1" ] && echo yes || echo "no ($e1 -> $e2)")"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
