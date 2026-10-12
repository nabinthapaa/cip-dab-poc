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
