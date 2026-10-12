-- =============================================================================
-- 30 · contract views - the only objects Data API builder can read
--
-- Each view is one entity in dab/dab-config.json and one REST path:
--   GET /api/<view name>          (behind the gateway / APIM)
-- Column names are the JSON keys the portal binds to. Changing a column is
-- a contract change: update docs/data-contract.md and the DAB config with it.
-- Timestamps are UTC (datetime2, serialised without a zone suffix).
-- =============================================================================
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

-- Estate master: coded estates only ----------------------------------------
CREATE OR ALTER VIEW contract.vw_estate
AS
SELECT
    e.estate_code,
    e.client_code,
    e.emirate,
    e.region,
    e.tier,
    CASE e.tier WHEN 1 THEN N'Flagship Estate'
                WHEN 2 THEN N'Principal Residence'
                ELSE N'Residential Estate' END AS tier_name,
    e.status_label,
    e.class_label,
    e.map_x,
    e.map_y,
    e.label_pos,
    e.managed_since
FROM core.estate AS e;
GO

-- M001-M003 · service delivery per estate ----------------------------------
CREATE OR ALTER VIEW contract.vw_service_delivery
AS
SELECT
    e.estate_code,
    ISNULL(m.open_orders, 0) AS open_orders,
    ISNULL(m.open_p1p2, 0)   AS open_p1p2,
    ISNULL(m.backlog_30d, 0) AS backlog_30d,
    CAST(100.0 * m.reactive_in_sla_30d / NULLIF(m.reactive_closed_30d, 0) AS decimal(5,1)) AS sla_pct,
    CAST(m.avg_response_min AS decimal(6,1)) AS avg_response_min,
    CAST(m.mttr_hours AS decimal(6,1))       AS mttr_hours,
    CAST(100.0 * m.ppm_done_90d / NULLIF(m.ppm_due_90d, 0) AS decimal(5,1)) AS ppm_completion_pct,
    CAST(100.0 * m.ppm_12m / NULLIF(m.wo_12m, 0) AS decimal(5,1))           AS planned_pct,
    m.last_ingested_at,
    SYSUTCDATETIME() AS as_of
FROM core.estate AS e
LEFT JOIN calc.wo_metrics AS m
  ON m.estate_code = e.estate_code
 AND m.is_client_total = 0;
GO

-- M070-M071 + Invisible Care Index per estate -------------------------------
CREATE OR ALTER VIEW contract.vw_invisible_care
AS
SELECT
    e.estate_code,
    env.iaq,
    env.water_quality,
    env.humidity,
    env.fire_integrity,
    env.env_score,
    env.avg_temp_c,
    ISNULL(env.sensors_reporting, 0) AS sensors_reporting,
    ISNULL(env.env_alerts_open, 0)   AS env_alerts_open,
    h.ppm_pct       AS ppm_score,
    h.crit_score    AS critical_wo_score,
    h.condition_idx AS asset_condition_idx,
    h.health_idx,
    CASE WHEN h.health_idx >= 90 THEN 'Nominal'
         WHEN h.health_idx >= 80 THEN 'Watch'
         WHEN h.health_idx IS NOT NULL THEN 'Attention' END AS health_band,
    env.last_read_at,
    DATEDIFF(minute, env.last_read_at, SYSUTCDATETIME()) AS freshness_min
FROM core.estate AS e
LEFT JOIN calc.env_estate    AS env ON env.estate_code = e.estate_code
LEFT JOIN calc.estate_health AS h   ON h.estate_code   = e.estate_code;
GO

-- M010-M012 · asset register and condition per estate -----------------------
CREATE OR ALTER VIEW contract.vw_asset_mgmt
AS
SELECT
    a.estate_code,
    a.assets_tagged      AS asset_count,
    a.condition_idx,
    a.good_fair_pct,
    a.critical_monitored,
    a.beyond_life        AS assets_beyond_life,
    a.surveyed_at
FROM silver.asset_condition AS a;
GO

-- M020-M022 · OPEX and CAPEX per estate -------------------------------------
CREATE OR ALTER VIEW contract.vw_finance
AS
SELECT
    e.estate_code,
    pl.last_period / 100 AS fy,
    pl.last_period       AS last_closed_period,
    pl.opex_fy_plan_aed,
    pl.opex_ytd_plan_aed,
    ac.opex_ytd_actual_aed,
    CAST(100.0 * (ac.opex_ytd_actual_aed - pl.opex_ytd_plan_aed) / NULLIF(pl.opex_ytd_plan_aed, 0) AS decimal(6,1)) AS opex_var_pct,
    -- annualised = YTD actual / elapsed share of the year (KPI dictionary)
    CAST(ac.opex_ytd_actual_aed * 12.0 / NULLIF(pl.last_period % 100, 0) AS decimal(14,0)) AS opex_annualised_aed,
    cx.budget_aed AS capex_fy_aed,
    cx.drawn_aed  AS capex_drawn_aed,
    CAST(100.0 * cx.drawn_aed / NULLIF(cx.budget_aed, 0) AS decimal(5,1)) AS capex_drawn_pct
FROM core.estate AS e
LEFT JOIN calc.finance_plan   AS pl ON pl.estate_code = e.estate_code AND pl.is_client_total = 0
LEFT JOIN calc.finance_actual AS ac ON ac.estate_code = e.estate_code AND ac.is_client_total = 0
LEFT JOIN silver.capex_programme AS cx
  ON cx.estate_code = e.estate_code
 AND cx.fy = pl.last_period / 100;
GO

-- Portfolio OPEX by month, current fiscal year -----------------------------
CREATE OR ALTER VIEW contract.vw_finance_monthly
AS
SELECT
    b.client_code,
    b.period,
    b.opex_plan_aed,
    a.opex_actual_aed
FROM (
    SELECT client_code, period, SUM(amount_aed) AS opex_plan_aed
    FROM silver.budget
    GROUP BY client_code, period
) AS b
JOIN calc.finance_period AS p
  ON p.client_code = b.client_code
 AND b.period / 100 = p.last_period / 100
LEFT JOIN (
    SELECT client_code, period, SUM(amount_aed) AS opex_actual_aed
    FROM silver.gl_actual
    GROUP BY client_code, period
) AS a
  ON a.client_code = b.client_code
 AND a.period = b.period;
GO

-- OPEX YTD by ERP cost dimension -------------------------------------------
CREATE OR ALTER VIEW contract.vw_finance_dimension
AS
SELECT
    pl.client_code,
    pl.cost_dimension,
    pl.ytd_plan_aed   AS opex_ytd_plan_aed,
    ac.ytd_actual_aed AS opex_ytd_actual_aed,
    CAST(100.0 * (ac.ytd_actual_aed - pl.ytd_plan_aed) / NULLIF(pl.ytd_plan_aed, 0) AS decimal(6,1)) AS var_pct
FROM (
    SELECT b.client_code, b.cost_dimension, SUM(b.amount_aed) AS ytd_plan_aed
    FROM silver.budget AS b
    JOIN calc.finance_period AS p
      ON p.client_code = b.client_code
     AND b.period / 100 = p.last_period / 100
     AND b.period <= p.last_period
    GROUP BY b.client_code, b.cost_dimension
) AS pl
LEFT JOIN (
    SELECT a.client_code, a.cost_dimension, SUM(a.amount_aed) AS ytd_actual_aed
    FROM silver.gl_actual AS a
    JOIN calc.finance_period AS p
      ON p.client_code = a.client_code
     AND a.period / 100 = p.last_period / 100
     AND a.period <= p.last_period
    GROUP BY a.client_code, a.cost_dimension
) AS ac
  ON ac.client_code = pl.client_code
 AND ac.cost_dimension = pl.cost_dimension;
GO

-- M060-M061 · people on site per estate ------------------------------------
CREATE OR ALTER VIEW contract.vw_hr
AS
SELECT
    e.estate_code,
    ISNULL(h.staff_on_site, 0)  AS staff_on_site,
    ISNULL(h.technical, 0)      AS technical,
    ISNULL(h.soft_services, 0)  AS soft_services,
    ISNULL(h.professional, 0)   AS professional,
    ISNULL(h.admin, 0)          AS admin,
    r.planned_headcount,
    CAST(100.0 * ISNULL(h.staff_on_site, 0) / NULLIF(r.planned_headcount, 0) AS decimal(5,1)) AS deployment_vs_plan_pct
FROM core.estate AS e
LEFT JOIN calc.hr_metrics     AS h ON h.estate_code = e.estate_code AND h.is_client_total = 0
LEFT JOIN calc.roster_metrics AS r ON r.estate_code = e.estate_code AND r.is_client_total = 0;
GO

-- M030-M032 · procurement summary per client -------------------------------
CREATE OR ALTER VIEW contract.vw_procurement
AS
SELECT
    c.client_code,
    SUM(CASE WHEN t.status <> 'Completed' THEN 1 ELSE 0 END) AS active_tenders,
    SUM(CASE WHEN t.status = 'Overdue' THEN 1 ELSE 0 END)    AS overdue_tenders,
    SUM(CASE WHEN t.status = 'At Risk' THEN 1 ELSE 0 END)    AS at_risk_tenders,
    CAST(SUM(CASE WHEN t.status <> 'Completed' THEN t.est_value_aed ELSE 0 END) AS decimal(14,0)) AS pipeline_aed,
    -- M031: tenders live at a stage-gate (not yet stabilised)
    SUM(CASE WHEN t.status <> 'Completed' THEN 1 ELSE 0 END) AS gates_live,
    AVG(CASE WHEN t.go_live_at IS NOT NULL THEN DATEDIFF(day, t.scoped_at, t.go_live_at) END) AS avg_cycle_days,
    CAST(SUM(CASE WHEN YEAR(t.awarded_at) = YEAR(SYSUTCDATETIME()) THEN t.est_value_aed ELSE 0 END) AS decimal(14,0)) AS awarded_ytd_aed
FROM core.client AS c
LEFT JOIN silver.tender AS t ON t.client_code = c.client_code
GROUP BY c.client_code;
GO

CREATE OR ALTER VIEW contract.vw_tender
AS
SELECT
    t.tender_ref,
    ISNULL(t.estate_code, 'Portfolio') AS estate_code,
    t.scope,
    t.category,
    t.bidders,
    t.gates_passed,
    ISNULL(g_last.gate_name, N'Not started')          AS last_milestone,
    ISNULL(g_next.gate_name, N'Go-Live / Stabilised') AS next_milestone,
    t.status,
    t.est_value_aed,
    t.baseline_var_pct,
    t.scoped_at,
    ev.last_passed_at
FROM silver.tender AS t
LEFT JOIN core.procurement_gate AS g_last ON g_last.gate_no = t.gates_passed
LEFT JOIN core.procurement_gate AS g_next ON g_next.gate_no = t.gates_passed + 1
OUTER APPLY (
    SELECT MAX(e.passed_at) AS last_passed_at
    FROM silver.tender_gate_event AS e
    WHERE e.tender_ref = t.tender_ref
) AS ev;
GO

CREATE OR ALTER VIEW contract.vw_tender_gate
AS
SELECT
    e.tender_ref,
    e.gate_no,
    g.gate_name,
    e.passed_at
FROM silver.tender_gate_event AS e
JOIN core.procurement_gate AS g ON g.gate_no = e.gate_no;
GO

-- M040-M041 · projects and on-demand works ---------------------------------
-- stages_done = stages reached; the current stage is the last one reached.
CREATE OR ALTER VIEW contract.vw_works
AS
SELECT
    w.item_ref,
    w.item_name,
    w.item_type,
    w.estate_code,
    w.stages_done,
    st.stage_total,
    CASE WHEN w.stages_done >= st.stage_total THEN N'Completed'
         ELSE ISNULL(s.stage_name, N'—') END AS current_stage,
    w.status,
    w.value_aed,
    w.reported_at,
    w.completed_at,
    CASE WHEN w.completed_at IS NOT NULL THEN DATEDIFF(day, w.reported_at, w.completed_at) END AS resolution_days
FROM silver.work_item AS w
CROSS APPLY (
    SELECT COUNT(*) AS stage_total
    FROM core.work_stage AS ws
    WHERE ws.item_type = w.item_type
) AS st
LEFT JOIN core.work_stage AS s
  ON s.item_type = w.item_type
 AND s.stage_no  = w.stages_done;
GO

-- Attention & actions: exceptions are computed from thresholds; people only
-- add the narrative and the action (silver.exception_action).
--   OPEX variance YTD >= +5%      -> warning (>= +10% critical)
--   environmental index < 80      -> warning
--   tender status Overdue         -> critical
CREATE OR ALTER VIEW contract.vw_exceptions
AS
SELECT
    x.exception_key,
    x.estate_code,
    x.domain,
    x.severity,
    CONCAT(x.detected, CASE WHEN a.cause_note IS NOT NULL THEN N' — ' + a.cause_note ELSE N'' END) AS cause,
    ISNULL(a.action_text, N'No action logged — assign an owner') AS action_text,
    ISNULL(a.owner_team, N'Unassigned') AS owner_team,
    a.updated_at AS action_updated_at
FROM (
    SELECT
        CAST(CONCAT('OPEX:', f.estate_code) AS varchar(48)) AS exception_key,
        f.estate_code,
        N'Finance' AS domain,
        CASE WHEN f.opex_var_pct >= 10 THEN 'critical' ELSE 'warning' END AS severity,
        CONCAT(N'OPEX +', CONVERT(varchar(12), f.opex_var_pct), N'% vs plan YTD') AS detected
    FROM contract.vw_finance AS f
    WHERE f.opex_var_pct >= 5

    UNION ALL

    SELECT
        CAST(CONCAT('ENV:', l.estate_code, ':', l.metric) AS varchar(48)),
        l.estate_code,
        N'Invisible Care',
        'warning',
        CONCAT(CASE l.metric WHEN 'iaq'            THEN N'Indoor air quality'
                             WHEN 'water_quality'  THEN N'Water quality'
                             WHEN 'humidity'       THEN N'Humidity'
                             ELSE N'Fire systems integrity' END,
               N' index ', CONVERT(varchar(12), CAST(ROUND(l.value, 0) AS int)), N'/100')
    FROM calc.env_latest AS l
    WHERE l.metric <> 'temp_c'
      AND l.value < 80

    UNION ALL

    SELECT
        CAST(CONCAT('TENDER:', t.tender_ref) AS varchar(48)),
        ISNULL(t.estate_code, 'Portfolio'),
        N'Procurement',
        'critical',
        CONCAT(t.scope, N' tender overdue at ', LOWER(ISNULL(g.gate_name, N'scoping')))
    FROM silver.tender AS t
    LEFT JOIN core.procurement_gate AS g ON g.gate_no = t.gates_passed
    WHERE t.status = 'Overdue'
) AS x
LEFT JOIN silver.exception_action AS a ON a.exception_key = x.exception_key;
GO

-- Live source-event feed (ingestion log) -----------------------------------
CREATE OR ALTER VIEW contract.vw_activity
AS
SELECT
    l.event_id,
    l.source_system,
    l.event_type,
    l.estate_code,
    l.entity_ref,
    l.detail,
    l.ingested_at
FROM silver.ingest_log AS l;
GO

-- M090 · data health per source system --------------------------------------
CREATE OR ALTER VIEW contract.vw_data_health
AS
SELECT
    CAST(CONCAT(c.client_code, ':', s.source_system) AS varchar(40)) AS health_key,
    s.source_system,
    s.feed,
    s.expected_cadence_min,
    lg.last_ingested_at,
    ISNULL(lg.events_1h, 0) AS events_1h,
    DATEDIFF(minute, lg.last_ingested_at, SYSUTCDATETIME()) AS freshness_min,
    CASE
        WHEN s.expected_cadence_min IS NULL THEN 'No digital source'
        WHEN lg.last_ingested_at IS NULL THEN 'No data'
        WHEN DATEDIFF(minute, lg.last_ingested_at, SYSUTCDATETIME()) <= s.expected_cadence_min THEN 'Fresh'
        WHEN DATEDIFF(minute, lg.last_ingested_at, SYSUTCDATETIME()) <= 3 * s.expected_cadence_min THEN 'Late'
        ELSE 'Stale'
    END AS status
FROM core.client AS c
CROSS JOIN (VALUES
    ('MRI CAFM',         N'Pipeline · near-live',      15),
    ('IoT / Event Hub',  N'Eventstream · streaming',    5),
    ('D365 HR + T&A',    N'Pipeline · near-live',      60),
    ('D365 F&O',         N'Pipeline · daily',        1440),
    ('D365 Projects',    N'Pipeline · daily',        1440),
    ('Utility invoices', N'Manual keying (M080/M081 gap)', NULL)
) AS s (source_system, feed, expected_cadence_min)
OUTER APPLY (
    SELECT
        MAX(l.ingested_at) AS last_ingested_at,
        SUM(CASE WHEN l.ingested_at >= DATEADD(hour, -1, SYSUTCDATETIME()) THEN 1 ELSE 0 END) AS events_1h
    FROM silver.ingest_log AS l
    WHERE l.client_code = c.client_code
      AND l.source_system = s.source_system
) AS lg;
GO

-- Portfolio headline per client (KPI strip) --------------------------------
CREATE OR ALTER VIEW contract.vw_portfolio_kpi
AS
SELECT
    c.client_code,
    est.estates,
    ISNULL(wo.open_orders, 0) AS open_orders,
    ISNULL(wo.open_p1p2, 0)   AS open_p1p2,
    ISNULL(wo.backlog_30d, 0) AS backlog_30d,
    CAST(100.0 * wo.reactive_in_sla_30d / NULLIF(wo.reactive_closed_30d, 0) AS decimal(5,1)) AS sla_pct,
    CAST(100.0 * wo.ppm_done_90d / NULLIF(wo.ppm_due_90d, 0) AS decimal(5,1))               AS ppm_completion_pct,
    CAST(100.0 * wo.ppm_12m / NULLIF(wo.wo_12m, 0) AS decimal(5,1))                         AS planned_pct,
    ISNULL(hr.staff_on_site, 0) AS staff_on_site,
    ro.planned_headcount,
    hl.health_idx,
    pl.last_period AS last_closed_period,
    pl.opex_fy_plan_aed,
    pl.opex_ytd_plan_aed,
    ac.opex_ytd_actual_aed,
    CAST(100.0 * (ac.opex_ytd_actual_aed - pl.opex_ytd_plan_aed) / NULLIF(pl.opex_ytd_plan_aed, 0) AS decimal(6,1)) AS opex_var_pct,
    CAST(ac.opex_ytd_actual_aed * 12.0 / NULLIF(pl.last_period % 100, 0) AS decimal(14,0)) AS opex_annualised_aed,
    SYSUTCDATETIME() AS as_of
FROM core.client AS c
OUTER APPLY (SELECT COUNT(*) AS estates FROM core.estate AS e WHERE e.client_code = c.client_code) AS est
LEFT JOIN calc.wo_metrics     AS wo ON wo.client_code = c.client_code AND wo.is_client_total = 1
LEFT JOIN calc.hr_metrics     AS hr ON hr.client_code = c.client_code AND hr.is_client_total = 1
LEFT JOIN calc.roster_metrics AS ro ON ro.client_code = c.client_code AND ro.is_client_total = 1
LEFT JOIN calc.finance_plan   AS pl ON pl.client_code = c.client_code AND pl.is_client_total = 1
LEFT JOIN calc.finance_actual AS ac ON ac.client_code = c.client_code AND ac.is_client_total = 1
OUTER APPLY (
    -- portfolio health = simple mean of estate indices (KPI dictionary)
    SELECT CAST(ROUND(AVG(CAST(h.health_idx AS decimal(6,2))), 0) AS int) AS health_idx
    FROM calc.estate_health AS h
    WHERE h.client_code = c.client_code
) AS hl;
GO
