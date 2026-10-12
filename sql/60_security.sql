-- =============================================================================
-- 60 · users, grants and row-level security
--
-- Data API builder runs with "set-session-context": true, so every request
-- arrives with the caller's token claims in SESSION_CONTEXT. The filter
-- predicate below keeps only rows whose client_code equals the caller's
-- client_code claim. No claim -> no rows. The portal cannot widen this: it
-- never sends SQL, and DAB's identity can only SELECT the contract views.
-- =============================================================================
SET NOCOUNT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

IF USER_ID(N'dab_reader') IS NULL CREATE USER dab_reader FOR LOGIN dab_reader;
IF USER_ID(N'cip_ingest') IS NULL CREATE USER cip_ingest FOR LOGIN cip_ingest;
GO

-- DAB: read the contract, nothing else. Contract views reach calc/silver/core
-- through ownership chaining (all owned by dbo), so no grants are needed there;
-- the DENYs document intent and block any direct query.
GRANT SELECT ON SCHEMA::contract TO dab_reader;
DENY  SELECT ON SCHEMA::silver   TO dab_reader;
DENY  SELECT ON SCHEMA::calc     TO dab_reader;
DENY  SELECT ON SCHEMA::core     TO dab_reader;

-- Ingestion: write through the procedures; read silver/core to pick records.
GRANT EXECUTE ON SCHEMA::ingest TO cip_ingest;
GRANT SELECT  ON SCHEMA::silver TO cip_ingest;
GRANT SELECT  ON SCHEMA::core   TO cip_ingest;
GO

IF OBJECT_ID(N'sec.client_isolation', N'SP') IS NOT NULL
    DROP SECURITY POLICY sec.client_isolation;
GO
CREATE OR ALTER FUNCTION sec.fn_client_filter (@client_code varchar(8))
RETURNS TABLE
WITH SCHEMABINDING
AS
RETURN
    SELECT 1 AS allowed
    WHERE @client_code = CAST(SESSION_CONTEXT(N'client_code') AS varchar(8))
       OR USER_NAME() = N'cip_ingest';      -- the ingestion identity writes for every client
GO

CREATE SECURITY POLICY sec.client_isolation
    ADD FILTER PREDICATE sec.fn_client_filter(client_code) ON core.client,
    ADD FILTER PREDICATE sec.fn_client_filter(client_code) ON core.estate,
    ADD FILTER PREDICATE sec.fn_client_filter(client_code) ON silver.work_order,
    ADD FILTER PREDICATE sec.fn_client_filter(client_code) ON silver.sensor_reading,
    ADD FILTER PREDICATE sec.fn_client_filter(client_code) ON silver.tender,
    ADD FILTER PREDICATE sec.fn_client_filter(client_code) ON silver.tender_gate_event,
    ADD FILTER PREDICATE sec.fn_client_filter(client_code) ON silver.clock_event,
    ADD FILTER PREDICATE sec.fn_client_filter(client_code) ON silver.roster_plan,
    ADD FILTER PREDICATE sec.fn_client_filter(client_code) ON silver.gl_actual,
    ADD FILTER PREDICATE sec.fn_client_filter(client_code) ON silver.budget,
    ADD FILTER PREDICATE sec.fn_client_filter(client_code) ON silver.capex_programme,
    ADD FILTER PREDICATE sec.fn_client_filter(client_code) ON silver.asset_condition,
    ADD FILTER PREDICATE sec.fn_client_filter(client_code) ON silver.work_item,
    ADD FILTER PREDICATE sec.fn_client_filter(client_code) ON silver.exception_action,
    ADD FILTER PREDICATE sec.fn_client_filter(client_code) ON silver.ingest_log
WITH (STATE = ON, SCHEMABINDING = ON);
GO

-- Quick check as an administrator (sees nothing until a client is set):
--   EXEC sp_set_session_context N'client_code', 'CL01';
--   SELECT COUNT(*) FROM contract.vw_estate;   -- 10
--   EXEC sp_set_session_context N'client_code', 'CL02';
--   SELECT COUNT(*) FROM contract.vw_estate;   -- 3
