-- =============================================================================
-- CIP POC on Supabase · one-shot setup (migrations 004–007)
-- Run AFTER 001–003. Paste the whole file into Supabase → SQL Editor → Run.
-- Runs as one transaction: either everything applies or nothing does.
-- Safe to run again: it rebuilds the demo data and re-registers the schedules.
-- =============================================================================


-- >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>> 004_security.sql
-- =============================================================================
-- CIP POC on Supabase · 004 grants and row-level security
--
-- Same rule as sql/60_security.sql: a caller sees only rows whose client_code
-- equals its client identity; no identity, no rows.
--
-- Where the identity comes from. DAB put the caller's token claims into SQL
-- Server SESSION_CONTEXT. Here the Netlify gateway (the only intended caller)
-- calls Supabase's Data API with two headers:
--   x-cip-client   the client the gateway resolved from the subscription key
--   x-cip-gateway  a shared secret only the gateway holds
-- PostgREST exposes request headers to SQL; cip_sec.request_client() returns
-- the client only when the secret's SHA-256 matches. Anyone calling the Data
-- API directly with the public key, with or without a forged x-cip-client,
-- gets zero rows.
-- =============================================================================

create table if not exists cip_sec.gateway_secret (
  label          text primary key,
  secret_sha256  text not null,
  created_at     timestamp(0) not null default cip_core.utc_now()
);
revoke all on cip_sec.gateway_secret from public, anon, authenticated;

create or replace function cip_sec.request_client() returns text
language plpgsql stable security definer set search_path = '' as $$
declare
  h      json := nullif(current_setting('request.headers', true), '')::json;
  client text;
  secret text;
begin
  if h is null then
    -- not an HTTP request (SQL console / tests): use an explicitly set session value
    return nullif(current_setting('cip.client_code', true), '');
  end if;
  client := h ->> 'x-cip-client';
  secret := h ->> 'x-cip-gateway';
  if client is null or secret is null then
    return null;
  end if;
  if exists (select 1 from cip_sec.gateway_secret g
              where g.secret_sha256 = encode(sha256(convert_to(secret, 'UTF8')), 'hex')) then
    return client;
  end if;
  return null;
end $$;

revoke all on function cip_sec.request_client() from public;
grant execute on function cip_sec.request_client() to anon;

-- ---------------------------------------------------------------- grants ----
-- anon reads through the invoker views, so it needs SELECT underneath. None of
-- these schemas are exposed by the Data API, so this adds no HTTP surface.
grant usage on schema cip_core, cip_silver, cip_calc, cip_sec to anon;
grant select on all tables in schema cip_core   to anon;
grant select on all tables in schema cip_silver to anon;
grant select on all tables in schema cip_calc   to anon;
revoke select on cip_sec.gateway_secret from anon;

-- contract views: read-only for anon, nothing for signed-in users
revoke all on public.vw_estate, public.vw_service_delivery, public.vw_invisible_care, public.vw_asset_mgmt,
              public.vw_finance, public.vw_finance_monthly, public.vw_finance_dimension, public.vw_hr,
              public.vw_procurement, public.vw_tender, public.vw_tender_gate, public.vw_works,
              public.vw_exceptions, public.vw_activity, public.vw_data_health, public.vw_portfolio_kpi
  from anon, authenticated;
grant select on public.vw_estate, public.vw_service_delivery, public.vw_invisible_care, public.vw_asset_mgmt,
                public.vw_finance, public.vw_finance_monthly, public.vw_finance_dimension, public.vw_hr,
                public.vw_procurement, public.vw_tender, public.vw_tender_gate, public.vw_works,
                public.vw_exceptions, public.vw_activity, public.vw_data_health, public.vw_portfolio_kpi
  to anon;

-- ------------------------------------------------------------------- RLS ----
do $$
declare t text;
begin
  foreach t in array array[
    'cip_core.client', 'cip_core.estate',
    'cip_silver.work_order', 'cip_silver.sensor_reading', 'cip_silver.sensor_window', 'cip_silver.tender', 'cip_silver.tender_gate_event',
    'cip_silver.clock_event', 'cip_silver.roster_plan', 'cip_silver.gl_actual', 'cip_silver.budget',
    'cip_silver.capex_programme', 'cip_silver.asset_condition', 'cip_silver.work_item',
    'cip_silver.exception_action', 'cip_silver.ingest_log']
  loop
    execute format('alter table %s enable row level security', t);
    execute format('drop policy if exists cip_client_isolation on %s', t);
    execute format('create policy cip_client_isolation on %s for select to anon '
                   'using (client_code = (select cip_sec.request_client()))', t);
  end loop;
end $$;

-- Reference tables hold no client data; RLS on, readable by anon.
alter table cip_core.index_weight     enable row level security;
alter table cip_core.procurement_gate enable row level security;
alter table cip_core.work_stage       enable row level security;
drop policy if exists cip_reference_read on cip_core.index_weight;
drop policy if exists cip_reference_read on cip_core.procurement_gate;
drop policy if exists cip_reference_read on cip_core.work_stage;
create policy cip_reference_read on cip_core.index_weight     for select to anon using (true);
create policy cip_reference_read on cip_core.procurement_gate for select to anon using (true);
create policy cip_reference_read on cip_core.work_stage       for select to anon using (true);
alter table cip_sec.gateway_secret enable row level security;


-- >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>> 005_ingest_and_simulator.sql
-- =============================================================================
-- CIP POC on Supabase · 005 ingest functions + source-event simulator
--
-- The ingest.* functions are the write path (port of sql/50_ingest_procs.sql).
-- The simulator calls them exactly as Fabric pipelines / eventstream would,
-- and runs inside the database on pg_cron (007), so nothing has to stay
-- running anywhere else. Nothing here is executable over the Data API.
-- =============================================================================

create or replace function cip_ingest.sla_minutes(p int) returns int
language sql immutable set search_path = '' as $$
  select case p when 1 then 30 when 2 then 60 when 3 then 240 else 1440 end
$$;

-- MRI CAFM work order: upsert on the CAFM work-order number ------------------
create or replace function cip_ingest.mri_workorder_upsert(
  p_source_ref varchar, p_estate_code varchar, p_wo_type varchar, p_priority int, p_status varchar,
  p_asset_class varchar, p_summary varchar, p_created_at timestamp, p_due_at timestamp,
  p_respond_by timestamp, p_responded_at timestamp, p_completed_at timestamp)
returns void language plpgsql set search_path = '' as $$
declare v_client varchar; v_inserted boolean; v_summary varchar;
begin
  select client_code into v_client from cip_core.estate where estate_code = p_estate_code;
  if v_client is null then raise exception 'Unknown estate_code %', p_estate_code; end if;

  insert into cip_silver.work_order as t (source_ref, client_code, estate_code, wo_type, priority, status, asset_class,
                                          summary, created_at, due_at, respond_by, responded_at, completed_at)
  values (p_source_ref, v_client, p_estate_code, p_wo_type, p_priority, p_status, p_asset_class,
          p_summary, p_created_at, p_due_at, p_respond_by, p_responded_at, p_completed_at)
  on conflict (source_ref) do update set
    priority = excluded.priority, status = excluded.status,
    asset_class = coalesce(excluded.asset_class, t.asset_class), summary = coalesce(excluded.summary, t.summary),
    due_at = excluded.due_at, respond_by = excluded.respond_by, responded_at = excluded.responded_at,
    completed_at = excluded.completed_at, ingested_at = cip_core.utc_now()
  returning (xmax = 0), t.summary into v_inserted, v_summary;

  insert into cip_silver.ingest_log (client_code, estate_code, source_system, event_type, entity_ref, detail)
  values (v_client, p_estate_code, 'MRI CAFM',
          case when v_inserted then 'WO raised' when p_status = 'Completed' then 'WO completed' else 'WO updated' end,
          p_source_ref,
          case when v_inserted then 'P' || p_priority || ' · ' || v_summary else v_summary end);
end $$;

-- Recompute the 15-minute window for the estate/metrics in a batch (all when null)
create or replace function cip_ingest.refresh_sensor_window(p_readings jsonb default null)
returns void language sql set search_path = '' as $$
  with keys as (
    select distinct r.estate_code, r.metric
    from jsonb_to_recordset(coalesce(p_readings, '[]'::jsonb)) as r(estate_code varchar, metric varchar)
    union
    select distinct estate_code, metric from cip_silver.sensor_reading where p_readings is null
  ), last as (
    select k.estate_code, k.metric,
           (select max(read_at) from cip_silver.sensor_reading s where s.estate_code = k.estate_code and s.metric = k.metric) as last_at
    from keys k
  )
  insert into cip_silver.sensor_window (estate_code, metric, client_code, value, sensor_count, last_read_at)
  select r.estate_code, r.metric, min(r.client_code), round(avg(r.value), 1), max(r.sensor_count), max(r.read_at)
  from last l
  join cip_silver.sensor_reading r
    on r.estate_code = l.estate_code and r.metric = l.metric and r.read_at > l.last_at - interval '15 minutes'
  group by r.estate_code, r.metric
  on conflict (estate_code, metric) do update
    set value = excluded.value, sensor_count = excluded.sensor_count,
        last_read_at = excluded.last_read_at, client_code = excluded.client_code;
$$;

-- IoT: one eventstream window as JSON ---------------------------------------
create or replace function cip_ingest.iot_reading_batch(p_readings jsonb)
returns void language plpgsql set search_path = '' as $$
begin
  insert into cip_silver.sensor_reading (client_code, estate_code, zone, metric, value, sensor_count, read_at)
  select e.client_code, r.estate_code, r.zone, r.metric, r.value, r.sensor_count, r.read_at
  from jsonb_to_recordset(p_readings) as r(estate_code varchar, zone varchar, metric varchar, value numeric,
                                           sensor_count int, read_at timestamp)
  join cip_core.estate e on e.estate_code = r.estate_code;

  perform cip_ingest.refresh_sensor_window(p_readings);

  insert into cip_silver.ingest_log (client_code, estate_code, source_system, event_type, entity_ref, detail)
  select e.client_code, case when count(distinct r.estate_code) = 1 then min(r.estate_code) end,
         'IoT / Event Hub', 'Telemetry window', null,
         count(*) || ' readings · ' || count(distinct r.estate_code) || ' estates · eventstream'
  from jsonb_to_recordset(p_readings) as r(estate_code varchar)
  join cip_core.estate e on e.estate_code = r.estate_code
  group by e.client_code;
end $$;

-- D365 tender register and stage-gates ----------------------------------------
create or replace function cip_ingest.d365_tender_register(
  p_tender_ref varchar, p_estate_code varchar, p_client_code varchar, p_scope varchar, p_category varchar,
  p_bidders int, p_est_value_aed numeric, p_scoped_at timestamp)
returns void language plpgsql set search_path = '' as $$
begin
  insert into cip_silver.tender (tender_ref, client_code, estate_code, scope, category, bidders, gates_passed, status,
                                 est_value_aed, baseline_var_pct, scoped_at)
  values (p_tender_ref, p_client_code, p_estate_code, p_scope, p_category, p_bidders, 0, 'On Track', p_est_value_aed, 0, p_scoped_at);
  insert into cip_silver.ingest_log (client_code, estate_code, source_system, event_type, entity_ref, detail)
  values (p_client_code, p_estate_code, 'D365 F&O', 'Tender registered', p_tender_ref,
          p_scope || ' · AED ' || round(p_est_value_aed / 1000000.0, 1) || 'm');
end $$;

create or replace function cip_ingest.d365_tender_gate_passed(
  p_tender_ref varchar, p_gate_no int, p_passed_at timestamp, p_status varchar default 'On Track')
returns void language plpgsql set search_path = '' as $$
declare t record;
begin
  select * into t from cip_silver.tender where tender_ref = p_tender_ref for update;
  if not found then raise exception 'Unknown tender_ref %', p_tender_ref; end if;
  if p_gate_no <> t.gates_passed + 1 then raise exception 'Gates must be passed in sequence'; end if;

  insert into cip_silver.tender_gate_event (tender_ref, gate_no, client_code, passed_at)
  values (p_tender_ref, p_gate_no, t.client_code, p_passed_at);
  update cip_silver.tender
     set gates_passed = p_gate_no,
         status       = case when p_gate_no = 13 then 'Completed' else p_status end,
         awarded_at   = case when p_gate_no = 11 then p_passed_at else awarded_at end,
         go_live_at   = case when p_gate_no = 13 then p_passed_at else go_live_at end,
         ingested_at  = cip_core.utc_now()
   where tender_ref = p_tender_ref;
  insert into cip_silver.ingest_log (client_code, estate_code, source_system, event_type, entity_ref, detail)
  select t.client_code, t.estate_code, 'D365 F&O', 'Tender gate passed', p_tender_ref,
         'Passed gate ' || p_gate_no || ' · ' || g.gate_name || ' · AED ' || round(t.est_value_aed / 1000000.0, 1) || 'm'
  from cip_core.procurement_gate g where g.gate_no = p_gate_no;
end $$;

-- Time & attendance: a batch of clock movements as JSON --------------------
create or replace function cip_ingest.ta_clock_batch(p_events jsonb)
returns void language plpgsql set search_path = '' as $$
begin
  update cip_silver.clock_event c set clock_out_at = v.at_utc
  from jsonb_to_recordset(p_events) as v(staff_ref varchar, direction varchar, at_utc timestamp)
  where v.direction = 'OUT' and v.staff_ref = c.staff_ref and c.clock_out_at is null;

  insert into cip_silver.clock_event (staff_ref, client_code, estate_code, category, clock_in_at)
  select v.staff_ref, e.client_code, v.estate_code, v.category, v.at_utc
  from jsonb_to_recordset(p_events) as v(staff_ref varchar, estate_code varchar, category varchar, direction varchar, at_utc timestamp)
  join cip_core.estate e on e.estate_code = v.estate_code
  where v.direction = 'IN';

  insert into cip_silver.ingest_log (client_code, estate_code, source_system, event_type, entity_ref, detail)
  select e.client_code, case when count(distinct v.estate_code) = 1 then min(v.estate_code) end,
         'D365 HR + T&A', 'Shift movements', null,
         count(*) filter (where v.direction = 'IN') || ' clock-ins · ' || count(*) filter (where v.direction = 'OUT') || ' clock-outs'
  from jsonb_to_recordset(p_events) as v(estate_code varchar, direction varchar)
  join cip_core.estate e on e.estate_code = v.estate_code
  group by e.client_code;
end $$;

create or replace function cip_ingest.log_sync(p_source_system varchar, p_client_code varchar, p_detail varchar)
returns void language sql set search_path = '' as $$
  insert into cip_silver.ingest_log (client_code, estate_code, source_system, event_type, entity_ref, detail)
  values (p_client_code, null, p_source_system, 'Scheduled sync', null, p_detail);
$$;

-- The simulator compresses months of reactive work into minutes. To keep the
-- rolling KPIs (SLA, MTTR, planned share) near their calibrated levels it ages
-- out its own completed work orders (WO-9xxxxx) after 30 minutes.
create or replace function cip_ingest.housekeeping(p_keep_telemetry_hours int default 6, p_keep_log_days int default 14)
returns void language sql set search_path = '' as $$
  delete from cip_silver.sensor_reading where read_at < cip_core.utc_now() - make_interval(hours => p_keep_telemetry_hours);
  delete from cip_silver.ingest_log where ingested_at < cip_core.utc_now() - make_interval(days => p_keep_log_days);
  delete from cip_silver.work_order
   where source_ref like 'WO-9%' and status = 'Completed' and completed_at < cip_core.utc_now() - interval '30 minutes';
$$;

-- =============================================================================
-- Simulator
-- =============================================================================
create table if not exists cip_ingest.sim_state (
  id       int primary key default 1 check (id = 1),
  tick     bigint not null default 0,
  seq      int    not null default 900000,
  scripted text
);
create table if not exists cip_ingest.sim_target (
  estate_code  varchar(10) primary key,
  client_code  varchar(8)  not null,
  open_target  int not null,
  p1p2_target  int not null,
  resp_min     numeric not null,
  staff_target int not null,
  weight       numeric not null
);
create table if not exists cip_ingest.sim_env (
  estate_code  varchar(10) not null,
  metric       varchar(16) not null,
  zone         varchar(40) not null,
  base         numeric not null,
  current      numeric not null,
  sensor_count int not null,
  primary key (estate_code, metric)
);
create table if not exists cip_ingest.fault (
  asset_class varchar(40) primary key,
  weight      int not null,
  fault_text  varchar(80) not null
);
create table if not exists cip_ingest.new_tender (
  scope    varchar(80) primary key,
  category varchar(30) not null,
  value_m  numeric not null
);

insert into cip_ingest.fault values
  ('AHUs & FAHUs', 31, 'AHU filter differential pressure high'), ('Water features & fountains', 18, 'fountain pump seal leak'),
  ('Irrigation systems', 16, 'irrigation zone valve fault'), ('Kitchen & F&B equipment', 14, 'cold room temperature alarm'),
  ('Elevators & escalators', 10, 'lift door sensor fault'), ('Chillers', 8, 'chiller high head-pressure trip'),
  ('Fire alarm devices', 6, 'detector fault on loop'), ('UPS systems', 4, 'UPS battery alarm')
on conflict do nothing;
insert into cip_ingest.new_tender values
  ('Façade cleaning & rope access services', 'Soft services', 0.9), ('BMS head-end modernisation', 'Special systems', 2.4),
  ('Pest control & hygiene services', 'Soft services', 0.4), ('Generator load-bank & overhaul', 'Electrical', 0.7)
on conflict do nothing;

-- Equilibrium targets are taken from the data as it stands, so the estate
-- "breathes" around its seeded levels instead of drifting.
create or replace function cip_ingest.sim_reset() returns void
language plpgsql set search_path = '' as $$
begin
  delete from cip_ingest.sim_target;
  insert into cip_ingest.sim_target
  select e.estate_code, e.client_code,
         (select count(*) from cip_silver.work_order w where w.estate_code = e.estate_code and w.status in ('Open','InProgress','OnHold')),
         (select count(*) from cip_silver.work_order w where w.estate_code = e.estate_code and w.status in ('Open','InProgress','OnHold') and w.priority <= 2),
         coalesce((select avg(extract(epoch from (w.responded_at - w.created_at)) / 60)
                     from cip_silver.work_order w
                    where w.estate_code = e.estate_code and w.wo_type = 'Reactive' and w.status = 'Completed'
                      and w.completed_at >= cip_core.utc_now() - interval '30 days'), 14),
         coalesce((select round(sum(planned_headcount) * 0.985) from cip_silver.roster_plan r where r.estate_code = e.estate_code), 0),
         coalesce((select sum(planned_headcount) from cip_silver.roster_plan r where r.estate_code = e.estate_code), 0) + 20
  from cip_core.estate e;

  delete from cip_ingest.sim_env;
  insert into cip_ingest.sim_env
  select r.estate_code, r.metric, max(r.zone), avg(r.value), avg(r.value), max(r.sensor_count)
  from cip_silver.sensor_reading r
  where r.read_at >= (select max(read_at) from cip_silver.sensor_reading) - interval '30 minutes'
  group by r.estate_code, r.metric;

  insert into cip_ingest.sim_state (id) values (1) on conflict (id) do nothing;
  update cip_ingest.sim_state
     set scripted = case when exists (select 1 from cip_silver.tender where tender_ref = 'T-0147' and gates_passed = 5)
                         then 'T-0147' end;
end $$;

create or replace function cip_ingest.sim_pick_estate() returns cip_ingest.sim_target
language sql volatile set search_path = '' as $$
  -- weighted random pick (exponential race)
  select * from cip_ingest.sim_target order by -ln(1 - random()) / weight limit 1
$$;

create or replace function cip_ingest.sim_mri(p_now timestamp) returns void
language plpgsql set search_path = '' as $$
declare
  t cip_ingest.sim_target; open_n int; p12 int; has_hi boolean; has_lo boolean; pref text;
  w record; late boolean; resp numeric; f record; zone text; pr int; u double precision; ref text;
begin
  t := cip_ingest.sim_pick_estate();
  select count(*), count(*) filter (where priority <= 2) into open_n, p12
    from cip_silver.work_order where estate_code = t.estate_code and status in ('Open', 'InProgress', 'OnHold');
  select bool_or(priority <= 2), bool_or(priority > 2) into has_hi, has_lo
    from cip_silver.work_order
   where estate_code = t.estate_code and wo_type = 'Reactive' and status in ('Open', 'InProgress')
     and created_at >= p_now - interval '72 hours';

  if coalesce(has_hi or has_lo, false) and (open_n > t.open_target or (open_n = t.open_target and random() < 0.5)) then
    pref := case when p12 > t.p1p2_target and has_hi then 'hi' when p12 < t.p1p2_target and has_lo then 'lo' else 'any' end;
    select * into w from cip_silver.work_order
     where estate_code = t.estate_code and wo_type = 'Reactive' and status in ('Open', 'InProgress')
       and created_at >= p_now - interval '72 hours'
       and (pref = 'any' or (pref = 'hi' and priority <= 2) or (pref = 'lo' and priority > 2))
     order by random() limit 1;
    late := random() < 0.015;
    resp := case when late then cip_ingest.sla_minutes(w.priority) + 12
                 else least(cip_ingest.sla_minutes(w.priority) - 1, t.resp_min * (0.5 + random())) end;
    perform cip_ingest.mri_workorder_upsert(w.source_ref, t.estate_code, 'Reactive', w.priority, 'Completed', null, null,
      w.created_at, null, w.respond_by,
      coalesce(w.responded_at, least(p_now, w.created_at + make_interval(secs => resp * 60))), p_now);
  else
    select * into f from cip_ingest.fault order by -ln(1 - random()) / weight limit 1;
    zone := (array['Main Residence', 'Majlis & Reception', 'Guest Villas', 'Service & BOH', 'Energy Centre',
                   'Landscape & Water Features', 'Mobility & Fleet'])[1 + floor(random() * 7)::int];
    u := random();
    pr := case when u < 0.05 then 1 when u < 0.20 then 2 when u < 0.70 then 3 else 4 end;
    if p12 < t.p1p2_target and random() < 0.6 then pr := case when random() < 0.3 then 1 else 2 end; end if;
    if p12 > t.p1p2_target and pr <= 2 then pr := 3; end if;
    update cip_ingest.sim_state set seq = seq + 1 where id = 1 returning 'WO-' || lpad(seq::text, 6, '0') into ref;
    perform cip_ingest.mri_workorder_upsert(ref, t.estate_code, 'Reactive', pr, 'Open', f.asset_class,
      zone || ' · ' || f.fault_text, p_now, null, p_now + make_interval(mins => cip_ingest.sla_minutes(pr)), null, null);
  end if;
end $$;

create or replace function cip_ingest.sim_iot(p_now timestamp) returns void
language plpgsql set search_path = '' as $$
declare batch jsonb;
begin
  update cip_ingest.sim_env
     set current = base + 0.6 * (current - base) + (random() * 2 - 1) * case when metric = 'temp_c' then 0.15 else 0.5 end;
  select jsonb_agg(jsonb_build_object('estate_code', estate_code, 'zone', zone, 'metric', metric,
                                      'value', round(current, 2), 'sensor_count', sensor_count, 'read_at', p_now))
    into batch from cip_ingest.sim_env;
  if batch is not null then perform cip_ingest.iot_reading_batch(batch); end if;
end $$;

create or replace function cip_ingest.sim_ta(p_now timestamp) returns void
language plpgsql set search_path = '' as $$
declare t cip_ingest.sim_target; on_n int; n int := 1 + floor(random() * 3)::int; ev jsonb;
begin
  t := cip_ingest.sim_pick_estate();
  select count(*) into on_n from cip_silver.clock_event
   where estate_code = t.estate_code and clock_out_at is null and clock_in_at >= p_now - interval '16 hours';
  if on_n < t.staff_target or (on_n = t.staff_target and random() < 0.5) then
    select jsonb_agg(jsonb_build_object(
             'staff_ref', 'S' || substr(t.estate_code, 3) || '-' || (5000 + floor(random() * 4999)::int),
             'estate_code', t.estate_code,
             'category', case when r < 0.58 then 'Technical' when r < 0.85 then 'Soft services' when r < 0.96 then 'Professional' else 'Admin' end,
             'direction', 'IN', 'at_utc', p_now))
      into ev from (select random() as r from generate_series(1, n)) s;
  else
    select jsonb_agg(jsonb_build_object('staff_ref', staff_ref, 'estate_code', estate_code, 'category', category,
                                        'direction', 'OUT', 'at_utc', p_now))
      into ev from (select staff_ref, estate_code, category from cip_silver.clock_event
                     where estate_code = t.estate_code and clock_out_at is null order by clock_in_at limit n) s;
  end if;
  if ev is not null then perform cip_ingest.ta_clock_batch(ev); end if;
end $$;

create or replace function cip_ingest.sim_tender(p_now timestamp, p_ref text default null) returns void
language plpgsql set search_path = '' as $$
declare t record; g int; nt record; e record; new_ref text;
begin
  if p_ref is not null then
    select * into t from cip_silver.tender where tender_ref = p_ref and status <> 'Completed';
  else
    select * into t from cip_silver.tender where status not in ('Completed', 'Overdue') order by random() limit 1;
  end if;
  if not found then return; end if;
  g := t.gates_passed + 1;
  perform cip_ingest.d365_tender_gate_passed(t.tender_ref, g, p_now,
    case when t.status = 'At Risk' and random() < 0.5 then 'At Risk' else 'On Track' end);
  if g = 13 then
    select * into nt from cip_ingest.new_tender order by random() limit 1;
    select * into e from cip_core.estate where client_code = t.client_code order by random() limit 1;
    new_ref := 'T-0' || (300 + floor(random() * 600)::int);
    if not exists (select 1 from cip_silver.tender where tender_ref = new_ref) then
      perform cip_ingest.d365_tender_register(new_ref, e.estate_code, t.client_code, nt.scope, nt.category,
                                              3 + floor(random() * 3)::int, nt.value_m * 1000000, p_now);
    end if;
  end if;
end $$;

create or replace function cip_ingest.sim_heartbeat() returns void
language plpgsql set search_path = '' as $$
declare src text := case when random() < 0.5 then 'D365 F&O' else 'D365 Projects' end; c record;
begin
  for c in select client_code from cip_core.client loop
    perform cip_ingest.log_sync(src, c.client_code,
      case when src = 'D365 F&O' then 'Ledger sync · no new postings' else 'Projects sync · stages reconciled' end);
  end loop;
end $$;

-- One simulator step: telemetry every 6th step, otherwise one source event.
create or replace function cip_ingest.sim_step() returns void
language plpgsql set search_path = '' as $$
declare st cip_ingest.sim_state; now_ts timestamp := cip_core.utc_now(); r double precision;
begin
  update cip_ingest.sim_state set tick = tick + 1 where id = 1 returning * into st;
  if st.tick % 6 = 1 then perform cip_ingest.sim_iot(now_ts); end if;
  if st.tick % 40 = 0 then perform cip_ingest.housekeeping(); end if;
  if st.scripted is not null and st.tick >= 2 then
    update cip_ingest.sim_state set scripted = null where id = 1;
    perform cip_ingest.sim_tender(now_ts, st.scripted);
    return;
  end if;
  r := random();
  if    r < 0.70  then perform cip_ingest.sim_mri(now_ts);
  elsif r < 0.96  then perform cip_ingest.sim_ta(now_ts);
  elsif r < 0.966 then perform cip_ingest.sim_tender(now_ts);
  elsif r < 0.976 then perform cip_ingest.sim_heartbeat();
  end if;
end $$;

-- pg_cron entry point: two steps every 5 seconds (~1 event every 2.5 s)
create or replace function cip_ingest.simulate_tick() returns void
language plpgsql set search_path = '' as $$
begin
  perform cip_ingest.sim_step();
  perform cip_ingest.sim_step();
end $$;

-- nothing in cip_ingest is callable by API roles
revoke all on all functions in schema cip_ingest from public, anon, authenticated;
revoke all on all tables in schema cip_ingest from public, anon, authenticated;


-- >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>> 006_seed.sql
-- =============================================================================
-- CIP POC on Supabase · 006 seed (GENERATED by tools/generate_pg_seed.py)
-- Reference data is explicit; record-level rows are generated in-database from
-- per-estate calibration parameters. Event times are relative to load time.
-- =============================================================================

insert into cip_core.client (client_code, portfolio_label) values
  ('CL01', 'Private estates portfolio · 10 assets'),
  ('CL02', 'Private estates portfolio · 3 assets')
on conflict do nothing;

insert into cip_core.estate (estate_code, client_code, emirate, region, tier, status_label, class_label, map_x, map_y, label_pos, managed_since) values
  ('SP11021', 'CL01', 'Abu Dhabi', 'Abu Dhabi', 1, 'Active', 'Icon', 395.0, 244.4, 'l', 2025),
  ('SP11047', 'CL01', 'Abu Dhabi', 'Abu Dhabi', 1, 'Active', 'Icon', 418.7, 252.3, 'br', 2025),
  ('SP11102', 'CL01', 'Abu Dhabi', 'Abu Dhabi', 2, 'Dormant', 'Residential', 308.5, 286.1, 'bl', 2025),
  ('SP11136', 'CL01', 'Abu Dhabi', 'Abu Dhabi', 2, 'Active', 'Residential', 551.5, 272.6, 'bl', 2025),
  ('SP11158', 'CL01', 'Abu Dhabi', 'Abu Dhabi', 2, 'Dormant', 'Residential', 409.3, 289.5, 'b', 2025),
  ('SP11203', 'CL01', 'Abu Dhabi', 'Abu Dhabi', 3, 'Dormant', 'Residential', 320.4, 396.7, 'r', 2025),
  ('SP11247', 'CL01', 'Abu Dhabi', 'Abu Dhabi', 3, 'Active', 'Residential', 435.3, 229.7, 'tr', 2025),
  ('SP21014', 'CL01', 'Dubai', 'Northern Emirates', 2, 'Active', 'Icon', 501.7, 165.4, 'r', 2025),
  ('SP31009', 'CL01', 'Ras Al Khaimah', 'Northern Emirates', 3, 'Dormant', 'Residential', 578.7, 101.1, 'l', 2025),
  ('SP41012', 'CL01', 'Fujairah', 'Northern Emirates', 3, 'Dormant', 'Residential', 622.6, 171.0, 'b', 2025),
  ('SP51003', 'CL02', 'Abu Dhabi', 'Abu Dhabi', 2, 'Active', 'Residential', 536.0, 318.0, 'r', 2025),
  ('SP51017', 'CL02', 'Dubai', 'Northern Emirates', 3, 'Active', 'Residential', 486.0, 183.0, 'l', 2025),
  ('SP51029', 'CL02', 'Sharjah', 'Northern Emirates', 3, 'Dormant', 'Residential', 521.0, 146.0, 'tr', 2025)
on conflict do nothing;

insert into cip_core.index_weight (component, weight, note) values
  ('environmental', 0.4, 'IAQ, water quality, humidity, fire integrity (pending SME sign-off, M011)'),
  ('ppm_compliance', 0.3, 'Rolling 90-day PPM completion'),
  ('critical_wo', 0.2, 'Open P1/P2 per 1,000 tagged assets'),
  ('asset_condition', 0.1, 'Validated condition index')
on conflict do nothing;

insert into cip_core.procurement_gate (gate_no, gate_name) values
  (1, 'Scope of Work'),
  (2, 'Bidders Identified'),
  (3, 'Client Pre-Approval'),
  (4, 'Tender Launched'),
  (5, 'Site Visits'),
  (6, 'Technical Evaluation'),
  (7, 'Commercial Evaluation'),
  (8, 'Internal Approval'),
  (9, 'Client Approval'),
  (10, 'Award Recommendation'),
  (11, 'Letter of Award'),
  (12, 'Contract Finalised'),
  (13, 'Go-Live / Stabilised')
on conflict do nothing;

insert into cip_core.work_stage (item_type, stage_no, stage_name) values
  ('Project', 1, 'Scope Defined'),
  ('Project', 2, 'Scope Approved by Client'),
  ('Project', 3, 'Commercial Proposal Submitted'),
  ('Project', 4, 'Commercial Approved by Client'),
  ('Project', 5, 'Mobilisation'),
  ('Project', 6, 'Works in Progress'),
  ('Project', 7, 'QA & Snagging'),
  ('Project', 8, 'Completed'),
  ('On-Demand', 1, 'Reported'),
  ('On-Demand', 2, 'Assigned'),
  ('On-Demand', 3, 'In Progress'),
  ('On-Demand', 4, 'Completed')
on conflict do nothing;

create table if not exists cip_ingest.seed_param (
  estate_code varchar(10) primary key, client_code varchar(8), n_done int, n_overdue int, backlog int, n_p1p2 int,
  n_or int, n_fp int, n_rc int, misses int, resp numeric, mttr numeric, staff int, assets int, cond numeric,
  health int, opex numeric, var numeric, capex numeric, draw numeric, iaq numeric, water numeric, humid numeric,
  fire numeric, temp numeric);
insert into cip_ingest.seed_param values
  ('SP11021', 'CL01', 454, 7, 5, 7, 29, 28, 86, 1, 11, 3.6, 512, 14820, 78, 94, 56.0, 1.2, 22.0, 0.52, 96, 98, 93, 99, 22.4),
  ('SP11047', 'CL01', 384, 8, 6, 10, 26, 23, 78, 0, 12, 3.9, 436, 12140, 77, 92, 47.5, -0.8, 18.5, 0.47, 95, 97, 91, 99, 22.6),
  ('SP11102', 'CL01', 212, 6, 4, 8, 17, 15, 53, 0, 14, 4.4, 242, 7420, 75, 90, 26.5, 2.1, 9.5, 0.55, 93, 96, 90, 98, 22.9),
  ('SP11136', 'CL01', 168, 10, 11, 15, 21, 16, 58, 1, 17, 5.8, 198, 6380, 64, 81, 22.0, 7.3, 8.0, 0.61, 88, 95, 78.6, 97, 23.6),
  ('SP11158', 'CL01', 154, 4, 3, 6, 13, 12, 35, 0, 13, 4.1, 176, 5910, 76, 91, 19.5, -1.4, 7.0, 0.49, 94, 97, 92, 99, 22.5),
  ('SP11203', 'CL01', 83, 3, 2, 4, 8, 7, 21, 0, 15, 4.8, 96, 3240, 74, 89, 11.0, 0.6, 3.8, 0.5, 92, 96, 88, 98, 23.1),
  ('SP11247', 'CL01', 77, 2, 1, 2, 6, 6, 17, 0, 12, 3.8, 88, 2980, 79, 93, 9.8, -2.2, 3.2, 0.44, 95, 98, 92, 99, 22.3),
  ('SP21014', 'CL01', 188, 5, 4, 8, 15, 13, 43, 0, 13, 4.3, 214, 6890, 75, 90, 24.5, 1.8, 9.0, 0.53, 93, 97, 90, 98, 22.8),
  ('SP31009', 'CL01', 63, 2, 3, 4, 7, 7, 17, 0, 16, 5.1, 72, 2410, 73, 87, 8.2, 0.9, 2.8, 0.46, 91, 95, 86, 98, 23.0),
  ('SP41012', 'CL01', 68, 2, 2, 4, 7, 6, 17, 0, 15, 4.6, 78, 2650, 75, 88, 8.8, -0.5, 3.0, 0.48, 92, 96, 85, 99, 23.2),
  ('SP51003', 'CL02', 142, 6, 4, 10, 14, 11, 42, 1, 15, 4.9, 164, 5120, 70, 84, 17.2, 2.6, 6.0, 0.41, 91, 95, 78.2, 98, 23.4),
  ('SP51017', 'CL02', 72, 2, 2, 2, 8, 7, 16, 0, 13, 4.4, 82, 2760, 76, 91, 9.1, -1.1, 3.1, 0.52, 93, 96, 90, 99, 22.7),
  ('SP51029', 'CL02', 61, 2, 2, 4, 7, 6, 15, 0, 14, 4.7, 70, 2200, 72, 87, 7.4, 5.6, 2.6, 0.37, 92, 95, 88, 98, 22.9)
on conflict do nothing;

create table if not exists cip_ingest.seed_dim (cost_dimension varchar(16) primary key, share numeric, g numeric);
insert into cip_ingest.seed_dim values
  ('Manpower', 0.5507246377, 1.003565365),
  ('Materials', 0.1202898551, 1.0369218811),
  ('Subcontracts', 0.1797101449, 1.0411030177),
  ('Utilities', 0.1101449275, 0.9501980758),
  ('Overheads', 0.0391304348, 0.7877339705)
on conflict do nothing;
create table if not exists cip_ingest.seed_month (client_code varchar(8), m int, month_plan_aed numeric, k numeric, total_opex_m numeric, primary key (client_code, m));
insert into cip_ingest.seed_month values
  ('CL01', 1, 19000000.0, 0.97378668, 233.8),
  ('CL01', 2, 18400000.0, 1.01629504, 233.8),
  ('CL01', 3, 19600000.0, 0.97931291, 233.8),
  ('CL01', 4, 19200000.0, 1.02032795, 233.8),
  ('CL01', 5, 19800000.0, 1.00439997, 233.8),
  ('CL01', 6, 20600000.0, 1.00381779, 233.8),
  ('CL01', 7, 21400000.0, 1.00327914, 233.8),
  ('CL01', 8, 21800000.0, 1.0, 233.8),
  ('CL01', 9, 20200000.0, 1.0, 233.8),
  ('CL01', 10, 19600000.0, 1.0, 233.8),
  ('CL01', 11, 19400000.0, 1.0, 233.8),
  ('CL01', 12, 19800000.0, 1.0, 233.8),
  ('CL02', 1, 2681323.28, 1.0, 33.7),
  ('CL02', 2, 2596649.92, 1.0, 33.7),
  ('CL02', 3, 2765996.65, 1.0, 33.7),
  ('CL02', 4, 2709547.74, 1.0, 33.7),
  ('CL02', 5, 2794221.11, 1.0, 33.7),
  ('CL02', 6, 2907118.93, 1.0, 33.7),
  ('CL02', 7, 3020016.75, 1.0, 33.7),
  ('CL02', 8, 3076465.66, 1.0, 33.7),
  ('CL02', 9, 2850670.02, 1.0, 33.7),
  ('CL02', 10, 2765996.65, 1.0, 33.7),
  ('CL02', 11, 2737772.19, 1.0, 33.7),
  ('CL02', 12, 2794221.11, 1.0, 33.7)
on conflict do nothing;



create or replace function cip_ingest.tri(u double precision, lo double precision, hi double precision, mode double precision)
returns double precision language sql immutable set search_path = '' as $$
  select case when u < (mode - lo) / (hi - lo) then lo + sqrt(u * (hi - lo) * (mode - lo))
              else hi - sqrt((1 - u) * (hi - lo) * (hi - mode)) end
$$;

create sequence if not exists cip_ingest.seed_wo_seq;
create or replace view cip_ingest.fault_cdf as
  select asset_class, fault_text,
         (sum(weight) over (order by asset_class) - weight)::float8 / sum(weight) over () as lo,
         (sum(weight) over (order by asset_class))::float8 / sum(weight) over ()          as hi
  from cip_ingest.fault;

-- Rebuilds every silver table from the parameters. Run by this migration and
-- nightly by pg_cron (007) so the demo stays fresh and the database stays small.
create or replace function cip_ingest.seed_demo() returns void
language plpgsql set search_path = cip_ingest, cip_core, cip_silver, public as $seed$
declare
  e record;
  now0 timestamp := cip_core.utc_now();
  zones text[] := array['Main Residence', 'Majlis & Reception', 'Guest Villas', 'Service & BOH', 'Energy Centre',
                        'Landscape & Water Features', 'Mobility & Fleet'];
  backlog_left int;
  fy int := 2026;
  last_closed int := 9;
begin
  truncate cip_silver.tender_gate_event, cip_silver.tender, cip_silver.work_order, cip_silver.sensor_reading,
           cip_silver.sensor_window, cip_silver.clock_event, cip_silver.roster_plan, cip_silver.gl_actual,
           cip_silver.budget, cip_silver.capex_programme, cip_silver.asset_condition, cip_silver.work_item,
           cip_silver.exception_action, cip_silver.ingest_log restart identity;
  perform setseed(0.20261012);
  perform setval('cip_ingest.seed_wo_seq', 4000);
  insert into cip_silver.tender (tender_ref, client_code, estate_code, scope, category, bidders, gates_passed, status, est_value_aed, baseline_var_pct, scoped_at, awarded_at, go_live_at) values
    ('T-0131', 'CL01', 'SP11021', 'Specialist landscape & irrigation services', 'Landscaping', 5, 11, 'On Track', 4400000, 4.0, cip_core.utc_now() - make_interval(secs => 12742279), cip_core.utc_now() - make_interval(secs => 279223), null),
    ('T-0138', 'CL01', 'SP11047', 'Security systems integration (ELV)', 'Security', 4, 6, 'At Risk', 3200000, -3.0, cip_core.utc_now() - make_interval(secs => 7105005), null, null),
    ('T-0112', 'CL01', null, 'Lift maintenance AMC consolidation', 'Vertical transport', 3, 13, 'Completed', 2000000, 5.0, cip_core.utc_now() - make_interval(secs => 17366400), cip_core.utc_now() - make_interval(secs => 4133908), cip_core.utc_now() - make_interval(secs => 1728000)),
    ('T-0152', 'CL01', 'SP11136', 'Chiller plant replacement works', 'HVAC works', 6, 4, 'On Track', 1100000, 0.0, cip_core.utc_now() - make_interval(secs => 4675390), null, null),
    ('T-0141', 'CL01', 'SP11102', 'Fire & life safety systems upgrade', 'FLS', 5, 7, 'Overdue', 3600000, 8.0, cip_core.utc_now() - make_interval(secs => 8135076), null, null),
    ('T-0147', 'CL01', 'SP31009', 'Waste management services', 'Environmental', 4, 5, 'On Track', 800000, -2.0, cip_core.utc_now() - make_interval(secs => 5481780), null, null),
    ('T-0203', 'CL02', 'SP51003', 'MEP maintenance AMC renewal', 'Hard FM', 4, 8, 'On Track', 2600000, 1.0, cip_core.utc_now() - make_interval(secs => 9293462), null, null),
    ('T-0209', 'CL02', 'SP51017', 'Pool & water feature services', 'Water features', 3, 3, 'At Risk', 600000, -1.0, cip_core.utc_now() - make_interval(secs => 3523600), null, null);
  insert into cip_silver.tender_gate_event (tender_ref, gate_no, client_code, passed_at) values
    ('T-0131', 1, 'CL01', cip_core.utc_now() - make_interval(secs => 12310279)),
    ('T-0131', 2, 'CL01', cip_core.utc_now() - make_interval(secs => 11093323)),
    ('T-0131', 3, 'CL01', cip_core.utc_now() - make_interval(secs => 9900238)),
    ('T-0131', 4, 'CL01', cip_core.utc_now() - make_interval(secs => 8719175)),
    ('T-0131', 5, 'CL01', cip_core.utc_now() - make_interval(secs => 7476271)),
    ('T-0131', 6, 'CL01', cip_core.utc_now() - make_interval(secs => 6320775)),
    ('T-0131', 7, 'CL01', cip_core.utc_now() - make_interval(secs => 5044954)),
    ('T-0131', 8, 'CL01', cip_core.utc_now() - make_interval(secs => 3852164)),
    ('T-0131', 9, 'CL01', cip_core.utc_now() - make_interval(secs => 2638393)),
    ('T-0131', 10, 'CL01', cip_core.utc_now() - make_interval(secs => 1540020)),
    ('T-0131', 11, 'CL01', cip_core.utc_now() - make_interval(secs => 279223)),
    ('T-0138', 1, 'CL01', cip_core.utc_now() - make_interval(secs => 6673005)),
    ('T-0138', 2, 'CL01', cip_core.utc_now() - make_interval(secs => 5507488)),
    ('T-0138', 3, 'CL01', cip_core.utc_now() - make_interval(secs => 4181274)),
    ('T-0138', 4, 'CL01', cip_core.utc_now() - make_interval(secs => 2976746)),
    ('T-0138', 5, 'CL01', cip_core.utc_now() - make_interval(secs => 1786418)),
    ('T-0138', 6, 'CL01', cip_core.utc_now() - make_interval(secs => 538384)),
    ('T-0112', 1, 'CL01', cip_core.utc_now() - make_interval(secs => 16163446)),
    ('T-0112', 2, 'CL01', cip_core.utc_now() - make_interval(secs => 14960492)),
    ('T-0112', 3, 'CL01', cip_core.utc_now() - make_interval(secs => 13757538)),
    ('T-0112', 4, 'CL01', cip_core.utc_now() - make_interval(secs => 12554585)),
    ('T-0112', 5, 'CL01', cip_core.utc_now() - make_interval(secs => 11351631)),
    ('T-0112', 6, 'CL01', cip_core.utc_now() - make_interval(secs => 10148677)),
    ('T-0112', 7, 'CL01', cip_core.utc_now() - make_interval(secs => 8945723)),
    ('T-0112', 8, 'CL01', cip_core.utc_now() - make_interval(secs => 7742769)),
    ('T-0112', 9, 'CL01', cip_core.utc_now() - make_interval(secs => 6539815)),
    ('T-0112', 10, 'CL01', cip_core.utc_now() - make_interval(secs => 5336862)),
    ('T-0112', 11, 'CL01', cip_core.utc_now() - make_interval(secs => 4133908)),
    ('T-0112', 12, 'CL01', cip_core.utc_now() - make_interval(secs => 2930954)),
    ('T-0112', 13, 'CL01', cip_core.utc_now() - make_interval(secs => 1728000)),
    ('T-0152', 1, 'CL01', cip_core.utc_now() - make_interval(secs => 4243390)),
    ('T-0152', 2, 'CL01', cip_core.utc_now() - make_interval(secs => 2986659)),
    ('T-0152', 3, 'CL01', cip_core.utc_now() - make_interval(secs => 1783904)),
    ('T-0152', 4, 'CL01', cip_core.utc_now() - make_interval(secs => 672485)),
    ('T-0141', 1, 'CL01', cip_core.utc_now() - make_interval(secs => 7703076)),
    ('T-0141', 2, 'CL01', cip_core.utc_now() - make_interval(secs => 6566152)),
    ('T-0141', 3, 'CL01', cip_core.utc_now() - make_interval(secs => 5249932)),
    ('T-0141', 4, 'CL01', cip_core.utc_now() - make_interval(secs => 4066734)),
    ('T-0141', 5, 'CL01', cip_core.utc_now() - make_interval(secs => 2875020)),
    ('T-0141', 6, 'CL01', cip_core.utc_now() - make_interval(secs => 1622761)),
    ('T-0141', 7, 'CL01', cip_core.utc_now() - make_interval(secs => 466078)),
    ('T-0147', 1, 'CL01', cip_core.utc_now() - make_interval(secs => 5049780)),
    ('T-0147', 2, 'CL01', cip_core.utc_now() - make_interval(secs => 3877789)),
    ('T-0147', 3, 'CL01', cip_core.utc_now() - make_interval(secs => 2693582)),
    ('T-0147', 4, 'CL01', cip_core.utc_now() - make_interval(secs => 1512203)),
    ('T-0147', 5, 'CL01', cip_core.utc_now() - make_interval(secs => 238430)),
    ('T-0203', 1, 'CL02', cip_core.utc_now() - make_interval(secs => 8861462)),
    ('T-0203', 2, 'CL02', cip_core.utc_now() - make_interval(secs => 7685089)),
    ('T-0203', 3, 'CL02', cip_core.utc_now() - make_interval(secs => 6414152)),
    ('T-0203', 4, 'CL02', cip_core.utc_now() - make_interval(secs => 5226966)),
    ('T-0203', 5, 'CL02', cip_core.utc_now() - make_interval(secs => 3991768)),
    ('T-0203', 6, 'CL02', cip_core.utc_now() - make_interval(secs => 2746598)),
    ('T-0203', 7, 'CL02', cip_core.utc_now() - make_interval(secs => 1617394)),
    ('T-0203', 8, 'CL02', cip_core.utc_now() - make_interval(secs => 300333)),
    ('T-0209', 1, 'CL02', cip_core.utc_now() - make_interval(secs => 3091600)),
    ('T-0209', 2, 'CL02', cip_core.utc_now() - make_interval(secs => 1817744)),
    ('T-0209', 3, 'CL02', cip_core.utc_now() - make_interval(secs => 526931));
  insert into cip_silver.work_item (item_ref, client_code, estate_code, item_name, item_type, stages_done, status, value_aed, reported_at, completed_at) values
    ('PRJ-0201', 'CL01', 'SP11021', 'Majlis wing refurbishment', 'Project', 6, 'On Track', 680000, cip_core.utc_now() - make_interval(secs => 5529600), null),
    ('PRJ-0207', 'CL01', 'SP11047', 'Water feature renewal — principal courtyard', 'Project', 7, 'At Risk', 350000, cip_core.utc_now() - make_interval(secs => 6393600), null),
    ('PRJ-0188', 'CL01', 'SP11158', 'Roof waterproofing replacement', 'Project', 8, 'Completed', 1140000, cip_core.utc_now() - make_interval(secs => 10022400), cip_core.utc_now() - make_interval(secs => 1728000)),
    ('PRJ-0214', 'CL01', 'SP11136', 'Perimeter security enhancement', 'Project', 2, 'On Track', 240000, cip_core.utc_now() - make_interval(secs => 2678400), null),
    ('OD-1102', 'CL01', 'SP11021', 'EV charging bays', 'On-Demand', 4, 'Completed', 33000, cip_core.utc_now() - make_interval(secs => 2160000), cip_core.utc_now() - make_interval(secs => 777600)),
    ('OD-1109', 'CL01', 'SP11102', 'CCTV camera additions', 'On-Demand', 3, 'On Track', 15000, cip_core.utc_now() - make_interval(secs => 1900800), null),
    ('OD-1113', 'CL01', 'SP41012', 'Entrance signage upgrade', 'On-Demand', 2, 'Overdue', 11000, cip_core.utc_now() - make_interval(secs => 1555200), null),
    ('OD-1117', 'CL01', 'SP11047', 'Staff cycle store', 'On-Demand', 1, 'On Track', 26000, cip_core.utc_now() - make_interval(secs => 1209600), null),
    ('OD-1094', 'CL01', 'SP11203', 'External lighting upgrade', 'On-Demand', 4, 'Completed', 18000, cip_core.utc_now() - make_interval(secs => 2592000), cip_core.utc_now() - make_interval(secs => 950400)),
    ('PRJ-0302', 'CL02', 'SP51003', 'Guest villa MEP upgrade', 'Project', 5, 'On Track', 420000, cip_core.utc_now() - make_interval(secs => 4752000), null),
    ('OD-1201', 'CL02', 'SP51029', 'Gate barrier replacement', 'On-Demand', 2, 'On Track', 22000, cip_core.utc_now() - make_interval(secs => 1641600), null);
  insert into cip_silver.exception_action (exception_key, client_code, cause_note, action_text, owner_team) values
    ('OPEX:SP11136', 'CL01', 'unplanned chiller-bank replacement (AED 1.9m) brought forward from FY27', 'Recovery plan active from month 8 · variance closes to +3% by year end', 'Asset Finance'),
    ('ENV:SP11136:humidity', 'CL01', 'majlis wing dehumidification underperforming in peak season', 'Remediation in progress · desiccant units on site · ETA 3 weeks', 'Hard FM'),
    ('TENDER:T-0141', 'CL01', '12 days behind milestone', 'Escalated to procurement committee · revised award date within 3 weeks', 'Procurement'),
    ('OPEX:SP51029', 'CL02', 'gate automation and access-control spares above plan', 'Spares call-off renegotiated · variance reviewed monthly', 'Asset Finance');

  for e in select * from cip_ingest.seed_param order by estate_code loop
    -- completed PPM, due in the last 90 days
    insert into cip_silver.work_order (source_ref, client_code, estate_code, wo_type, priority, status, asset_class, summary,
                                       created_at, due_at, completed_at)
    select 'WO-' || lpad(nextval('cip_ingest.seed_wo_seq')::text, 6, '0'), e.client_code, e.estate_code, 'PPM', 3, 'Completed',
           fc.asset_class, zones[1 + floor(r.u2 * 7)::int] || ' · ' || fc.asset_class || ' planned maintenance (SFG20)',
           now0 - make_interval(secs => r.d + 7 * 86400), now0 - make_interval(secs => r.d),
           now0 - make_interval(secs => greatest(600, r.d + (r.u3 * 3 - 1) * 86400))
    from (select random() u1, random() u2, random() u3, 86400 + random() * 88 * 86400 d from generate_series(1, e.n_done)) r
    join cip_ingest.fault_cdf fc on r.u1 >= fc.lo and r.u1 < fc.hi;

    -- overdue PPM (open); the oldest count towards the 30-day backlog
    insert into cip_silver.work_order (source_ref, client_code, estate_code, wo_type, priority, status, asset_class, summary,
                                       created_at, due_at)
    select 'WO-' || lpad(nextval('cip_ingest.seed_wo_seq')::text, 6, '0'), e.client_code, e.estate_code, 'PPM', 3, 'Open',
           fc.asset_class, zones[1 + floor(r.u2 * 7)::int] || ' · ' || fc.asset_class || ' planned maintenance (SFG20)',
           now0 - make_interval(secs => r.d + 7 * 86400), now0 - make_interval(secs => r.d)
    from (select random() u1, random() u2,
                 case when gs <= least(e.backlog, e.n_overdue) then 25 + random() * 30 else 1 + random() * 19 end * 86400 d
            from generate_series(1, e.n_overdue) gs) r
    join cip_ingest.fault_cdf fc on r.u1 >= fc.lo and r.u1 < fc.hi;
    backlog_left := e.backlog - least(e.backlog, e.n_overdue);

    -- open reactive: P1/P2 first, backlog extras on hold, most raised today
    insert into cip_silver.work_order (source_ref, client_code, estate_code, wo_type, priority, status, asset_class, summary,
                                       created_at, respond_by, responded_at)
    select 'WO-' || lpad(nextval('cip_ingest.seed_wo_seq')::text, 6, '0'), e.client_code, e.estate_code, 'Reactive', c.pr, c.status,
           fc.asset_class, zones[1 + floor(c.u2 * 7)::int] || ' · ' || fc.fault_text,
           now0 - make_interval(secs => c.created_s),
           now0 - make_interval(secs => c.created_s - cip_ingest.sla_minutes(c.pr) * 60),
           case when c.status <> 'Open' then now0 - make_interval(secs => greatest(0, c.created_s - (240 + c.u5 * 1260))) end
    from (
      select b.*,
             case b.kind when 'backlog' then 31 * 86400 + b.u3 * 39 * 86400
                         when 'hold'    then 86400 + b.u3 * 25 * 86400
                         else 300 + b.u3 * (9 * 3600 - 300) end as created_s,
             case b.kind when 'fresh' then case when b.u4 < 0.5 then 'Open' else 'InProgress' end else 'OnHold' end as status
      from (
        select a.*,
               case when a.i < e.n_p1p2 then case when a.u6 < 1/3.0 then 1 else 2 end
                    else case when a.u6 < 2/3.0 then 3 else 4 end end as pr,
               case when a.i >= e.n_p1p2 and a.i - e.n_p1p2 < backlog_left then 'backlog'
                    when a.i >= e.n_p1p2 and a.u7 < 0.25 then 'hold'
                    else 'fresh' end as kind
        from (select gs - 1 as i, random() u1, random() u2, random() u3, random() u4, random() u5, random() u6, random() u7
                from generate_series(1, e.n_or) gs) a
      ) b
    ) c
    join cip_ingest.fault_cdf fc on c.u1 >= fc.lo and c.u1 < fc.hi;

    -- open future PPM
    insert into cip_silver.work_order (source_ref, client_code, estate_code, wo_type, priority, status, asset_class, summary,
                                       created_at, due_at)
    select 'WO-' || lpad(nextval('cip_ingest.seed_wo_seq')::text, 6, '0'), e.client_code, e.estate_code, 'PPM', 3, 'Open',
           fc.asset_class, zones[1 + floor(r.u2 * 7)::int] || ' · ' || fc.asset_class || ' planned maintenance (SFG20)',
           now0 - make_interval(secs => 3600 + r.u3 * (6 * 86400 - 3600)), now0 + make_interval(secs => 86400 + r.u4 * 13 * 86400)
    from (select random() u1, random() u2, random() u3, random() u4 from generate_series(1, e.n_fp)) r
    join cip_ingest.fault_cdf fc on r.u1 >= fc.lo and r.u1 < fc.hi;

    -- completed reactive over 90 days, response and repair times around the estate's levels
    insert into cip_silver.work_order (source_ref, client_code, estate_code, wo_type, priority, status, asset_class, summary,
                                       created_at, respond_by, responded_at, completed_at)
    select 'WO-' || lpad(nextval('cip_ingest.seed_wo_seq')::text, 6, '0'), e.client_code, e.estate_code, 'Reactive', x.pr, 'Completed',
           fc.asset_class, zones[1 + floor(x.u2 * 7)::int] || ' · ' || fc.fault_text,
           now0 - make_interval(secs => x.created_s),
           now0 - make_interval(secs => x.created_s - cip_ingest.sla_minutes(x.pr) * 60),
           now0 - make_interval(secs => x.created_s - x.resp_min * 60),
           now0 - make_interval(secs => greatest(60, x.created_s - x.repair_h * 3600))
    from (
      select y.*, greatest(y.resp_min / 60 + 0.4, e.mttr * cip_ingest.tri(y.u5, 0.35, 2.3, 0.8) / 1.15) as repair_h
      from (
        select z.*, least(cip_ingest.sla_minutes(z.pr) - 1, e.resp * cip_ingest.tri(z.u4, 0.45, 1.9, 0.8) / 1.05) as resp_min
        from (
          select random() u1, random() u2, 6 * 3600 + random() * (90 * 86400 - 6 * 3600) as created_s, random() u4, random() u5,
                 case when q < 0.05 then 1 when q < 0.20 then 2 when q < 0.70 then 3 else 4 end as pr
          from (select random() q from generate_series(1, e.n_rc)) s
        ) z
      ) y
    ) x
    join cip_ingest.fault_cdf fc on x.u1 >= fc.lo and x.u1 < fc.hi;

    -- deliberate SLA breaches (P1/P2, recent, old enough to have breached)
    update cip_silver.work_order w
       set responded_at = w.respond_by + interval '15 minutes',
           completed_at = greatest(w.completed_at, w.respond_by + interval '45 minutes')
     where w.source_ref in (
       select source_ref from cip_silver.work_order
        where estate_code = e.estate_code and wo_type = 'Reactive' and status = 'Completed' and priority <= 2
          and completed_at >= now0 - interval '28 days'
          and created_at < now0 - make_interval(mins => cip_ingest.sla_minutes(priority) + 180)
        order by source_ref limit e.misses);

    -- telemetry: three 5-minute windows per metric
    insert into cip_silver.sensor_reading (client_code, estate_code, zone, metric, value, sensor_count, read_at)
    select e.client_code, e.estate_code,
           case when m.metric = 'temp_c' then 'Majlis & Reception' else 'Estate' end, m.metric,
           round((m.base + (random() * 2 - 1) * case when m.metric = 'temp_c' then 0.2 else 0.3 end)::numeric, 2),
           greatest(1, round(e.assets * 0.045 * m.split)),
           now0 - make_interval(mins => o.mins)
    from (values ('iaq', e.iaq, 0.35), ('water_quality', e.water, 0.15), ('humidity', e.humid, 0.25),
                 ('fire_integrity', e.fire, 0.20), ('temp_c', e.temp, 0.05)) as m(metric, base, split)
    cross join (values (11), (6), (1)) as o(mins);

    -- people on site and roster
    insert into cip_silver.roster_plan (estate_code, category, client_code, planned_headcount)
    select e.estate_code, c.category, e.client_code, round(round(e.staff * c.share) / 0.985)
    from (values ('Technical', 0.58), ('Soft services', 0.27), ('Professional', 0.11), ('Admin', 0.04)) as c(category, share);

    insert into cip_silver.clock_event (staff_ref, client_code, estate_code, category, clock_in_at)
    select 'S' || substr(e.estate_code, 3) || '-' || lpad((row_number() over (order by c.ord, gs))::text, 4, '0'),
           e.client_code, e.estate_code, c.category,
           now0 - make_interval(secs => 1200 + random() * (7.5 * 3600 - 1200))
    from (values (1, 'Technical', 0.58), (2, 'Soft services', 0.27), (3, 'Professional', 0.11), (4, 'Admin', 0.04)) as c(ord, category, share)
    cross join lateral generate_series(1, round(e.staff * c.share)::int) gs;

    insert into cip_silver.asset_condition (estate_code, client_code, assets_tagged, condition_idx, good_fair_pct,
                                            critical_monitored, beyond_life, surveyed_at)
    values (e.estate_code, e.client_code, e.assets, e.cond, least(97, e.health + 3), round(e.assets * 0.06),
            round(e.assets * 0.031), now0 - make_interval(days => 30 + floor(random() * 90)::int));

    insert into cip_silver.capex_programme (estate_code, fy, client_code, budget_aed, drawn_aed)
    values (e.estate_code, fy, e.client_code, round(e.capex * 1e6), round(e.capex * e.draw * 1e6));
  end loop;

  -- finance: plan = month plan x estate weight x dimension share; actual applies the
  -- estate variance, the month factor (pins CL01 to the v3 series) and the dimension factor
  insert into cip_silver.budget (estate_code, period, cost_dimension, client_code, amount_aed)
  select p.estate_code, fy * 100 + s.m, d.cost_dimension, p.client_code,
         round(s.month_plan_aed * (p.opex / s.total_opex_m) * d.share)
  from cip_ingest.seed_param p
  join cip_ingest.seed_month s on s.client_code = p.client_code
  cross join cip_ingest.seed_dim d;

  insert into cip_silver.gl_actual (estate_code, period, cost_dimension, client_code, amount_aed)
  select p.estate_code, fy * 100 + s.m, d.cost_dimension, p.client_code,
         round(s.month_plan_aed * (p.opex / s.total_opex_m) * d.share * (1 + p.var / 100) * s.k * d.g)
  from cip_ingest.seed_param p
  join cip_ingest.seed_month s on s.client_code = p.client_code and s.m <= last_closed
  cross join cip_ingest.seed_dim d;

  -- ingest log so data health and the activity feed start populated
  insert into cip_silver.ingest_log (client_code, estate_code, source_system, event_type, entity_ref, detail, ingested_at)
  select w.client_code, w.estate_code, 'MRI CAFM', 'WO completed', w.source_ref, w.summary,
         (now() at time zone 'utc') - make_interval(mins => (2 + rn * 3)::int)
  from (select w.*, row_number() over (partition by w.client_code order by w.completed_at desc) rn
          from cip_silver.work_order w where w.wo_type = 'Reactive' and w.status = 'Completed') w
  where w.rn <= 4;
  insert into cip_silver.ingest_log (client_code, estate_code, source_system, event_type, entity_ref, detail, ingested_at)
  select c.client_code, null, x.src, x.typ, null, x.detail, (now() at time zone 'utc') - make_interval(mins => x.mins)
  from cip_core.client c
  cross join (values ('IoT / Event Hub', 'Telemetry window', 'Eventstream window · all estates', 1),
                     ('D365 HR + T&A', 'Shift movements', 'Day shift roll-call reconciled', 18),
                     ('D365 F&O', 'Scheduled sync', 'Daily ledger sync · 06:00 GST', 320),
                     ('D365 Projects', 'Scheduled sync', 'Daily projects sync', 380)) as x(src, typ, detail, mins);
  perform cip_ingest.refresh_sensor_window(null);
  update cip_ingest.sim_state set tick = 0, seq = 900000 where id = 1;
  perform cip_ingest.sim_reset();
end
$seed$;

select cip_ingest.seed_demo();


-- >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>> 007_schedule.sql
-- =============================================================================
-- CIP POC on Supabase · 007 schedules (pg_cron)
--   cip-simulator       two simulator steps every 5 seconds
--   cip-nightly-reseed  rebuild the demo data at 02:00 GST (22:00 UTC) so the
--                       relative-time seed stays fresh and the tables stay small
-- Stop the simulator:  select cron.unschedule('cip-simulator');
-- Pause it:            select cron.alter_job((select jobid from cron.job where jobname = 'cip-simulator'), active := false);
-- =============================================================================
create extension if not exists pg_cron with schema pg_catalog;
grant usage on schema cron to postgres;
grant all privileges on all tables in schema cron to postgres;

select cron.schedule('cip-simulator', '5 seconds', $$select cip_ingest.simulate_tick()$$);
select cron.schedule('cip-nightly-reseed', '0 22 * * *', $$select cip_ingest.seed_demo()$$);
select cron.schedule('cip-cron-history-cleanup', '15 * * * *',
  $$delete from cron.job_run_details where end_time < now() - interval '6 hours'$$);
