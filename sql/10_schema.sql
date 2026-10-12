-- =============================================================================
-- 10 · schemas and tables
--
--   core      reference data: clients, estates, gates, index weights
--   silver    conformed record-level data written by the ingestion layer
--             (Fabric pipelines / eventstream in Azure; the simulator here)
--   calc      internal calculation views - never exposed
--   contract  the governed views Data API builder exposes. One definition
--             per figure; every portal number comes from one of these.
--   ingest    write procedures the ingestion identity is allowed to call
--   sec       row-level security predicate and policy
--
-- Every client-scoped table carries client_code so the RLS predicate can
-- filter it directly. Estates are coded; no names are stored.
-- =============================================================================
SET NOCOUNT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

IF SCHEMA_ID(N'core') IS NULL     EXEC (N'CREATE SCHEMA core');
IF SCHEMA_ID(N'silver') IS NULL   EXEC (N'CREATE SCHEMA silver');
IF SCHEMA_ID(N'calc') IS NULL     EXEC (N'CREATE SCHEMA calc');
IF SCHEMA_ID(N'contract') IS NULL EXEC (N'CREATE SCHEMA contract');
IF SCHEMA_ID(N'ingest') IS NULL   EXEC (N'CREATE SCHEMA ingest');
IF SCHEMA_ID(N'sec') IS NULL      EXEC (N'CREATE SCHEMA sec');
GO

-- ---------------------------------------------------------------- core ------
CREATE TABLE core.client (
    client_code     varchar(8)    NOT NULL CONSTRAINT pk_client PRIMARY KEY,
    portfolio_label nvarchar(60)  NOT NULL
);

CREATE TABLE core.estate (
    estate_code     varchar(10)   NOT NULL CONSTRAINT pk_estate PRIMARY KEY,
    client_code     varchar(8)    NOT NULL CONSTRAINT fk_estate_client REFERENCES core.client (client_code),
    emirate         nvarchar(30)  NOT NULL,
    region          nvarchar(30)  NOT NULL,          -- 'Abu Dhabi' | 'Northern Emirates'
    tier            tinyint       NOT NULL CONSTRAINT ck_estate_tier CHECK (tier BETWEEN 1 AND 3),
    status_label    nvarchar(20)  NOT NULL,          -- 'Active' | 'Dormant'
    class_label     nvarchar(20)  NOT NULL,          -- 'Icon' | 'Residential'
    map_x           decimal(6,1)  NOT NULL,          -- stylised map position, approximate
    map_y           decimal(6,1)  NOT NULL,
    label_pos       varchar(2)    NOT NULL,
    managed_since   smallint      NOT NULL
);
CREATE INDEX ix_estate_client ON core.estate (client_code);

-- Invisible Care Index weights (mapping M011: weights pending SME sign-off).
-- Held as data so a change of weights is an UPDATE, not a release.
CREATE TABLE core.index_weight (
    component   varchar(20)   NOT NULL CONSTRAINT pk_index_weight PRIMARY KEY,
    weight      decimal(4,2)  NOT NULL,
    note        nvarchar(120) NULL,
    updated_at  datetime2(0)  NOT NULL CONSTRAINT df_index_weight_upd DEFAULT SYSUTCDATETIME()
);

CREATE TABLE core.procurement_gate (
    gate_no    tinyint      NOT NULL CONSTRAINT pk_procurement_gate PRIMARY KEY,
    gate_name  nvarchar(40) NOT NULL
);

CREATE TABLE core.work_stage (
    item_type   varchar(10)  NOT NULL,               -- 'Project' | 'On-Demand'
    stage_no    tinyint      NOT NULL,
    stage_name  nvarchar(40) NOT NULL,
    CONSTRAINT pk_work_stage PRIMARY KEY (item_type, stage_no)
);
GO

-- -------------------------------------------------------------- silver ------
-- MRI CAFM work orders (mapping M001-M003)
CREATE TABLE silver.work_order (
    wo_id         int IDENTITY(1,1) NOT NULL CONSTRAINT pk_work_order PRIMARY KEY,
    source_ref    varchar(20)   NOT NULL CONSTRAINT uq_work_order_ref UNIQUE,
    client_code   varchar(8)    NOT NULL,
    estate_code   varchar(10)   NOT NULL CONSTRAINT fk_wo_estate REFERENCES core.estate (estate_code),
    wo_type       varchar(10)   NOT NULL CONSTRAINT ck_wo_type CHECK (wo_type IN ('PPM', 'Reactive')),
    priority      tinyint       NOT NULL CONSTRAINT ck_wo_priority CHECK (priority BETWEEN 1 AND 4),
    status        varchar(12)   NOT NULL CONSTRAINT ck_wo_status CHECK (status IN ('Open', 'InProgress', 'OnHold', 'Completed', 'Cancelled')),
    asset_class   nvarchar(40)  NULL,
    summary       nvarchar(120) NULL,
    created_at    datetime2(0)  NOT NULL,
    due_at        datetime2(0)  NULL,                -- PPM scheduled date
    respond_by    datetime2(0)  NULL,                -- reactive SLA response target
    responded_at  datetime2(0)  NULL,
    completed_at  datetime2(0)  NULL,
    ingested_at   datetime2(0)  NOT NULL CONSTRAINT df_wo_ingested DEFAULT SYSUTCDATETIME()
);
CREATE INDEX ix_wo_estate_status ON silver.work_order (estate_code, status) INCLUDE (wo_type, priority, created_at);
CREATE INDEX ix_wo_client_completed ON silver.work_order (client_code, completed_at) INCLUDE (wo_type, respond_by, responded_at, created_at);

-- IoT environmental telemetry, windowed per zone by eventstream (mapping M070)
CREATE TABLE silver.sensor_reading (
    reading_id    bigint IDENTITY(1,1) NOT NULL CONSTRAINT pk_sensor_reading PRIMARY KEY,
    client_code   varchar(8)    NOT NULL,
    estate_code   varchar(10)   NOT NULL CONSTRAINT fk_reading_estate REFERENCES core.estate (estate_code),
    zone          nvarchar(40)  NOT NULL,
    metric        varchar(16)   NOT NULL CONSTRAINT ck_reading_metric CHECK (metric IN ('iaq', 'water_quality', 'humidity', 'fire_integrity', 'temp_c')),
    value         decimal(6,2)  NOT NULL,
    sensor_count  int           NOT NULL,
    read_at       datetime2(0)  NOT NULL,
    ingested_at   datetime2(0)  NOT NULL CONSTRAINT df_reading_ingested DEFAULT SYSUTCDATETIME()
);
CREATE INDEX ix_reading_estate_metric ON silver.sensor_reading (estate_code, metric, read_at DESC) INCLUDE (value, sensor_count);

-- D365 tender register (mapping M030-M032)
CREATE TABLE silver.tender (
    tender_ref        varchar(12)   NOT NULL CONSTRAINT pk_tender PRIMARY KEY,
    client_code       varchar(8)    NOT NULL,
    estate_code       varchar(10)   NULL CONSTRAINT fk_tender_estate REFERENCES core.estate (estate_code),   -- NULL = portfolio-wide
    scope             nvarchar(80)  NOT NULL,
    category          nvarchar(30)  NOT NULL,
    bidders           tinyint       NOT NULL,
    gates_passed      tinyint       NOT NULL CONSTRAINT ck_tender_gates CHECK (gates_passed BETWEEN 0 AND 13),
    status            varchar(10)   NOT NULL CONSTRAINT ck_tender_status CHECK (status IN ('On Track', 'At Risk', 'Overdue', 'Completed')),
    est_value_aed     decimal(14,0) NOT NULL,
    baseline_var_pct  decimal(5,1)  NOT NULL,
    scoped_at         datetime2(0)  NOT NULL,
    awarded_at        datetime2(0)  NULL,
    go_live_at        datetime2(0)  NULL,
    ingested_at       datetime2(0)  NOT NULL CONSTRAINT df_tender_ingested DEFAULT SYSUTCDATETIME()
);

CREATE TABLE silver.tender_gate_event (
    tender_ref   varchar(12)  NOT NULL CONSTRAINT fk_gate_event_tender REFERENCES silver.tender (tender_ref),
    gate_no      tinyint      NOT NULL CONSTRAINT fk_gate_event_gate REFERENCES core.procurement_gate (gate_no),
    client_code  varchar(8)   NOT NULL,
    passed_at    datetime2(0) NOT NULL,
    CONSTRAINT pk_tender_gate_event PRIMARY KEY (tender_ref, gate_no)
);

-- D365 HR + time & attendance (mapping M060-M061)
CREATE TABLE silver.clock_event (
    clock_id      bigint IDENTITY(1,1) NOT NULL CONSTRAINT pk_clock_event PRIMARY KEY,
    staff_ref     varchar(12)   NOT NULL,
    client_code   varchar(8)    NOT NULL,
    estate_code   varchar(10)   NOT NULL CONSTRAINT fk_clock_estate REFERENCES core.estate (estate_code),
    category      varchar(16)   NOT NULL CONSTRAINT ck_clock_category CHECK (category IN ('Technical', 'Soft services', 'Professional', 'Admin')),
    clock_in_at   datetime2(0)  NOT NULL,
    clock_out_at  datetime2(0)  NULL
);
CREATE INDEX ix_clock_open ON silver.clock_event (estate_code, clock_out_at) INCLUDE (category, clock_in_at);

CREATE TABLE silver.roster_plan (
    estate_code        varchar(10)  NOT NULL CONSTRAINT fk_roster_estate REFERENCES core.estate (estate_code),
    category           varchar(16)  NOT NULL,
    client_code        varchar(8)   NOT NULL,
    planned_headcount  int          NOT NULL,
    CONSTRAINT pk_roster_plan PRIMARY KEY (estate_code, category)
);

-- D365 F&O general ledger and budget (mapping M020-M022)
CREATE TABLE silver.gl_actual (
    estate_code     varchar(10)   NOT NULL CONSTRAINT fk_gl_estate REFERENCES core.estate (estate_code),
    period          int           NOT NULL,          -- yyyymm, closed periods only
    cost_dimension  varchar(16)   NOT NULL,
    client_code     varchar(8)    NOT NULL,
    amount_aed      decimal(14,0) NOT NULL,
    CONSTRAINT pk_gl_actual PRIMARY KEY (estate_code, period, cost_dimension)
);

CREATE TABLE silver.budget (
    estate_code     varchar(10)   NOT NULL CONSTRAINT fk_budget_estate REFERENCES core.estate (estate_code),
    period          int           NOT NULL,
    cost_dimension  varchar(16)   NOT NULL,
    client_code     varchar(8)    NOT NULL,
    amount_aed      decimal(14,0) NOT NULL,
    CONSTRAINT pk_budget PRIMARY KEY (estate_code, period, cost_dimension)
);

CREATE TABLE silver.capex_programme (
    estate_code  varchar(10)   NOT NULL CONSTRAINT fk_capex_estate REFERENCES core.estate (estate_code),
    fy           smallint      NOT NULL,
    client_code  varchar(8)    NOT NULL,
    budget_aed   decimal(14,0) NOT NULL,
    drawn_aed    decimal(14,0) NOT NULL,
    CONSTRAINT pk_capex_programme PRIMARY KEY (estate_code, fy)
);

-- MRI CAFM condition surveys, summarised per estate (mapping M010-M012)
CREATE TABLE silver.asset_condition (
    estate_code         varchar(10)   NOT NULL CONSTRAINT pk_asset_condition PRIMARY KEY
                                      CONSTRAINT fk_asset_estate REFERENCES core.estate (estate_code),
    client_code         varchar(8)    NOT NULL,
    assets_tagged       int           NOT NULL,
    condition_idx       decimal(5,1)  NOT NULL,
    good_fair_pct       decimal(5,1)  NOT NULL,
    critical_monitored  int           NOT NULL,
    beyond_life         int           NOT NULL,
    surveyed_at         datetime2(0)  NOT NULL
);

-- D365 Projects: capital projects and on-demand works (mapping M040-M041)
CREATE TABLE silver.work_item (
    item_ref      varchar(12)   NOT NULL CONSTRAINT pk_work_item PRIMARY KEY,
    client_code   varchar(8)    NOT NULL,
    estate_code   varchar(10)   NOT NULL CONSTRAINT fk_item_estate REFERENCES core.estate (estate_code),
    item_name     nvarchar(80)  NOT NULL,
    item_type     varchar(10)   NOT NULL CONSTRAINT ck_item_type CHECK (item_type IN ('Project', 'On-Demand')),
    stages_done   tinyint       NOT NULL,
    status        varchar(10)   NOT NULL CONSTRAINT ck_item_status CHECK (status IN ('On Track', 'At Risk', 'Overdue', 'Completed')),
    value_aed     decimal(14,0) NOT NULL,
    reported_at   datetime2(0)  NOT NULL,
    completed_at  datetime2(0)  NULL
);

-- Management narrative attached to auto-flagged exceptions. The exception
-- itself is computed (contract.vw_exceptions); people only add the action.
CREATE TABLE silver.exception_action (
    exception_key  varchar(48)   NOT NULL CONSTRAINT pk_exception_action PRIMARY KEY,
    client_code    varchar(8)    NOT NULL,
    cause_note     nvarchar(160) NULL,
    action_text    nvarchar(200) NOT NULL,
    owner_team     nvarchar(40)  NOT NULL,
    updated_at     datetime2(0)  NOT NULL CONSTRAINT df_exception_action_upd DEFAULT SYSUTCDATETIME()
);

-- One row per ingested source event: feeds data-health (M090) and the activity feed
CREATE TABLE silver.ingest_log (
    event_id       bigint IDENTITY(1,1) NOT NULL CONSTRAINT pk_ingest_log PRIMARY KEY,
    client_code    varchar(8)    NOT NULL,
    estate_code    varchar(10)   NULL,
    source_system  varchar(20)   NOT NULL,
    event_type     varchar(30)   NOT NULL,
    entity_ref     varchar(20)   NULL,
    detail         nvarchar(160) NULL,
    ingested_at    datetime2(3)  NOT NULL CONSTRAINT df_ingest_log_at DEFAULT SYSUTCDATETIME()
);
CREATE INDEX ix_ingest_log_client_source ON silver.ingest_log (client_code, source_system, ingested_at DESC);
GO
