-- =============================================================================
-- Client Intelligence Portal · DAB live-read POC
-- 00 · database and logins (run in master)
--
-- Two application principals, least privilege:
--   dab_reader  - the identity Data API builder connects with. SELECT on the
--                 contract schema only. Row-level security applies to it.
--   cip_ingest  - the identity the ingestion layer writes with (Fabric
--                 pipelines / eventstream in Azure; the simulator in this POC).
--                 EXECUTE on the ingest procedures only.
-- In Azure these become managed identities (Entra auth), not SQL logins.
-- =============================================================================
SET NOCOUNT ON;

IF DB_ID(N'cip') IS NULL
    CREATE DATABASE cip;
GO

IF SUSER_ID(N'dab_reader') IS NULL
    EXEC (N'CREATE LOGIN dab_reader WITH PASSWORD = N''$(DAB_READER_PASSWORD)'', CHECK_POLICY = ON;');
GO

IF SUSER_ID(N'cip_ingest') IS NULL
    EXEC (N'CREATE LOGIN cip_ingest WITH PASSWORD = N''$(CIP_INGEST_PASSWORD)'', CHECK_POLICY = ON;');
GO
