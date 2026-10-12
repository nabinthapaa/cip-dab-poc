-- =============================================================================
-- CIP POC on Supabase · 001 schema
-- Postgres port of sql/10_schema.sql. Same tables, same columns, same keys.
--   cip_core    reference data          cip_silver  conformed record-level data
--   cip_calc    calculation views        public      contract views (vw_*) = the API
--   cip_ingest  write path + simulator   cip_sec     row-level security plumbing
-- Only public is exposed by Supabase's Data API, so only the contract views
-- are reachable over HTTP.
-- =============================================================================
create schema if not exists cip_core;
create schema if not exists cip_silver;
create schema if not exists cip_calc;
create schema if not exists cip_ingest;
create schema if not exists cip_sec;

create or replace function cip_core.utc_now() returns timestamp(0)
language sql stable set search_path = '' as $$ select (now() at time zone 'utc')::timestamp(0) $$;

-- ---------------------------------------------------------------- core ------
create table cip_core.client (
  client_code     varchar(8)  primary key,
  portfolio_label varchar(60) not null
);

create table cip_core.estate (
  estate_code   varchar(10)  primary key,
  client_code   varchar(8)   not null references cip_core.client (client_code),
  emirate       varchar(30)  not null,
  region        varchar(30)  not null,
  tier          smallint     not null check (tier between 1 and 3),
  status_label  varchar(20)  not null,
  class_label   varchar(20)  not null,
  map_x         numeric(6,1) not null,
  map_y         numeric(6,1) not null,
  label_pos     varchar(2)   not null,
  managed_since smallint     not null
);
create index ix_estate_client on cip_core.estate (client_code);

create table cip_core.index_weight (
  component  varchar(20)  primary key,
  weight     numeric(4,2) not null,
  note       varchar(120),
  updated_at timestamp(0) not null default cip_core.utc_now()
);

create table cip_core.procurement_gate (
  gate_no   smallint    primary key,
  gate_name varchar(40) not null
);

create table cip_core.work_stage (
  item_type  varchar(10) not null,
  stage_no   smallint    not null,
  stage_name varchar(40) not null,
  primary key (item_type, stage_no)
);

-- -------------------------------------------------------------- silver ------
create table cip_silver.work_order (
  wo_id        int generated always as identity primary key,
  source_ref   varchar(20)  not null unique,
  client_code  varchar(8)   not null,
  estate_code  varchar(10)  not null references cip_core.estate (estate_code),
  wo_type      varchar(10)  not null check (wo_type in ('PPM', 'Reactive')),
  priority     smallint     not null check (priority between 1 and 4),
  status       varchar(12)  not null check (status in ('Open', 'InProgress', 'OnHold', 'Completed', 'Cancelled')),
  asset_class  varchar(40),
  summary      varchar(120),
  created_at   timestamp(0) not null,
  due_at       timestamp(0),
  respond_by   timestamp(0),
  responded_at timestamp(0),
  completed_at timestamp(0),
  ingested_at  timestamp(0) not null default cip_core.utc_now()
);
create index ix_wo_estate_status on cip_silver.work_order (estate_code, status);
create index ix_wo_client_completed on cip_silver.work_order (client_code, completed_at);

create table cip_silver.sensor_reading (
  reading_id   bigint generated always as identity primary key,
  client_code  varchar(8)   not null,
  estate_code  varchar(10)  not null references cip_core.estate (estate_code),
  zone         varchar(40)  not null,
  metric       varchar(16)  not null check (metric in ('iaq', 'water_quality', 'humidity', 'fire_integrity', 'temp_c')),
  value        numeric(6,2) not null,
  sensor_count int          not null,
  read_at      timestamp(0) not null,
  ingested_at  timestamp(0) not null default cip_core.utc_now()
);
create index ix_reading_estate_metric on cip_silver.sensor_reading (estate_code, metric, read_at desc);

-- Latest 15-minute window per estate and metric, maintained on ingest (what an
-- eventstream tumbling window would land). Views read this, not the raw stream.
create table cip_silver.sensor_window (
  estate_code  varchar(10)  not null references cip_core.estate (estate_code),
  metric       varchar(16)  not null,
  client_code  varchar(8)   not null,
  value        numeric(6,1) not null,
  sensor_count int          not null,
  last_read_at timestamp(0) not null,
  primary key (estate_code, metric)
);

create table cip_silver.tender (
  tender_ref       varchar(12)   primary key,
  client_code      varchar(8)    not null,
  estate_code      varchar(10)   references cip_core.estate (estate_code),
  scope            varchar(80)   not null,
  category         varchar(30)   not null,
  bidders          smallint      not null,
  gates_passed     smallint      not null check (gates_passed between 0 and 13),
  status           varchar(10)   not null check (status in ('On Track', 'At Risk', 'Overdue', 'Completed')),
  est_value_aed    numeric(14,0) not null,
  baseline_var_pct numeric(5,1)  not null,
  scoped_at        timestamp(0)  not null,
  awarded_at       timestamp(0),
  go_live_at       timestamp(0),
  ingested_at      timestamp(0)  not null default cip_core.utc_now()
);

create table cip_silver.tender_gate_event (
  tender_ref  varchar(12)  not null references cip_silver.tender (tender_ref),
  gate_no     smallint     not null references cip_core.procurement_gate (gate_no),
  client_code varchar(8)   not null,
  passed_at   timestamp(0) not null,
  primary key (tender_ref, gate_no)
);

create table cip_silver.clock_event (
  clock_id     bigint generated always as identity primary key,
  staff_ref    varchar(12)  not null,
  client_code  varchar(8)   not null,
  estate_code  varchar(10)  not null references cip_core.estate (estate_code),
  category     varchar(16)  not null check (category in ('Technical', 'Soft services', 'Professional', 'Admin')),
  clock_in_at  timestamp(0) not null,
  clock_out_at timestamp(0)
);
create index ix_clock_open on cip_silver.clock_event (estate_code, clock_out_at);

create table cip_silver.roster_plan (
  estate_code       varchar(10) not null references cip_core.estate (estate_code),
  category          varchar(16) not null,
  client_code       varchar(8)  not null,
  planned_headcount int         not null,
  primary key (estate_code, category)
);

create table cip_silver.gl_actual (
  estate_code    varchar(10)   not null references cip_core.estate (estate_code),
  period         int           not null,
  cost_dimension varchar(16)   not null,
  client_code    varchar(8)    not null,
  amount_aed     numeric(14,0) not null,
  primary key (estate_code, period, cost_dimension)
);

create table cip_silver.budget (
  estate_code    varchar(10)   not null references cip_core.estate (estate_code),
  period         int           not null,
  cost_dimension varchar(16)   not null,
  client_code    varchar(8)    not null,
  amount_aed     numeric(14,0) not null,
  primary key (estate_code, period, cost_dimension)
);

create table cip_silver.capex_programme (
  estate_code varchar(10)   not null references cip_core.estate (estate_code),
  fy          smallint      not null,
  client_code varchar(8)    not null,
  budget_aed  numeric(14,0) not null,
  drawn_aed   numeric(14,0) not null,
  primary key (estate_code, fy)
);

create table cip_silver.asset_condition (
  estate_code        varchar(10)  primary key references cip_core.estate (estate_code),
  client_code        varchar(8)   not null,
  assets_tagged      int          not null,
  condition_idx      numeric(5,1) not null,
  good_fair_pct      numeric(5,1) not null,
  critical_monitored int          not null,
  beyond_life        int          not null,
  surveyed_at        timestamp(0) not null
);

create table cip_silver.work_item (
  item_ref     varchar(12)   primary key,
  client_code  varchar(8)    not null,
  estate_code  varchar(10)   not null references cip_core.estate (estate_code),
  item_name    varchar(80)   not null,
  item_type    varchar(10)   not null check (item_type in ('Project', 'On-Demand')),
  stages_done  smallint      not null,
  status       varchar(10)   not null check (status in ('On Track', 'At Risk', 'Overdue', 'Completed')),
  value_aed    numeric(14,0) not null,
  reported_at  timestamp(0)  not null,
  completed_at timestamp(0)
);

create table cip_silver.exception_action (
  exception_key varchar(48)  primary key,
  client_code   varchar(8)   not null,
  cause_note    varchar(160),
  action_text   varchar(200) not null,
  owner_team    varchar(40)  not null,
  updated_at    timestamp(0) not null default cip_core.utc_now()
);

create table cip_silver.ingest_log (
  event_id      bigint generated always as identity primary key,
  client_code   varchar(8)   not null,
  estate_code   varchar(10),
  source_system varchar(20)  not null,
  event_type    varchar(30)  not null,
  entity_ref    varchar(20),
  detail        varchar(160),
  ingested_at   timestamp(3) not null default (now() at time zone 'utc')
);
create index ix_ingest_log_client_source on cip_silver.ingest_log (client_code, source_system, ingested_at desc);
