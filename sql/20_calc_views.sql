-- =============================================================================
-- 20 · calculation views (internal - not granted to dab_reader)
--
-- Each metric is defined exactly once here. GROUPING SETS give the same
-- definition at two grains (per estate, and per client total) so a portfolio
-- figure is never an average of estate percentages by accident.
-- Row-level security on the silver tables applies underneath every view.
-- =============================================================================
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

-- ------------------------------------------------------- work orders --------
-- M001 open_orders · M002 sla_pct (rolling 30d) · M003 avg_response_min (30d,
-- reactive only) · PPM completion (rolling 90d) · planned share (trailing 12m)
CREATE OR ALTER VIEW calc.wo_metrics
AS
SELECT
    w.client_code,
    w.estate_code,
    CAST(GROUPING(w.estate_code) AS bit) AS is_client_total,
    SUM(CASE WHEN w.status IN ('Open', 'InProgress', 'OnHold') THEN 1 ELSE 0 END) AS open_orders,
    SUM(CASE WHEN w.status IN ('Open', 'InProgress', 'OnHold') AND w.priority <= 2 THEN 1 ELSE 0 END) AS open_p1p2,
    SUM(CASE WHEN w.status IN ('Open', 'InProgress', 'OnHold')
              AND w.created_at < DATEADD(day, -30, SYSUTCDATETIME()) THEN 1 ELSE 0 END) AS backlog_30d,
    SUM(CASE WHEN w.wo_type = 'Reactive' AND w.status = 'Completed'
              AND w.completed_at >= DATEADD(day, -30, SYSUTCDATETIME()) THEN 1 ELSE 0 END) AS reactive_closed_30d,
    SUM(CASE WHEN w.wo_type = 'Reactive' AND w.status = 'Completed'
              AND w.completed_at >= DATEADD(day, -30, SYSUTCDATETIME())
              AND w.responded_at <= w.respond_by THEN 1 ELSE 0 END) AS reactive_in_sla_30d,
    AVG(CASE WHEN w.wo_type = 'Reactive' AND w.status = 'Completed'
              AND w.completed_at >= DATEADD(day, -30, SYSUTCDATETIME())
             THEN CAST(DATEDIFF(second, w.created_at, w.responded_at) AS float) / 60.0 END) AS avg_response_min,
    AVG(CASE WHEN w.wo_type = 'Reactive' AND w.status = 'Completed'
              AND w.completed_at >= DATEADD(day, -30, SYSUTCDATETIME())
             THEN CAST(DATEDIFF(second, w.created_at, w.completed_at) AS float) / 3600.0 END) AS mttr_hours,
    SUM(CASE WHEN w.wo_type = 'PPM' AND w.status <> 'Cancelled'
              AND w.due_at >= DATEADD(day, -90, SYSUTCDATETIME()) AND w.due_at <= SYSUTCDATETIME() THEN 1 ELSE 0 END) AS ppm_due_90d,
    SUM(CASE WHEN w.wo_type = 'PPM' AND w.status = 'Completed'
              AND w.due_at >= DATEADD(day, -90, SYSUTCDATETIME()) AND w.due_at <= SYSUTCDATETIME() THEN 1 ELSE 0 END) AS ppm_done_90d,
    SUM(CASE WHEN w.status <> 'Cancelled'
              AND w.created_at >= DATEADD(month, -12, SYSUTCDATETIME()) THEN 1 ELSE 0 END) AS wo_12m,
    SUM(CASE WHEN w.wo_type = 'PPM' AND w.status <> 'Cancelled'
              AND w.created_at >= DATEADD(month, -12, SYSUTCDATETIME()) THEN 1 ELSE 0 END) AS ppm_12m,
    MAX(w.ingested_at) AS last_ingested_at
FROM silver.work_order AS w
GROUP BY GROUPING SETS ((w.client_code), (w.client_code, w.estate_code));
GO

-- ------------------------------------------------------- environment --------
-- M070: average over the 15 minutes up to each metric's latest reading.
-- Anchored on the latest reading, not on "now", so a stalled feed shows as
-- stale (freshness) instead of silently disappearing.
CREATE OR ALTER VIEW calc.env_latest
AS
SELECT
    r.client_code,
    r.estate_code,
    r.metric,
    CAST(AVG(r.value) AS decimal(6,1)) AS value,
    MAX(r.sensor_count)                AS sensor_count,
    MAX(r.read_at)                     AS last_read_at
FROM silver.sensor_reading AS r
JOIN (
    SELECT estate_code, metric, MAX(read_at) AS last_at
    FROM silver.sensor_reading
    GROUP BY estate_code, metric
) AS x
  ON  x.estate_code = r.estate_code
  AND x.metric      = r.metric
  AND r.read_at     > DATEADD(minute, -15, x.last_at)
GROUP BY r.client_code, r.estate_code, r.metric;
GO

CREATE OR ALTER VIEW calc.env_estate
AS
SELECT
    p.client_code,
    p.estate_code,
    p.iaq,
    p.water_quality,
    p.humidity,
    p.fire_integrity,
    CAST((p.iaq + p.water_quality + p.humidity + p.fire_integrity) / 4.0 AS decimal(5,1)) AS env_score,
    p.avg_temp_c,
    p.sensors_reporting,
    p.env_alerts_open,
    p.last_read_at
FROM (
    SELECT
        client_code,
        estate_code,
        MAX(CASE WHEN metric = 'iaq'            THEN value END) AS iaq,
        MAX(CASE WHEN metric = 'water_quality'  THEN value END) AS water_quality,
        MAX(CASE WHEN metric = 'humidity'       THEN value END) AS humidity,
        MAX(CASE WHEN metric = 'fire_integrity' THEN value END) AS fire_integrity,
        MAX(CASE WHEN metric = 'temp_c'         THEN value END) AS avg_temp_c,
        SUM(sensor_count)                                       AS sensors_reporting,
        -- M071: open threshold breaches (index below the 80 "attention" band)
        SUM(CASE WHEN metric <> 'temp_c' AND value < 80 THEN 1 ELSE 0 END) AS env_alerts_open,
        MAX(last_read_at)                                       AS last_read_at
    FROM calc.env_latest
    GROUP BY client_code, estate_code
) AS p;
GO

-- ------------------------------------------------- Invisible Care Index -----
-- Index = w_env*Environmental + w_ppm*PPM completion
--       + w_crit*Critical work orders + w_cond*Asset condition
-- Critical WO score: 100 at zero open P1/P2, falling 20 points per open
-- P1/P2 per 1,000 tagged assets, floored at 0.
CREATE OR ALTER VIEW calc.estate_health
AS
SELECT
    e.client_code,
    e.estate_code,
    env.env_score,
    ppm.ppm_pct,
    crit.crit_score,
    ac.condition_idx,
    CAST(ROUND(  wt.w_env  * env.env_score
               + wt.w_ppm  * ppm.ppm_pct
               + wt.w_crit * crit.crit_score
               + wt.w_cond * ac.condition_idx, 0) AS int) AS health_idx
FROM core.estate AS e
LEFT JOIN calc.env_estate      AS env ON env.estate_code = e.estate_code
LEFT JOIN calc.wo_metrics      AS wo  ON wo.estate_code  = e.estate_code AND wo.is_client_total = 0
LEFT JOIN silver.asset_condition AS ac ON ac.estate_code = e.estate_code
CROSS JOIN (
    SELECT
        MAX(CASE WHEN component = 'environmental'   THEN weight END) AS w_env,
        MAX(CASE WHEN component = 'ppm_compliance'  THEN weight END) AS w_ppm,
        MAX(CASE WHEN component = 'critical_wo'     THEN weight END) AS w_crit,
        MAX(CASE WHEN component = 'asset_condition' THEN weight END) AS w_cond
    FROM core.index_weight
) AS wt
CROSS APPLY (
    SELECT CAST(100.0 * wo.ppm_done_90d / NULLIF(wo.ppm_due_90d, 0) AS decimal(5,1)) AS ppm_pct
) AS ppm
CROSS APPLY (
    SELECT CAST(CASE
                  WHEN ac.assets_tagged IS NULL OR ac.assets_tagged = 0 THEN NULL
                  WHEN 100.0 - 20.0 * ISNULL(wo.open_p1p2, 0) * 1000.0 / ac.assets_tagged < 0 THEN 0
                  ELSE 100.0 - 20.0 * ISNULL(wo.open_p1p2, 0) * 1000.0 / ac.assets_tagged
                END AS decimal(5,1)) AS crit_score
) AS crit;
GO

-- -------------------------------------------------------------- people ------
-- M060: distinct staff clocked in and not yet out (shift window 16h)
CREATE OR ALTER VIEW calc.hr_metrics
AS
SELECT
    c.client_code,
    c.estate_code,
    CAST(GROUPING(c.estate_code) AS bit) AS is_client_total,
    COUNT(DISTINCT c.staff_ref) AS staff_on_site,
    COUNT(DISTINCT CASE WHEN c.category = 'Technical'     THEN c.staff_ref END) AS technical,
    COUNT(DISTINCT CASE WHEN c.category = 'Soft services' THEN c.staff_ref END) AS soft_services,
    COUNT(DISTINCT CASE WHEN c.category = 'Professional'  THEN c.staff_ref END) AS professional,
    COUNT(DISTINCT CASE WHEN c.category = 'Admin'         THEN c.staff_ref END) AS admin
FROM silver.clock_event AS c
WHERE c.clock_out_at IS NULL
  AND c.clock_in_at >= DATEADD(hour, -16, SYSUTCDATETIME())
GROUP BY GROUPING SETS ((c.client_code), (c.client_code, c.estate_code));
GO

CREATE OR ALTER VIEW calc.roster_metrics
AS
SELECT
    r.client_code,
    r.estate_code,
    CAST(GROUPING(r.estate_code) AS bit) AS is_client_total,
    SUM(r.planned_headcount) AS planned_headcount
FROM silver.roster_plan AS r
GROUP BY GROUPING SETS ((r.client_code), (r.client_code, r.estate_code));
GO

-- ------------------------------------------------------------- finance ------
-- Fiscal year = calendar year of the latest closed period in the ledger.
CREATE OR ALTER VIEW calc.finance_period
AS
SELECT client_code, MAX(period) AS last_period
FROM silver.gl_actual
GROUP BY client_code;
GO

-- M020/M021: YTD plan and actual, same periods on both sides
CREATE OR ALTER VIEW calc.finance_plan
AS
SELECT
    b.client_code,
    b.estate_code,
    CAST(GROUPING(b.estate_code) AS bit) AS is_client_total,
    p.last_period,
    SUM(b.amount_aed) AS opex_fy_plan_aed,
    SUM(CASE WHEN b.period <= p.last_period THEN b.amount_aed ELSE 0 END) AS opex_ytd_plan_aed
FROM silver.budget AS b
JOIN calc.finance_period AS p
  ON p.client_code = b.client_code
 AND b.period / 100 = p.last_period / 100
GROUP BY GROUPING SETS ((b.client_code, p.last_period), (b.client_code, p.last_period, b.estate_code));
GO

CREATE OR ALTER VIEW calc.finance_actual
AS
SELECT
    a.client_code,
    a.estate_code,
    CAST(GROUPING(a.estate_code) AS bit) AS is_client_total,
    SUM(a.amount_aed) AS opex_ytd_actual_aed
FROM silver.gl_actual AS a
JOIN calc.finance_period AS p
  ON p.client_code = a.client_code
 AND a.period / 100 = p.last_period / 100
 AND a.period <= p.last_period
GROUP BY GROUPING SETS ((a.client_code), (a.client_code, a.estate_code));
GO
