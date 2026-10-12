-- =============================================================================
-- 50 · ingest procedures - the write path for the ingestion identity
--
-- In Azure these are called by Fabric pipelines (scheduled MERGE by business
-- key) and by an eventstream sink (micro-batches as JSON). In this POC the
-- simulator calls exactly the same procedures, so swapping the simulator for
-- Fabric changes nothing downstream of silver.
-- Every call writes one silver.ingest_log row per client touched, which feeds
-- contract.vw_activity and contract.vw_data_health (M090).
-- =============================================================================
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

-- MRI CAFM work order: MERGE on the CAFM work-order number -----------------
CREATE OR ALTER PROCEDURE ingest.usp_mri_workorder_upsert
    @source_ref    varchar(20),
    @estate_code   varchar(10),
    @wo_type       varchar(10),
    @priority      tinyint,
    @status        varchar(12),
    @asset_class   nvarchar(40)  = NULL,
    @summary       nvarchar(120) = NULL,
    @created_at    datetime2(0),
    @due_at        datetime2(0)  = NULL,
    @respond_by    datetime2(0)  = NULL,
    @responded_at  datetime2(0)  = NULL,
    @completed_at  datetime2(0)  = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @client_code varchar(8) = (SELECT client_code FROM core.estate WHERE estate_code = @estate_code);
    IF @client_code IS NULL
        THROW 50001, N'Unknown estate_code', 1;

    DECLARE @merge_action TABLE (merge_action nvarchar(10));

    BEGIN TRANSACTION;

    MERGE silver.work_order WITH (HOLDLOCK) AS t
    USING (SELECT @source_ref AS source_ref) AS s
       ON t.source_ref = s.source_ref
    WHEN MATCHED THEN UPDATE SET
        t.priority     = @priority,
        t.status       = @status,
        t.asset_class  = ISNULL(@asset_class, t.asset_class),
        t.summary      = ISNULL(@summary, t.summary),
        t.due_at       = @due_at,
        t.respond_by   = @respond_by,
        t.responded_at = @responded_at,
        t.completed_at = @completed_at,
        t.ingested_at  = SYSUTCDATETIME()
    WHEN NOT MATCHED THEN INSERT
        (source_ref, client_code, estate_code, wo_type, priority, status, asset_class, summary,
         created_at, due_at, respond_by, responded_at, completed_at)
    VALUES
        (@source_ref, @client_code, @estate_code, @wo_type, @priority, @status, @asset_class, @summary,
         @created_at, @due_at, @respond_by, @responded_at, @completed_at)
    OUTPUT $action INTO @merge_action (merge_action);

    INSERT silver.ingest_log (client_code, estate_code, source_system, event_type, entity_ref, detail)
    SELECT
        @client_code,
        @estate_code,
        'MRI CAFM',
        CASE WHEN m.merge_action = N'INSERT' THEN 'WO raised'
             WHEN @status = 'Completed'      THEN 'WO completed'
             ELSE 'WO updated' END,
        @source_ref,
        (SELECT summary FROM silver.work_order WHERE source_ref = @source_ref)
    FROM @merge_action AS m;

    COMMIT TRANSACTION;
END;
GO

-- IoT telemetry: one eventstream window as a JSON array --------------------
-- [{"estate_code":"SP11021","zone":"Estate","metric":"iaq","value":96.1,
--   "sensor_count":170,"read_at":"2026-10-12T08:00:00"}, ...]
CREATE OR ALTER PROCEDURE ingest.usp_iot_reading_batch
    @readings nvarchar(max)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @rows TABLE (
        estate_code  varchar(10),
        zone         nvarchar(40),
        metric       varchar(16),
        value        decimal(6,2),
        sensor_count int,
        read_at      datetime2(0)
    );

    INSERT @rows (estate_code, zone, metric, value, sensor_count, read_at)
    SELECT estate_code, zone, metric, value, sensor_count, read_at
    FROM OPENJSON(@readings)
    WITH (
        estate_code  varchar(10)  '$.estate_code',
        zone         nvarchar(40) '$.zone',
        metric       varchar(16)  '$.metric',
        value        decimal(6,2) '$.value',
        sensor_count int          '$.sensor_count',
        read_at      datetime2(0) '$.read_at'
    );

    BEGIN TRANSACTION;

    INSERT silver.sensor_reading (client_code, estate_code, zone, metric, value, sensor_count, read_at)
    SELECT e.client_code, r.estate_code, r.zone, r.metric, r.value, r.sensor_count, r.read_at
    FROM @rows AS r
    JOIN core.estate AS e ON e.estate_code = r.estate_code;

    INSERT silver.ingest_log (client_code, estate_code, source_system, event_type, entity_ref, detail)
    SELECT
        e.client_code,
        CASE WHEN COUNT(DISTINCT r.estate_code) = 1 THEN MIN(r.estate_code) END,
        'IoT / Event Hub',
        'Telemetry window',
        NULL,
        CONCAT(COUNT(*), N' readings · ', COUNT(DISTINCT r.estate_code), N' estates · eventstream')
    FROM @rows AS r
    JOIN core.estate AS e ON e.estate_code = r.estate_code
    GROUP BY e.client_code;

    COMMIT TRANSACTION;
END;
GO

-- D365 tender register: new tender at gate 0 -------------------------------
CREATE OR ALTER PROCEDURE ingest.usp_d365_tender_register
    @tender_ref        varchar(12),
    @estate_code       varchar(10) = NULL,
    @client_code       varchar(8),
    @scope             nvarchar(80),
    @category          nvarchar(30),
    @bidders           tinyint,
    @est_value_aed     decimal(14,0),
    @scoped_at         datetime2(0)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRANSACTION;

    INSERT silver.tender (tender_ref, client_code, estate_code, scope, category, bidders, gates_passed,
                          status, est_value_aed, baseline_var_pct, scoped_at)
    VALUES (@tender_ref, @client_code, @estate_code, @scope, @category, @bidders, 0,
            'On Track', @est_value_aed, 0, @scoped_at);

    INSERT silver.ingest_log (client_code, estate_code, source_system, event_type, entity_ref, detail)
    VALUES (@client_code, @estate_code, 'D365 F&O', 'Tender registered', @tender_ref,
            CONCAT(@scope, N' · AED ', CONVERT(varchar(20), CAST(@est_value_aed / 1000000.0 AS decimal(9,1))), N'm'));

    COMMIT TRANSACTION;
END;
GO

-- D365 tender stage-gate passed --------------------------------------------
CREATE OR ALTER PROCEDURE ingest.usp_d365_tender_gate_passed
    @tender_ref  varchar(12),
    @gate_no     tinyint,
    @passed_at   datetime2(0),
    @status      varchar(10) = 'On Track'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @client_code varchar(8), @estate_code varchar(10), @gates_passed tinyint, @value decimal(14,0);
    SELECT @client_code = client_code, @estate_code = estate_code, @gates_passed = gates_passed, @value = est_value_aed
    FROM silver.tender
    WHERE tender_ref = @tender_ref;

    IF @client_code IS NULL
        THROW 50002, N'Unknown tender_ref', 1;
    IF @gate_no <> @gates_passed + 1
        THROW 50003, N'Gates must be passed in sequence', 1;

    BEGIN TRANSACTION;

    INSERT silver.tender_gate_event (tender_ref, gate_no, client_code, passed_at)
    VALUES (@tender_ref, @gate_no, @client_code, @passed_at);

    UPDATE silver.tender
    SET gates_passed = @gate_no,
        status       = CASE WHEN @gate_no = 13 THEN 'Completed' ELSE @status END,
        awarded_at   = CASE WHEN @gate_no = 11 THEN @passed_at ELSE awarded_at END,   -- Letter of Award
        go_live_at   = CASE WHEN @gate_no = 13 THEN @passed_at ELSE go_live_at END,
        ingested_at  = SYSUTCDATETIME()
    WHERE tender_ref = @tender_ref;

    INSERT silver.ingest_log (client_code, estate_code, source_system, event_type, entity_ref, detail)
    SELECT @client_code, @estate_code, 'D365 F&O', 'Tender gate passed', @tender_ref,
           CONCAT(N'Passed gate ', @gate_no, N' · ', g.gate_name, N' · AED ',
                  CONVERT(varchar(20), CAST(@value / 1000000.0 AS decimal(9,1))), N'm')
    FROM core.procurement_gate AS g
    WHERE g.gate_no = @gate_no;

    COMMIT TRANSACTION;
END;
GO

-- Scheduled pipeline heartbeat (daily ledger / projects syncs with no new
-- postings still prove the feed is alive for data health) --------------------
CREATE OR ALTER PROCEDURE ingest.usp_log_sync
    @source_system  varchar(20),
    @client_code    varchar(8),
    @detail         nvarchar(160)
AS
BEGIN
    SET NOCOUNT ON;
    INSERT silver.ingest_log (client_code, estate_code, source_system, event_type, entity_ref, detail)
    VALUES (@client_code, NULL, @source_system, 'Scheduled sync', NULL, @detail);
END;
GO

-- Housekeeping: telemetry is only read over its latest 15-minute window, so
-- keep a few hours for inspection and let the rest go ----------------------
CREATE OR ALTER PROCEDURE ingest.usp_housekeeping
    @keep_telemetry_hours int = 6,
    @keep_log_days        int = 14
AS
BEGIN
    SET NOCOUNT ON;
    DELETE FROM silver.sensor_reading WHERE read_at < DATEADD(hour, -@keep_telemetry_hours, SYSUTCDATETIME());
    DELETE FROM silver.ingest_log     WHERE ingested_at < DATEADD(day, -@keep_log_days, SYSUTCDATETIME());
    -- the simulator compresses months of reactive work into minutes; age its own
    -- completed work orders out so rolling KPIs stay near calibrated levels
    DELETE FROM silver.work_order
    WHERE source_ref LIKE 'WO-9%' AND status = 'Completed'
      AND completed_at < DATEADD(minute, -30, SYSUTCDATETIME());
END;
GO

-- Time & attendance: a batch of clock movements as JSON ----------------------
-- [{"staff_ref":"S11021-0042","estate_code":"SP11021","category":"Technical",
--   "direction":"IN","at":"2026-10-12T08:00:00"}, ...]
CREATE OR ALTER PROCEDURE ingest.usp_ta_clock_batch
    @events nvarchar(max)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @ev TABLE (
        staff_ref    varchar(12),
        estate_code  varchar(10),
        category     varchar(16),
        direction    varchar(3),
        at_utc       datetime2(0)
    );

    INSERT @ev (staff_ref, estate_code, category, direction, at_utc)
    SELECT staff_ref, estate_code, category, direction, at_utc
    FROM OPENJSON(@events)
    WITH (
        staff_ref    varchar(12)  '$.staff_ref',
        estate_code  varchar(10)  '$.estate_code',
        category     varchar(16)  '$.category',
        direction    varchar(3)   '$.direction',
        at_utc       datetime2(0) '$.at'
    );

    BEGIN TRANSACTION;

    UPDATE c
    SET c.clock_out_at = v.at_utc
    FROM silver.clock_event AS c
    JOIN @ev AS v
      ON v.staff_ref = c.staff_ref
     AND v.direction = 'OUT'
    WHERE c.clock_out_at IS NULL;

    INSERT silver.clock_event (staff_ref, client_code, estate_code, category, clock_in_at)
    SELECT v.staff_ref, e.client_code, v.estate_code, v.category, v.at_utc
    FROM @ev AS v
    JOIN core.estate AS e ON e.estate_code = v.estate_code
    WHERE v.direction = 'IN';

    INSERT silver.ingest_log (client_code, estate_code, source_system, event_type, entity_ref, detail)
    SELECT
        e.client_code,
        CASE WHEN COUNT(DISTINCT v.estate_code) = 1 THEN MIN(v.estate_code) END,
        'D365 HR + T&A',
        'Shift movements',
        NULL,
        CONCAT(SUM(CASE WHEN v.direction = 'IN' THEN 1 ELSE 0 END), N' clock-ins · ',
               SUM(CASE WHEN v.direction = 'OUT' THEN 1 ELSE 0 END), N' clock-outs')
    FROM @ev AS v
    JOIN core.estate AS e ON e.estate_code = v.estate_code
    GROUP BY e.client_code;

    COMMIT TRANSACTION;
END;
GO
