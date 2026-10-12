#!/bin/bash
# =============================================================================
# One-shot database initialisation (docker compose service "db-init").
# Creates the database, loads schema -> views -> seed -> procs -> security,
# then proves row-level security works as the DAB identity before exiting.
# Idempotent: skips when the database exists unless RESET_DB=1.
# =============================================================================
set -euo pipefail

SQLCMD=/opt/mssql-tools18/bin/sqlcmd
SA=(-S sql -U sa -P "$SA_PASSWORD" -C -b -I -f 65001)

echo "[init] waiting for SQL Server"
for i in $(seq 1 60); do
  if "$SQLCMD" "${SA[@]}" -Q "SELECT 1" -o /dev/null 2>/dev/null; then break; fi
  sleep 2
done

exists=$("$SQLCMD" "${SA[@]}" -h -1 -W -Q "SET NOCOUNT ON; SELECT CASE WHEN DB_ID('cip') IS NULL THEN 0 ELSE 1 END" | tr -d '[:space:]')
if [ "$exists" = "1" ] && [ "${RESET_DB:-0}" != "1" ]; then
  echo "[init] database cip already initialised - nothing to do (set RESET_DB=1 to rebuild)"
  exit 0
fi
if [ "$exists" = "1" ]; then
  echo "[init] RESET_DB=1 - dropping cip"
  "$SQLCMD" "${SA[@]}" -Q "ALTER DATABASE cip SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE cip;"
fi

echo "[init] 00_database.sql"
"$SQLCMD" "${SA[@]}" -d master -i /sql/00_database.sql \
  -v DAB_READER_PASSWORD="$DAB_READER_PASSWORD" CIP_INGEST_PASSWORD="$CIP_INGEST_PASSWORD"

for f in 10_schema 20_calc_views 30_contract_views 40_seed 50_ingest_procs 60_security; do
  echo "[init] $f.sql"
  "$SQLCMD" "${SA[@]}" -d cip -i "/sql/$f.sql"
done

# ---- prove RLS as the DAB identity ------------------------------------------
READER=(-S sql -U dab_reader -P "$DAB_READER_PASSWORD" -d cip -C -h -1 -W)
q() { "$SQLCMD" "${READER[@]}" -Q "SET NOCOUNT ON; $1" | tr -d '[:space:]'; }

none=$(q "SELECT COUNT(*) FROM contract.vw_estate;")
cl01=$(q "EXEC sp_set_session_context N'client_code', 'CL01'; SELECT COUNT(*) FROM contract.vw_estate;")
cl02=$(q "EXEC sp_set_session_context N'client_code', 'CL02'; SELECT COUNT(*) FROM contract.vw_estate;")
echo "[init] RLS check as dab_reader: no claim=$none  CL01=$cl01  CL02=$cl02"
if [ "$none" != "0" ] || [ "$cl01" != "10" ] || [ "$cl02" != "3" ]; then
  echo "[init] RLS check FAILED"; exit 1
fi

if "$SQLCMD" "${READER[@]}" -b -Q "SELECT TOP 1 1 FROM silver.work_order" -o /dev/null 2>/dev/null; then
  echo "[init] dab_reader can read silver directly - grants are wrong"; exit 1
fi
echo "[init] dab_reader is denied direct access to silver (as intended)"
echo "[init] done"
