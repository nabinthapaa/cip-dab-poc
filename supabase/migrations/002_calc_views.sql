-- =============================================================================
-- CIP POC on Supabase · 002 calculation views (port of sql/20_calc_views.sql)
-- security_invoker: row-level security is evaluated as the caller, so every
-- view on top of these is filtered to the caller's client.
-- =============================================================================

-- M001 open_orders · M002 sla_pct (30d) · M003 response (30d) · PPM (90d) · planned (12m)
create or replace view cip_calc.wo_metrics with (security_invoker = true) as
select
  w.client_code,
  w.estate_code,
  grouping(w.estate_code) = 1 as is_client_total,
  count(*) filter (where w.status in ('Open', 'InProgress', 'OnHold'))                                  as open_orders,
  count(*) filter (where w.status in ('Open', 'InProgress', 'OnHold') and w.priority <= 2)              as open_p1p2,
  count(*) filter (where w.status in ('Open', 'InProgress', 'OnHold')
                     and w.created_at < cip_core.utc_now() - interval '30 days')                         as backlog_30d,
  count(*) filter (where w.wo_type = 'Reactive' and w.status = 'Completed'
                     and w.completed_at >= cip_core.utc_now() - interval '30 days')                      as reactive_closed_30d,
  count(*) filter (where w.wo_type = 'Reactive' and w.status = 'Completed'
                     and w.completed_at >= cip_core.utc_now() - interval '30 days'
                     and w.responded_at <= w.respond_by)                                                 as reactive_in_sla_30d,
  avg(extract(epoch from (w.responded_at - w.created_at)) / 60.0)
     filter (where w.wo_type = 'Reactive' and w.status = 'Completed'
               and w.completed_at >= cip_core.utc_now() - interval '30 days')                            as avg_response_min,
  avg(extract(epoch from (w.completed_at - w.created_at)) / 3600.0)
     filter (where w.wo_type = 'Reactive' and w.status = 'Completed'
               and w.completed_at >= cip_core.utc_now() - interval '30 days')                            as mttr_hours,
  count(*) filter (where w.wo_type = 'PPM' and w.status <> 'Cancelled'
                     and w.due_at >= cip_core.utc_now() - interval '90 days' and w.due_at <= cip_core.utc_now()) as ppm_due_90d,
  count(*) filter (where w.wo_type = 'PPM' and w.status = 'Completed'
                     and w.due_at >= cip_core.utc_now() - interval '90 days' and w.due_at <= cip_core.utc_now()) as ppm_done_90d,
  count(*) filter (where w.status <> 'Cancelled' and w.created_at >= cip_core.utc_now() - interval '12 months') as wo_12m,
  count(*) filter (where w.wo_type = 'PPM' and w.status <> 'Cancelled'
                     and w.created_at >= cip_core.utc_now() - interval '12 months')                      as ppm_12m,
  max(w.ingested_at) as last_ingested_at
from cip_silver.work_order w
group by grouping sets ((w.client_code), (w.client_code, w.estate_code));

-- M070: average over the 15 minutes up to each metric's latest reading,
-- maintained by cip_ingest.iot_reading_batch in cip_silver.sensor_window
create or replace view cip_calc.env_latest with (security_invoker = true) as
select w.client_code, w.estate_code, w.metric, w.value, w.sensor_count, w.last_read_at
from cip_silver.sensor_window w;

create or replace view cip_calc.env_estate with (security_invoker = true) as
select p.client_code, p.estate_code, p.iaq, p.water_quality, p.humidity, p.fire_integrity,
       round((p.iaq + p.water_quality + p.humidity + p.fire_integrity) / 4.0, 1) as env_score,
       p.avg_temp_c, p.sensors_reporting, p.env_alerts_open, p.last_read_at
from (
  select client_code, estate_code,
         max(value) filter (where metric = 'iaq')            as iaq,
         max(value) filter (where metric = 'water_quality')  as water_quality,
         max(value) filter (where metric = 'humidity')       as humidity,
         max(value) filter (where metric = 'fire_integrity') as fire_integrity,
         max(value) filter (where metric = 'temp_c')         as avg_temp_c,
         sum(sensor_count)                                   as sensors_reporting,
         count(*) filter (where metric <> 'temp_c' and value < 80) as env_alerts_open,
         max(last_read_at)                                   as last_read_at
  from cip_calc.env_latest
  group by client_code, estate_code
) p;

-- Invisible Care Index (weights are data: cip_core.index_weight)
create or replace view cip_calc.estate_health with (security_invoker = true) as
with env as materialized (select * from cip_calc.env_estate),
     wo  as materialized (select * from cip_calc.wo_metrics where not is_client_total),
     wt  as materialized (
       select max(weight) filter (where component = 'environmental')   as w_env,
              max(weight) filter (where component = 'ppm_compliance')  as w_ppm,
              max(weight) filter (where component = 'critical_wo')     as w_crit,
              max(weight) filter (where component = 'asset_condition') as w_cond
       from cip_core.index_weight)
select e.client_code, e.estate_code, env.env_score, ppm.ppm_pct, crit.crit_score, ac.condition_idx,
       round(wt.w_env * env.env_score + wt.w_ppm * ppm.ppm_pct
           + wt.w_crit * crit.crit_score + wt.w_cond * ac.condition_idx)::int as health_idx
from cip_core.estate e
left join env on env.estate_code = e.estate_code
left join wo  on wo.estate_code  = e.estate_code
left join cip_silver.asset_condition ac on ac.estate_code = e.estate_code
cross join wt
cross join lateral (select round(100.0 * wo.ppm_done_90d / nullif(wo.ppm_due_90d, 0), 1) as ppm_pct) ppm
cross join lateral (
  select round(case when ac.assets_tagged is null or ac.assets_tagged = 0 then null
                    else greatest(0, 100.0 - 20.0 * coalesce(wo.open_p1p2, 0) * 1000.0 / ac.assets_tagged) end, 1) as crit_score
) crit;

-- M060: distinct staff clocked in and not yet out (16h shift window)
create or replace view cip_calc.hr_metrics with (security_invoker = true) as
select c.client_code, c.estate_code, grouping(c.estate_code) = 1 as is_client_total,
       count(distinct c.staff_ref) as staff_on_site,
       count(distinct c.staff_ref) filter (where c.category = 'Technical')     as technical,
       count(distinct c.staff_ref) filter (where c.category = 'Soft services') as soft_services,
       count(distinct c.staff_ref) filter (where c.category = 'Professional')  as professional,
       count(distinct c.staff_ref) filter (where c.category = 'Admin')         as admin
from cip_silver.clock_event c
where c.clock_out_at is null and c.clock_in_at >= cip_core.utc_now() - interval '16 hours'
group by grouping sets ((c.client_code), (c.client_code, c.estate_code));

create or replace view cip_calc.roster_metrics with (security_invoker = true) as
select r.client_code, r.estate_code, grouping(r.estate_code) = 1 as is_client_total,
       sum(r.planned_headcount) as planned_headcount
from cip_silver.roster_plan r
group by grouping sets ((r.client_code), (r.client_code, r.estate_code));

-- Fiscal year = calendar year of the latest closed period in the ledger
create or replace view cip_calc.finance_period with (security_invoker = true) as
select client_code, max(period) as last_period from cip_silver.gl_actual group by client_code;

create or replace view cip_calc.finance_plan with (security_invoker = true) as
select b.client_code, b.estate_code, grouping(b.estate_code) = 1 as is_client_total, p.last_period,
       sum(b.amount_aed) as opex_fy_plan_aed,
       sum(b.amount_aed) filter (where b.period <= p.last_period) as opex_ytd_plan_aed
from cip_silver.budget b
join cip_calc.finance_period p on p.client_code = b.client_code and b.period / 100 = p.last_period / 100
group by grouping sets ((b.client_code, p.last_period), (b.client_code, p.last_period, b.estate_code));

create or replace view cip_calc.finance_actual with (security_invoker = true) as
select a.client_code, a.estate_code, grouping(a.estate_code) = 1 as is_client_total,
       sum(a.amount_aed) as opex_ytd_actual_aed
from cip_silver.gl_actual a
join cip_calc.finance_period p on p.client_code = a.client_code
 and a.period / 100 = p.last_period / 100 and a.period <= p.last_period
group by grouping sets ((a.client_code), (a.client_code, a.estate_code));
