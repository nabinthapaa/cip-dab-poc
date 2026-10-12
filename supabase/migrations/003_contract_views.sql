-- =============================================================================
-- CIP POC on Supabase · 003 contract views (port of sql/30_contract_views.sql)
-- Same 16 views, same column names and order, in schema public so Supabase's
-- Data API (PostgREST) serves them at /rest/v1/vw_*. The Netlify gateway maps
-- them to /api/vw_* with the DAB-style {"value":[...]} envelope.
-- =============================================================================

create or replace view public.vw_estate with (security_invoker = true) as
select e.estate_code, e.client_code, e.emirate, e.region, e.tier,
       case e.tier when 1 then 'Flagship Estate' when 2 then 'Principal Residence' else 'Residential Estate' end as tier_name,
       e.status_label, e.class_label, e.map_x, e.map_y, e.label_pos, e.managed_since
from cip_core.estate e;

create or replace view public.vw_service_delivery with (security_invoker = true) as
select e.estate_code,
       coalesce(m.open_orders, 0) as open_orders,
       coalesce(m.open_p1p2, 0)   as open_p1p2,
       coalesce(m.backlog_30d, 0) as backlog_30d,
       round(100.0 * m.reactive_in_sla_30d / nullif(m.reactive_closed_30d, 0), 1) as sla_pct,
       round(m.avg_response_min, 1) as avg_response_min,
       round(m.mttr_hours, 1)       as mttr_hours,
       round(100.0 * m.ppm_done_90d / nullif(m.ppm_due_90d, 0), 1) as ppm_completion_pct,
       round(100.0 * m.ppm_12m / nullif(m.wo_12m, 0), 1)           as planned_pct,
       m.last_ingested_at,
       cip_core.utc_now() as as_of
from cip_core.estate e
left join (select * from cip_calc.wo_metrics where not is_client_total offset 0) m on m.estate_code = e.estate_code;

create or replace view public.vw_invisible_care with (security_invoker = true) as
select e.estate_code, env.iaq, env.water_quality, env.humidity, env.fire_integrity, env.env_score, env.avg_temp_c,
       coalesce(env.sensors_reporting, 0) as sensors_reporting,
       coalesce(env.env_alerts_open, 0)   as env_alerts_open,
       h.ppm_pct as ppm_score, h.crit_score as critical_wo_score, h.condition_idx as asset_condition_idx, h.health_idx,
       case when h.health_idx >= 90 then 'Nominal' when h.health_idx >= 80 then 'Watch'
            when h.health_idx is not null then 'Attention' end as health_band,
       env.last_read_at,
       (extract(epoch from (cip_core.utc_now() - env.last_read_at)) / 60)::int as freshness_min
from cip_core.estate e
left join (select * from cip_calc.env_estate offset 0) env on env.estate_code = e.estate_code
left join (select * from cip_calc.estate_health offset 0) h on h.estate_code = e.estate_code;

create or replace view public.vw_asset_mgmt with (security_invoker = true) as
select a.estate_code, a.assets_tagged as asset_count, a.condition_idx, a.good_fair_pct,
       a.critical_monitored, a.beyond_life as assets_beyond_life, a.surveyed_at
from cip_silver.asset_condition a;

create or replace view public.vw_finance with (security_invoker = true) as
select e.estate_code,
       pl.last_period / 100 as fy,
       pl.last_period       as last_closed_period,
       pl.opex_fy_plan_aed, pl.opex_ytd_plan_aed, ac.opex_ytd_actual_aed,
       round(100.0 * (ac.opex_ytd_actual_aed - pl.opex_ytd_plan_aed) / nullif(pl.opex_ytd_plan_aed, 0), 1) as opex_var_pct,
       round(ac.opex_ytd_actual_aed * 12.0 / nullif(pl.last_period % 100, 0)) as opex_annualised_aed,
       cx.budget_aed as capex_fy_aed, cx.drawn_aed as capex_drawn_aed,
       round(100.0 * cx.drawn_aed / nullif(cx.budget_aed, 0), 1) as capex_drawn_pct
from cip_core.estate e
left join cip_calc.finance_plan pl   on pl.estate_code = e.estate_code and not pl.is_client_total
left join cip_calc.finance_actual ac on ac.estate_code = e.estate_code and not ac.is_client_total
left join cip_silver.capex_programme cx on cx.estate_code = e.estate_code and cx.fy = pl.last_period / 100;

create or replace view public.vw_finance_monthly with (security_invoker = true) as
select b.client_code, b.period, b.opex_plan_aed, a.opex_actual_aed
from (select client_code, period, sum(amount_aed) as opex_plan_aed from cip_silver.budget group by client_code, period) b
join cip_calc.finance_period p on p.client_code = b.client_code and b.period / 100 = p.last_period / 100
left join (select client_code, period, sum(amount_aed) as opex_actual_aed from cip_silver.gl_actual group by client_code, period) a
  on a.client_code = b.client_code and a.period = b.period;

create or replace view public.vw_finance_dimension with (security_invoker = true) as
select pl.client_code, pl.cost_dimension, pl.ytd_plan_aed as opex_ytd_plan_aed, ac.ytd_actual_aed as opex_ytd_actual_aed,
       round(100.0 * (ac.ytd_actual_aed - pl.ytd_plan_aed) / nullif(pl.ytd_plan_aed, 0), 1) as var_pct
from (select b.client_code, b.cost_dimension, sum(b.amount_aed) as ytd_plan_aed
        from cip_silver.budget b
        join cip_calc.finance_period p on p.client_code = b.client_code
         and b.period / 100 = p.last_period / 100 and b.period <= p.last_period
       group by b.client_code, b.cost_dimension) pl
left join (select a.client_code, a.cost_dimension, sum(a.amount_aed) as ytd_actual_aed
             from cip_silver.gl_actual a
             join cip_calc.finance_period p on p.client_code = a.client_code
              and a.period / 100 = p.last_period / 100 and a.period <= p.last_period
            group by a.client_code, a.cost_dimension) ac
  on ac.client_code = pl.client_code and ac.cost_dimension = pl.cost_dimension;

create or replace view public.vw_hr with (security_invoker = true) as
select e.estate_code,
       coalesce(h.staff_on_site, 0) as staff_on_site, coalesce(h.technical, 0) as technical,
       coalesce(h.soft_services, 0) as soft_services, coalesce(h.professional, 0) as professional,
       coalesce(h.admin, 0) as admin, r.planned_headcount,
       round(100.0 * coalesce(h.staff_on_site, 0) / nullif(r.planned_headcount, 0), 1) as deployment_vs_plan_pct
from cip_core.estate e
left join cip_calc.hr_metrics h     on h.estate_code = e.estate_code and not h.is_client_total
left join cip_calc.roster_metrics r on r.estate_code = e.estate_code and not r.is_client_total;

create or replace view public.vw_procurement with (security_invoker = true) as
select c.client_code,
       count(t.tender_ref) filter (where t.status <> 'Completed') as active_tenders,
       count(t.tender_ref) filter (where t.status = 'Overdue')    as overdue_tenders,
       count(t.tender_ref) filter (where t.status = 'At Risk')    as at_risk_tenders,
       coalesce(sum(t.est_value_aed) filter (where t.status <> 'Completed'), 0) as pipeline_aed,
       count(t.tender_ref) filter (where t.status <> 'Completed') as gates_live,
       floor(avg(extract(epoch from (t.go_live_at - t.scoped_at)) / 86400) filter (where t.go_live_at is not null))::int as avg_cycle_days,
       coalesce(sum(t.est_value_aed) filter (where extract(year from t.awarded_at) = extract(year from cip_core.utc_now())), 0) as awarded_ytd_aed
from cip_core.client c
left join cip_silver.tender t on t.client_code = c.client_code
group by c.client_code;

create or replace view public.vw_tender with (security_invoker = true) as
select t.tender_ref, coalesce(t.estate_code, 'Portfolio') as estate_code, t.scope, t.category, t.bidders, t.gates_passed,
       coalesce(g_last.gate_name, 'Not started')          as last_milestone,
       coalesce(g_next.gate_name, 'Go-Live / Stabilised') as next_milestone,
       t.status, t.est_value_aed, t.baseline_var_pct, t.scoped_at, ev.last_passed_at
from cip_silver.tender t
left join cip_core.procurement_gate g_last on g_last.gate_no = t.gates_passed
left join cip_core.procurement_gate g_next on g_next.gate_no = t.gates_passed + 1
left join lateral (select max(e.passed_at) as last_passed_at from cip_silver.tender_gate_event e where e.tender_ref = t.tender_ref) ev on true;

create or replace view public.vw_tender_gate with (security_invoker = true) as
select e.tender_ref, e.gate_no, g.gate_name, e.passed_at
from cip_silver.tender_gate_event e
join cip_core.procurement_gate g on g.gate_no = e.gate_no;

create or replace view public.vw_works with (security_invoker = true) as
select w.item_ref, w.item_name, w.item_type, w.estate_code, w.stages_done, st.stage_total,
       case when w.stages_done >= st.stage_total then 'Completed' else coalesce(s.stage_name, '—') end as current_stage,
       w.status, w.value_aed, w.reported_at, w.completed_at,
       case when w.completed_at is not null then round(extract(epoch from (w.completed_at - w.reported_at)) / 86400)::int end as resolution_days
from cip_silver.work_item w
cross join lateral (select count(*)::int as stage_total from cip_core.work_stage ws where ws.item_type = w.item_type) st
left join cip_core.work_stage s on s.item_type = w.item_type and s.stage_no = w.stages_done;

-- Exceptions computed from thresholds; people only add the action.
create or replace view public.vw_exceptions with (security_invoker = true) as
select x.exception_key, x.estate_code, x.domain, x.severity,
       x.detected || coalesce(' — ' || a.cause_note, '') as cause,
       coalesce(a.action_text, 'No action logged — assign an owner') as action_text,
       coalesce(a.owner_team, 'Unassigned') as owner_team,
       a.updated_at as action_updated_at
from (
  select ('OPEX:' || f.estate_code)::varchar(48) as exception_key, f.estate_code, 'Finance'::text as domain,
         case when f.opex_var_pct >= 10 then 'critical' else 'warning' end as severity,
         'OPEX +' || f.opex_var_pct::text || '% vs plan YTD' as detected
  from public.vw_finance f where f.opex_var_pct >= 5
  union all
  select ('ENV:' || l.estate_code || ':' || l.metric)::varchar(48), l.estate_code, 'Invisible Care', 'warning',
         case l.metric when 'iaq' then 'Indoor air quality' when 'water_quality' then 'Water quality'
                       when 'humidity' then 'Humidity' else 'Fire systems integrity' end
         || ' index ' || round(l.value)::int::text || '/100'
  from cip_calc.env_latest l where l.metric <> 'temp_c' and l.value < 80
  union all
  select ('TENDER:' || t.tender_ref)::varchar(48), coalesce(t.estate_code, 'Portfolio'), 'Procurement', 'critical',
         t.scope || ' tender overdue at ' || lower(coalesce(g.gate_name, 'scoping'))
  from cip_silver.tender t
  left join cip_core.procurement_gate g on g.gate_no = t.gates_passed
  where t.status = 'Overdue'
) x
left join cip_silver.exception_action a on a.exception_key = x.exception_key;

create or replace view public.vw_activity with (security_invoker = true) as
select l.event_id, l.source_system, l.event_type, l.estate_code, l.entity_ref, l.detail,
       l.ingested_at::timestamp(0) as ingested_at
from cip_silver.ingest_log l;

create or replace view public.vw_data_health with (security_invoker = true) as
select (c.client_code || ':' || s.source_system)::varchar(40) as health_key, s.source_system, s.feed, s.expected_cadence_min,
       lg.last_ingested_at, coalesce(lg.events_1h, 0) as events_1h,
       (extract(epoch from (cip_core.utc_now() - lg.last_ingested_at)) / 60)::int as freshness_min,
       case when s.expected_cadence_min is null then 'No digital source'
            when lg.last_ingested_at is null then 'No data'
            when extract(epoch from (cip_core.utc_now() - lg.last_ingested_at)) / 60 <= s.expected_cadence_min then 'Fresh'
            when extract(epoch from (cip_core.utc_now() - lg.last_ingested_at)) / 60 <= 3 * s.expected_cadence_min then 'Late'
            else 'Stale' end as status
from cip_core.client c
cross join (values
  ('MRI CAFM',         'Pipeline · near-live',          15),
  ('IoT / Event Hub',  'Eventstream · streaming',        5),
  ('D365 HR + T&A',    'Pipeline · near-live',          60),
  ('D365 F&O',         'Pipeline · daily',            1440),
  ('D365 Projects',    'Pipeline · daily',            1440),
  ('Utility invoices', 'Manual keying (M080/M081 gap)', null)
) as s (source_system, feed, expected_cadence_min)
left join lateral (
  select max(l.ingested_at)::timestamp(0) as last_ingested_at,
         count(*) filter (where l.ingested_at >= cip_core.utc_now() - interval '1 hour') as events_1h
  from cip_silver.ingest_log l
  where l.client_code = c.client_code and l.source_system = s.source_system
) lg on true;

create or replace view public.vw_portfolio_kpi with (security_invoker = true) as
select c.client_code, est.estates,
       coalesce(wo.open_orders, 0) as open_orders, coalesce(wo.open_p1p2, 0) as open_p1p2, coalesce(wo.backlog_30d, 0) as backlog_30d,
       round(100.0 * wo.reactive_in_sla_30d / nullif(wo.reactive_closed_30d, 0), 1) as sla_pct,
       round(100.0 * wo.ppm_done_90d / nullif(wo.ppm_due_90d, 0), 1) as ppm_completion_pct,
       round(100.0 * wo.ppm_12m / nullif(wo.wo_12m, 0), 1) as planned_pct,
       coalesce(hr.staff_on_site, 0) as staff_on_site, ro.planned_headcount, hl.health_idx,
       pl.last_period as last_closed_period, pl.opex_fy_plan_aed, pl.opex_ytd_plan_aed, ac.opex_ytd_actual_aed,
       round(100.0 * (ac.opex_ytd_actual_aed - pl.opex_ytd_plan_aed) / nullif(pl.opex_ytd_plan_aed, 0), 1) as opex_var_pct,
       round(ac.opex_ytd_actual_aed * 12.0 / nullif(pl.last_period % 100, 0)) as opex_annualised_aed,
       cip_core.utc_now() as as_of
from cip_core.client c
left join lateral (select count(*)::int as estates from cip_core.estate e where e.client_code = c.client_code) est on true
left join cip_calc.wo_metrics wo     on wo.client_code = c.client_code and wo.is_client_total
left join cip_calc.hr_metrics hr     on hr.client_code = c.client_code and hr.is_client_total
left join cip_calc.roster_metrics ro on ro.client_code = c.client_code and ro.is_client_total
left join cip_calc.finance_plan pl   on pl.client_code = c.client_code and pl.is_client_total
left join cip_calc.finance_actual ac on ac.client_code = c.client_code and ac.is_client_total
left join (select client_code, round(avg(health_idx))::int as health_idx from cip_calc.estate_health group by client_code) hl
  on hl.client_code = c.client_code;
