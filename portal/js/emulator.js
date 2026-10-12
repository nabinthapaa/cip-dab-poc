/* =============================================================================
 * CIP · in-browser DAB emulator
 *
 * Stands in for the whole live-read path when no endpoint is configured:
 *   simulator -> silver rows -> contract views (+ RLS) -> DAB REST -> gateway
 *
 * It loads the same seed rows as sql/40_seed.sql and implements each contract
 * view with the same definition as sql/20_calc_views.sql and
 * sql/30_contract_views.sql, so the numbers you see here are computed, not
 * typed in. The HTTP surface mirrors DAB behind the gateway:
 *   GET /api/<entity>?$filter=&$orderby=&$first=&$select=   -> {"value":[...]}
 *   Ocp-Apim-Subscription-Key header required (401 otherwise)
 * Works in the browser (window.CipEmulator) and in Node (module.exports).
 * ============================================================================= */
(function (root) {
  'use strict';

  const SEC = 1000, MIN = 60 * SEC, HOUR = 60 * MIN, DAY = 24 * HOUR;

  // Gateway subscription keys -> client principal (same table as gateway/templates)
  const KEYS = {
    'cl01-demo-7f3a9c': { client_code: 'CL01', user: 'cl01.viewer@portal.demo' },
    'cl02-demo-41be07': { client_code: 'CL02', user: 'cl02.viewer@portal.demo' },
  };

  const TIME_COLS = {
    due_s: 'due_at', respond_by_s: 'respond_by', responded_s: 'responded_at', completed_s: 'completed_at',
    created_s: 'created_at', read_s: 'read_at', passed_s: 'passed_at', scoped_s: 'scoped_at',
    awarded_s: 'awarded_at', go_live_s: 'go_live_at', clock_in_s: 'clock_in_at', clock_out_s: 'clock_out_at',
    surveyed_s: 'surveyed_at', reported_s: 'reported_at', ingested_s: 'ingested_at',
  };
  const GLOBAL_TABLES = new Set(['index_weight', 'procurement_gate', 'work_stage']);

  // DAB entity -> primary key fields (dab/dab-config.json "fields" with primary-key)
  const KEYS_BY_ENTITY = {
    vw_estate: ['estate_code'], vw_service_delivery: ['estate_code'], vw_invisible_care: ['estate_code'],
    vw_asset_mgmt: ['estate_code'], vw_finance: ['estate_code'], vw_finance_monthly: ['client_code', 'period'],
    vw_finance_dimension: ['client_code', 'cost_dimension'], vw_hr: ['estate_code'],
    vw_procurement: ['client_code'], vw_tender: ['tender_ref'], vw_tender_gate: ['tender_ref', 'gate_no'],
    vw_works: ['item_ref'], vw_exceptions: ['exception_key'], vw_activity: ['event_id'],
    vw_data_health: ['health_key'], vw_portfolio_kpi: ['client_code'],
  };

  // ------------------------------------------------------------------ utils
  const r1 = (x) => (x == null || !isFinite(x) ? null : Math.round(x * 10) / 10);
  const r0 = (x) => (x == null || !isFinite(x) ? null : Math.round(x));
  const pct = (a, b) => (b ? r1((100 * a) / b) : null);
  const iso = (t) => (t == null ? null : new Date(t).toISOString().slice(0, 19));  // datetime2(0), UTC, no zone
  const sum = (arr, f) => arr.reduce((a, x) => a + (f(x) || 0), 0);
  const avg = (vals) => { const v = vals.filter((x) => x != null); return v.length ? v.reduce((a, b) => a + b, 0) / v.length : null; };
  const groupBy = (arr, k) => { const m = new Map(); for (const x of arr) { const key = x[k]; if (!m.has(key)) m.set(key, []); m.get(key).push(x); } return m; };
  const OPEN = new Set(['Open', 'InProgress', 'OnHold']);

  function load(seed, now) {
    const db = {};
    for (const [name, t] of Object.entries(seed.tables)) {
      db[name] = t.rows.map((row) => {
        const o = {};
        t.cols.forEach((c, i) => {
          const v = row[i];
          if (c in TIME_COLS) o[TIME_COLS[c]] = v == null ? null : now - v * SEC;
          else o[c] = v;
        });
        return o;
      });
    }
    db.ingest_log.forEach((r, i) => { r.event_id = i + 1; });
    return db;
  }

  // Row-level security: same predicate as sec.fn_client_filter
  function scope(db, client) {
    const s = {};
    for (const [name, rows] of Object.entries(db)) {
      s[name] = GLOBAL_TABLES.has(name) ? rows : rows.filter((r) => r.client_code === client);
    }
    return s;
  }

  // ------------------------------------------------------- calc.* views
  function woMetrics(rows, now) {
    const d30 = now - 30 * DAY, d90 = now - 90 * DAY, m12 = now - 365 * DAY;
    const rc30 = rows.filter((w) => w.wo_type === 'Reactive' && w.status === 'Completed' && w.completed_at >= d30);
    const ppm90 = rows.filter((w) => w.wo_type === 'PPM' && w.status !== 'Cancelled' && w.due_at != null && w.due_at >= d90 && w.due_at <= now);
    const c12 = rows.filter((w) => w.status !== 'Cancelled' && w.created_at >= m12);
    return {
      open_orders: rows.filter((w) => OPEN.has(w.status)).length,
      open_p1p2: rows.filter((w) => OPEN.has(w.status) && w.priority <= 2).length,
      backlog_30d: rows.filter((w) => OPEN.has(w.status) && w.created_at < d30).length,
      reactive_closed_30d: rc30.length,
      reactive_in_sla_30d: rc30.filter((w) => w.responded_at != null && w.responded_at <= w.respond_by).length,
      avg_response_min: avg(rc30.map((w) => (w.responded_at == null ? null : (w.responded_at - w.created_at) / MIN))),
      mttr_hours: avg(rc30.map((w) => (w.completed_at - w.created_at) / HOUR)),
      ppm_due_90d: ppm90.length,
      ppm_done_90d: ppm90.filter((w) => w.status === 'Completed').length,
      wo_12m: c12.length,
      ppm_12m: c12.filter((w) => w.wo_type === 'PPM').length,
      last_ingested_at: rows.reduce((a, w) => Math.max(a, w.ingested_at || 0), 0) || null,
    };
  }

  function envLatest(readings) {
    const out = [];
    const byKey = new Map();
    for (const r of readings) {
      const k = r.estate_code + '|' + r.metric;
      if (!byKey.has(k)) byKey.set(k, []);
      byKey.get(k).push(r);
    }
    for (const rows of byKey.values()) {
      const last = Math.max(...rows.map((r) => r.read_at));
      const win = rows.filter((r) => r.read_at > last - 15 * MIN);
      out.push({
        client_code: rows[0].client_code, estate_code: rows[0].estate_code, metric: rows[0].metric,
        value: r1(avg(win.map((r) => r.value))), sensor_count: Math.max(...win.map((r) => r.sensor_count)), last_read_at: last,
      });
    }
    return out;
  }

  function envEstate(latest) {
    const m = new Map();
    for (const [estate, rows] of groupBy(latest, 'estate_code')) {
      const g = (k) => { const x = rows.find((r) => r.metric === k); return x ? x.value : null; };
      const iaq = g('iaq'), water = g('water_quality'), hum = g('humidity'), fire = g('fire_integrity');
      m.set(estate, {
        iaq, water_quality: water, humidity: hum, fire_integrity: fire,
        env_score: [iaq, water, hum, fire].some((v) => v == null) ? null : r1((iaq + water + hum + fire) / 4),
        avg_temp_c: g('temp_c'),
        sensors_reporting: sum(rows, (r) => r.sensor_count),
        env_alerts_open: rows.filter((r) => r.metric !== 'temp_c' && r.value < 80).length,
        last_read_at: Math.max(...rows.map((r) => r.last_read_at)),
      });
    }
    return m;
  }

  function weights(db) {
    const w = Object.fromEntries(db.index_weight.map((x) => [x.component, x.weight]));
    return { env: w.environmental, ppm: w.ppm_compliance, crit: w.critical_wo, cond: w.asset_condition };
  }

  function estateHealth(s, now, wo, env) {
    const w = weights(s);
    const ac = new Map(s.asset_condition.map((a) => [a.estate_code, a]));
    const out = new Map();
    for (const e of s.estate) {
      const m = wo.get(e.estate_code), en = env.get(e.estate_code), a = ac.get(e.estate_code);
      const ppm = m && m.ppm_due_90d ? r1((100 * m.ppm_done_90d) / m.ppm_due_90d) : null;
      let crit = null;
      if (a && a.assets_tagged) crit = r1(Math.max(0, 100 - (20 * (m ? m.open_p1p2 : 0) * 1000) / a.assets_tagged));
      const parts = [en && en.env_score, ppm, crit, a && a.condition_idx];
      const health = parts.some((v) => v == null) ? null
        : r0(w.env * parts[0] + w.ppm * parts[1] + w.crit * parts[2] + w.cond * parts[3]);
      out.set(e.estate_code, { env_score: en ? en.env_score : null, ppm_pct: ppm, crit_score: crit, condition_idx: a ? a.condition_idx : null, health_idx: health });
    }
    return out;
  }

  function hrMetrics(clock, now) {
    const on = clock.filter((c) => c.clock_out_at == null && c.clock_in_at >= now - 16 * HOUR);
    const count = (rows, cat) => new Set(rows.filter((c) => !cat || c.category === cat).map((c) => c.staff_ref)).size;
    const f = (rows) => ({
      staff_on_site: count(rows), technical: count(rows, 'Technical'), soft_services: count(rows, 'Soft services'),
      professional: count(rows, 'Professional'), admin: count(rows, 'Admin'),
    });
    const byEstate = new Map([...groupBy(on, 'estate_code')].map(([k, v]) => [k, f(v)]));
    return { byEstate, total: f(on) };
  }

  function finance(s) {
    const last = s.gl_actual.reduce((a, r) => Math.max(a, r.period), 0) || null;
    if (!last) return { last: null };
    const fy = Math.floor(last / 100);
    const inFy = (p) => Math.floor(p / 100) === fy;
    const plan = s.budget.filter((b) => inFy(b.period));
    const act = s.gl_actual.filter((a) => inFy(a.period) && a.period <= last);
    return { last, fy, plan, act };
  }

  // -------------------------------------------------- contract.* views
  function views(s, now) {
    const woByEstate = new Map([...groupBy(s.work_order, 'estate_code')].map(([k, v]) => [k, woMetrics(v, now)]));
    const woTotal = woMetrics(s.work_order, now);
    const latest = envLatest(s.sensor_reading);
    const env = envEstate(latest);
    const health = estateHealth(s, now, woByEstate, env);
    const hr = hrMetrics(s.clock_event, now);
    const fin = finance(s);
    const roster = groupBy(s.roster_plan, 'estate_code');
    const gate = new Map(s.procurement_gate.map((g) => [g.gate_no, g.gate_name]));
    const ts = (t) => iso(t);

    const vw_estate = s.estate.map((e) => ({
      estate_code: e.estate_code, client_code: e.client_code, emirate: e.emirate, region: e.region, tier: e.tier,
      tier_name: e.tier === 1 ? 'Flagship Estate' : e.tier === 2 ? 'Principal Residence' : 'Residential Estate',
      status_label: e.status_label, class_label: e.class_label, map_x: e.map_x, map_y: e.map_y,
      label_pos: e.label_pos, managed_since: e.managed_since,
    }));

    const vw_service_delivery = s.estate.map((e) => {
      const m = woByEstate.get(e.estate_code);
      return {
        estate_code: e.estate_code,
        open_orders: m ? m.open_orders : 0, open_p1p2: m ? m.open_p1p2 : 0, backlog_30d: m ? m.backlog_30d : 0,
        sla_pct: m ? pct(m.reactive_in_sla_30d, m.reactive_closed_30d) : null,
        avg_response_min: m ? r1(m.avg_response_min) : null, mttr_hours: m ? r1(m.mttr_hours) : null,
        ppm_completion_pct: m ? pct(m.ppm_done_90d, m.ppm_due_90d) : null,
        planned_pct: m ? pct(m.ppm_12m, m.wo_12m) : null,
        last_ingested_at: m ? ts(m.last_ingested_at) : null, as_of: ts(now),
      };
    });

    const vw_invisible_care = s.estate.map((e) => {
      const en = env.get(e.estate_code) || {}, h = health.get(e.estate_code) || {};
      const hi = h.health_idx;
      return {
        estate_code: e.estate_code, iaq: en.iaq ?? null, water_quality: en.water_quality ?? null,
        humidity: en.humidity ?? null, fire_integrity: en.fire_integrity ?? null, env_score: en.env_score ?? null,
        avg_temp_c: en.avg_temp_c ?? null, sensors_reporting: en.sensors_reporting || 0,
        env_alerts_open: en.env_alerts_open || 0, ppm_score: h.ppm_pct ?? null, critical_wo_score: h.crit_score ?? null,
        asset_condition_idx: h.condition_idx ?? null, health_idx: hi ?? null,
        health_band: hi == null ? null : hi >= 90 ? 'Nominal' : hi >= 80 ? 'Watch' : 'Attention',
        last_read_at: en.last_read_at ? ts(en.last_read_at) : null,
        freshness_min: en.last_read_at ? Math.floor((now - en.last_read_at) / MIN) : null,
      };
    });

    const vw_asset_mgmt = s.asset_condition.map((a) => ({
      estate_code: a.estate_code, asset_count: a.assets_tagged, condition_idx: a.condition_idx,
      good_fair_pct: a.good_fair_pct, critical_monitored: a.critical_monitored,
      assets_beyond_life: a.beyond_life, surveyed_at: ts(a.surveyed_at),
    }));

    const capex = new Map(s.capex_programme.map((c) => [c.estate_code + '|' + c.fy, c]));
    const finEstate = (code) => {
      if (!fin.last) return null;
      const p = fin.plan.filter((b) => b.estate_code === code), a = fin.act.filter((x) => x.estate_code === code);
      const fyPlan = sum(p, (b) => b.amount_aed), ytdPlan = sum(p.filter((b) => b.period <= fin.last), (b) => b.amount_aed);
      const ytdAct = sum(a, (x) => x.amount_aed);
      return { fyPlan, ytdPlan, ytdAct };
    };
    const vw_finance = s.estate.map((e) => {
      const f = finEstate(e.estate_code), c = fin.last ? capex.get(e.estate_code + '|' + fin.fy) : null;
      return {
        estate_code: e.estate_code, fy: fin.fy ?? null, last_closed_period: fin.last,
        opex_fy_plan_aed: f ? f.fyPlan : null, opex_ytd_plan_aed: f ? f.ytdPlan : null, opex_ytd_actual_aed: f ? f.ytdAct : null,
        opex_var_pct: f && f.ytdPlan ? r1((100 * (f.ytdAct - f.ytdPlan)) / f.ytdPlan) : null,
        opex_annualised_aed: f ? r0((f.ytdAct * 12) / (fin.last % 100)) : null,
        capex_fy_aed: c ? c.budget_aed : null, capex_drawn_aed: c ? c.drawn_aed : null,
        capex_drawn_pct: c ? pct(c.drawn_aed, c.budget_aed) : null,
      };
    });

    const vw_finance_monthly = [];
    const vw_finance_dimension = [];
    if (fin.last) {
      const client = s.client[0] ? s.client[0].client_code : null;
      for (const [period, rows] of groupBy(fin.plan, 'period')) {
        const a = s.gl_actual.filter((x) => x.period === period);
        vw_finance_monthly.push({ client_code: client, period, opex_plan_aed: sum(rows, (r) => r.amount_aed),
          opex_actual_aed: a.length ? sum(a, (r) => r.amount_aed) : null });
      }
      for (const [dim, rows] of groupBy(fin.plan.filter((b) => b.period <= fin.last), 'cost_dimension')) {
        const p = sum(rows, (r) => r.amount_aed), a = sum(fin.act.filter((x) => x.cost_dimension === dim), (r) => r.amount_aed);
        vw_finance_dimension.push({ client_code: client, cost_dimension: dim, opex_ytd_plan_aed: p, opex_ytd_actual_aed: a,
          var_pct: p ? r1((100 * (a - p)) / p) : null });
      }
    }

    const vw_hr = s.estate.map((e) => {
      const h = hr.byEstate.get(e.estate_code) || { staff_on_site: 0, technical: 0, soft_services: 0, professional: 0, admin: 0 };
      const planned = roster.has(e.estate_code) ? sum(roster.get(e.estate_code), (r) => r.planned_headcount) : null;
      return { estate_code: e.estate_code, ...h, planned_headcount: planned, deployment_vs_plan_pct: planned ? pct(h.staff_on_site, planned) : null };
    });

    const thisYear = new Date(now).getUTCFullYear();
    const vw_procurement = s.client.map((c) => {
      const t = s.tender;
      const live = t.filter((x) => x.status !== 'Completed');
      const done = t.filter((x) => x.go_live_at != null);
      return {
        client_code: c.client_code, active_tenders: live.length,
        overdue_tenders: t.filter((x) => x.status === 'Overdue').length,
        at_risk_tenders: t.filter((x) => x.status === 'At Risk').length,
        pipeline_aed: sum(live, (x) => x.est_value_aed), gates_live: live.length,
        avg_cycle_days: done.length ? Math.trunc(avg(done.map((x) => Math.round((x.go_live_at - x.scoped_at) / DAY)))) : null,
        awarded_ytd_aed: sum(t.filter((x) => x.awarded_at != null && new Date(x.awarded_at).getUTCFullYear() === thisYear), (x) => x.est_value_aed),
      };
    });

    const vw_tender = s.tender.map((t) => {
      const ev = s.tender_gate_event.filter((g) => g.tender_ref === t.tender_ref);
      return {
        tender_ref: t.tender_ref, estate_code: t.estate_code || 'Portfolio', scope: t.scope, category: t.category,
        bidders: t.bidders, gates_passed: t.gates_passed,
        last_milestone: gate.get(t.gates_passed) || 'Not started',
        next_milestone: gate.get(t.gates_passed + 1) || 'Go-Live / Stabilised',
        status: t.status, est_value_aed: t.est_value_aed, baseline_var_pct: t.baseline_var_pct,
        scoped_at: ts(t.scoped_at), last_passed_at: ev.length ? ts(Math.max(...ev.map((g) => g.passed_at))) : null,
      };
    });

    const vw_tender_gate = s.tender_gate_event.map((g) => ({
      tender_ref: g.tender_ref, gate_no: g.gate_no, gate_name: gate.get(g.gate_no), passed_at: ts(g.passed_at),
    }));

    const stages = groupBy(s.work_stage, 'item_type');
    const vw_works = s.work_item.map((w) => {
      const st = stages.get(w.item_type) || [];
      const cur = st.find((x) => x.stage_no === w.stages_done);
      return {
        item_ref: w.item_ref, item_name: w.item_name, item_type: w.item_type, estate_code: w.estate_code,
        stages_done: w.stages_done, stage_total: st.length,
        current_stage: w.stages_done >= st.length ? 'Completed' : cur ? cur.stage_name : '—',
        status: w.status, value_aed: w.value_aed, reported_at: ts(w.reported_at), completed_at: ts(w.completed_at),
        resolution_days: w.completed_at != null ? Math.round((w.completed_at - w.reported_at) / DAY) : null,
      };
    });

    const actions = new Map(s.exception_action.map((a) => [a.exception_key, a]));
    const LABEL = { iaq: 'Indoor air quality', water_quality: 'Water quality', humidity: 'Humidity', fire_integrity: 'Fire systems integrity' };
    const raw = [];
    for (const f of vw_finance) {
      if (f.opex_var_pct != null && f.opex_var_pct >= 5) {
        raw.push({ exception_key: 'OPEX:' + f.estate_code, estate_code: f.estate_code, domain: 'Finance',
          severity: f.opex_var_pct >= 10 ? 'critical' : 'warning', detected: `OPEX +${f.opex_var_pct.toFixed(1)}% vs plan YTD` });
      }
    }
    for (const l of latest) {
      if (l.metric !== 'temp_c' && l.value < 80) {
        raw.push({ exception_key: `ENV:${l.estate_code}:${l.metric}`, estate_code: l.estate_code, domain: 'Invisible Care',
          severity: 'warning', detected: `${LABEL[l.metric]} index ${Math.round(l.value)}/100` });
      }
    }
    for (const t of s.tender) {
      if (t.status === 'Overdue') {
        raw.push({ exception_key: 'TENDER:' + t.tender_ref, estate_code: t.estate_code || 'Portfolio', domain: 'Procurement',
          severity: 'critical', detected: `${t.scope} tender overdue at ${(gate.get(t.gates_passed) || 'scoping').toLowerCase()}` });
      }
    }
    const vw_exceptions = raw.map((x) => {
      const a = actions.get(x.exception_key);
      return {
        exception_key: x.exception_key, estate_code: x.estate_code, domain: x.domain, severity: x.severity,
        cause: x.detected + (a && a.cause_note ? ' — ' + a.cause_note : ''),
        action_text: a ? a.action_text : 'No action logged — assign an owner',
        owner_team: a ? a.owner_team : 'Unassigned', action_updated_at: a ? ts(now - 2 * DAY) : null,
      };
    });

    const vw_activity = s.ingest_log.map((l) => ({
      event_id: l.event_id, source_system: l.source_system, event_type: l.event_type, estate_code: l.estate_code,
      entity_ref: l.entity_ref, detail: l.detail, ingested_at: ts(l.ingested_at),
    }));

    const SOURCES = [
      ['MRI CAFM', 'Pipeline · near-live', 15], ['IoT / Event Hub', 'Eventstream · streaming', 5],
      ['D365 HR + T&A', 'Pipeline · near-live', 60], ['D365 F&O', 'Pipeline · daily', 1440],
      ['D365 Projects', 'Pipeline · daily', 1440], ['Utility invoices', 'Manual keying (M080/M081 gap)', null],
    ];
    const vw_data_health = [];
    for (const c of s.client) {
      for (const [src, feed, cad] of SOURCES) {
        const logs = s.ingest_log.filter((l) => l.source_system === src);
        const last = logs.length ? Math.max(...logs.map((l) => l.ingested_at)) : null;
        const fresh = last == null ? null : Math.floor((now - last) / MIN);
        vw_data_health.push({
          health_key: `${c.client_code}:${src}`, source_system: src, feed, expected_cadence_min: cad,
          last_ingested_at: ts(last), events_1h: logs.filter((l) => l.ingested_at >= now - HOUR).length,
          freshness_min: fresh,
          status: cad == null ? 'No digital source' : last == null ? 'No data' : fresh <= cad ? 'Fresh' : fresh <= 3 * cad ? 'Late' : 'Stale',
        });
      }
    }

    const vw_portfolio_kpi = s.client.map((c) => {
      const planned = sum(s.roster_plan, (r) => r.planned_headcount);
      const hs = [...health.values()].map((h) => h.health_idx).filter((v) => v != null);
      let fyPlan = null, ytdPlan = null, ytdAct = null;
      if (fin.last) {
        fyPlan = sum(fin.plan, (b) => b.amount_aed);
        ytdPlan = sum(fin.plan.filter((b) => b.period <= fin.last), (b) => b.amount_aed);
        ytdAct = sum(fin.act, (a) => a.amount_aed);
      }
      return {
        client_code: c.client_code, estates: s.estate.length,
        open_orders: woTotal.open_orders, open_p1p2: woTotal.open_p1p2, backlog_30d: woTotal.backlog_30d,
        sla_pct: pct(woTotal.reactive_in_sla_30d, woTotal.reactive_closed_30d),
        ppm_completion_pct: pct(woTotal.ppm_done_90d, woTotal.ppm_due_90d),
        planned_pct: pct(woTotal.ppm_12m, woTotal.wo_12m),
        staff_on_site: hr.total.staff_on_site, planned_headcount: planned || null,
        health_idx: hs.length ? r0(avg(hs)) : null,
        last_closed_period: fin.last, opex_fy_plan_aed: fyPlan, opex_ytd_plan_aed: ytdPlan, opex_ytd_actual_aed: ytdAct,
        opex_var_pct: ytdPlan ? r1((100 * (ytdAct - ytdPlan)) / ytdPlan) : null,
        opex_annualised_aed: fin.last ? r0((ytdAct * 12) / (fin.last % 100)) : null,
        as_of: ts(now),
      };
    });

    return {
      vw_estate, vw_service_delivery, vw_invisible_care, vw_asset_mgmt, vw_finance, vw_finance_monthly,
      vw_finance_dimension, vw_hr, vw_procurement, vw_tender, vw_tender_gate, vw_works, vw_exceptions,
      vw_activity, vw_data_health, vw_portfolio_kpi,
    };
  }

  // ------------------------------------------------- OData-ish query layer
  function applyQuery(entity, rows, q) {
    let out = rows.slice();
    const keys = KEYS_BY_ENTITY[entity];
    const filter = q.get('$filter');
    if (filter) {
      const m = filter.match(/^\s*(\w+)\s+eq\s+(?:'([^']*)'|(-?\d+(?:\.\d+)?))\s*$/);
      if (!m) throw Object.assign(new Error('Unsupported $filter in emulator: ' + filter), { status: 400 });
      const v = m[2] != null ? m[2] : Number(m[3]);
      out = out.filter((r) => r[m[1]] === v);
    }
    const ob = q.get('$orderby');
    const sortBy = ob ? ob.split(',').map((p) => p.trim().split(/\s+/)) : keys.map((k) => [k, 'asc']);
    out.sort((a, b) => {
      for (const [f, dir] of sortBy) {
        const x = a[f], y = b[f];
        if (x === y) continue;
        const c = x == null ? -1 : y == null ? 1 : x < y ? -1 : 1;
        return (dir || '').toLowerCase() === 'desc' ? -c : c;
      }
      return 0;
    });
    const first = q.get('$first') ? Math.max(1, parseInt(q.get('$first'), 10)) : 100;
    const more = out.length > first;
    out = out.slice(0, first);
    const sel = q.get('$select');
    if (sel) {
      const f = sel.split(',').map((x) => x.trim());
      out = out.map((r) => Object.fromEntries(f.map((k) => [k, r[k]])));
    }
    return { value: out, more };
  }

  // ------------------------------------------------------------ simulator
  function mulberry32(a) { return function () { a |= 0; a = (a + 0x6d2b79f5) | 0; let t = Math.imul(a ^ (a >>> 15), 1 | a); t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t; return ((t ^ (t >>> 14)) >>> 0) / 4294967296; }; }
  const SLA_MIN = { 1: 30, 2: 60, 3: 240, 4: 1440 };
  const FAULTS = [
    ['AHUs & FAHUs', 31, 'AHU filter differential pressure high'], ['Water features & fountains', 18, 'fountain pump seal leak'],
    ['Irrigation systems', 16, 'irrigation zone valve fault'], ['Kitchen & F&B equipment', 14, 'cold room temperature alarm'],
    ['Elevators & escalators', 10, 'lift door sensor fault'], ['Chillers', 8, 'chiller high head-pressure trip'],
    ['Fire alarm devices', 6, 'detector fault on loop'], ['UPS systems', 4, 'UPS battery alarm'],
  ];
  const ZONES = ['Main Residence', 'Majlis & Reception', 'Guest Villas', 'Service & BOH', 'Energy Centre', 'Landscape & Water Features', 'Mobility & Fleet'];
  const MIX = [['Technical', 0.58], ['Soft services', 0.27], ['Professional', 0.11], ['Admin', 0.04]];
  const NEW_TENDERS = [
    ['Façade cleaning & rope access services', 'Soft services', 0.9], ['BMS head-end modernisation', 'Special systems', 2.4],
    ['Pest control & hygiene services', 'Soft services', 0.4], ['Generator load-bank & overhaul', 'Electrical', 0.7],
  ];

  class Emulator {
    constructor(seed, opts = {}) {
      this.now = opts.now || (() => Date.now());
      this.rng = mulberry32(opts.seed || 20261012);
      this.db = load(seed, this.now());
      this.tick = 0;
      this.seq = 900000;
      this.listeners = [];
      // equilibrium targets so the simulated estate breathes but stays recognisable
      const now = this.now();
      this.targets = {};
      for (const e of this.db.estate) {
        const wo = this.db.work_order.filter((w) => w.estate_code === e.estate_code);
        this.targets[e.estate_code] = {
          open: wo.filter((w) => OPEN.has(w.status)).length,
          p1p2: wo.filter((w) => OPEN.has(w.status) && w.priority <= 2).length,
          staff: this.db.clock_event.filter((c) => c.estate_code === e.estate_code && c.clock_out_at == null).length,
          resp: avg(wo.filter((w) => w.wo_type === 'Reactive' && w.status === 'Completed' && w.completed_at >= now - 30 * DAY)
            .map((w) => (w.responded_at - w.created_at) / MIN)) || 14,
        };
      }
      this.envBase = {};
      for (const r of this.db.sensor_reading) this.envBase[r.estate_code + '|' + r.metric] = r.value;
      this.envNow = { ...this.envBase };
      this.scripted = ['tender:T-0147'];
    }

    on(fn) { this.listeners.push(fn); }
    emit(ev) { for (const fn of this.listeners) { try { fn(ev); } catch (e) { /* listener errors never stop the feed */ } } }
    log(client, estate, source, type, ref, detail) {
      const id = (this.db.ingest_log.length ? this.db.ingest_log[this.db.ingest_log.length - 1].event_id : 0) + 1;
      const row = { event_id: id, client_code: client, estate_code: estate, source_system: source, event_type: type, entity_ref: ref, detail, ingested_at: this.now() };
      this.db.ingest_log.push(row);
      if (this.db.ingest_log.length > 600) this.db.ingest_log.splice(0, this.db.ingest_log.length - 600);
      this.emit(row);
      return row;
    }
    pickEstate() {
      const est = this.db.estate;
      const w = est.map((e) => this.targets[e.estate_code].staff + 20);
      let r = this.rng() * w.reduce((a, b) => a + b, 0);
      for (let i = 0; i < est.length; i++) { r -= w[i]; if (r <= 0) return est[i]; }
      return est[est.length - 1];
    }

    step() {
      this.tick++;
      const now = this.now();
      if (this.tick % 5 === 1) this.iot(now);
      if (this.tick % 40 === 0) {
        // same rule as ingest.housekeeping: simulated completed orders age out after 30 minutes
        this.db.work_order = this.db.work_order.filter((w) => !(w.source_ref.startsWith('WO-9') && w.status === 'Completed' && w.completed_at < now - 30 * MIN));
      }
      if (this.tick === 3 && this.scripted.length) {
        const s = this.scripted.shift();
        if (s.startsWith('tender:')) this.tenderGate(now, s.slice(7));
        return;
      }
      const r = this.rng();
      if (r < 0.70) this.mri(now);
      else if (r < 0.96) this.ta(now);
      else if (r < 0.966) this.tenderGate(now);
      else if (r < 0.976) this.heartbeat(now);
    }

    mri(now) {
      const e = this.pickEstate(), code = e.estate_code, t = this.targets[code];
      const wo = this.db.work_order.filter((w) => w.estate_code === code);
      const open = wo.filter((w) => OPEN.has(w.status));
      const p1p2 = open.filter((w) => w.priority <= 2).length;
      let cand = open.filter((w) => w.wo_type === 'Reactive' && w.status !== 'OnHold' && w.created_at >= now - 72 * HOUR);
      const complete = cand.length && (open.length > t.open || (open.length === t.open && this.rng() < 0.5));
      if (complete) {
        // keep open P1/P2 near the estate's level so the Invisible Care Index stays recognisable
        const hi = cand.filter((w) => w.priority <= 2), lo = cand.filter((w) => w.priority > 2);
        if (p1p2 > t.p1p2 && hi.length) cand = hi;
        else if (p1p2 < t.p1p2 && lo.length) cand = lo;
        const w = cand[Math.floor(this.rng() * cand.length)];
        const late = this.rng() < 0.015;
        const resp = late ? SLA_MIN[w.priority] + 12 : Math.min(SLA_MIN[w.priority] - 1, t.resp * (0.5 + this.rng()));
        w.responded_at = w.responded_at || Math.min(now, w.created_at + resp * MIN);
        w.status = 'Completed';
        w.completed_at = now;
        w.ingested_at = now;
        this.log(e.client_code, code, 'MRI CAFM', 'WO completed', w.source_ref, w.summary);
      } else {
        const f = this.fault();
        const zone = ZONES[Math.floor(this.rng() * ZONES.length)];
        const u = this.rng();
        let pr = u < 0.05 ? 1 : u < 0.20 ? 2 : u < 0.70 ? 3 : 4;
        if (p1p2 < t.p1p2 && this.rng() < 0.6) pr = this.rng() < 0.3 ? 1 : 2;
        if (p1p2 > t.p1p2 && pr <= 2) pr = 3;
        const ref = 'WO-' + String(++this.seq).padStart(6, '0');
        const row = {
          source_ref: ref, client_code: e.client_code, estate_code: code, wo_type: 'Reactive', priority: pr, status: 'Open',
          asset_class: f[0], summary: `${zone} · ${f[2]}`, created_at: now, due_at: null,
          respond_by: now + SLA_MIN[pr] * MIN, responded_at: null, completed_at: null, ingested_at: now,
        };
        this.db.work_order.push(row);
        this.log(e.client_code, code, 'MRI CAFM', 'WO raised', ref, `P${pr} · ${row.summary}`);
      }
    }
    fault() {
      let r = this.rng() * FAULTS.reduce((a, f) => a + f[1], 0);
      for (const f of FAULTS) { r -= f[1]; if (r <= 0) return f; }
      return FAULTS[0];
    }

    iot(now) {
      const per = {};
      for (const e of this.db.estate) {
        for (const metric of ['iaq', 'water_quality', 'humidity', 'fire_integrity', 'temp_c']) {
          const k = e.estate_code + '|' + metric, base = this.envBase[k];
          if (base == null) continue;
          const amp = metric === 'temp_c' ? 0.15 : 0.5;
          const v = base + 0.6 * (this.envNow[k] - base) + (this.rng() * 2 - 1) * amp;
          this.envNow[k] = v;
          const prev = this.db.sensor_reading.find((r) => r.estate_code === e.estate_code && r.metric === metric);
          this.db.sensor_reading.push({
            client_code: e.client_code, estate_code: e.estate_code, zone: prev ? prev.zone : 'Estate', metric,
            value: Math.round(v * 100) / 100, sensor_count: prev ? prev.sensor_count : 1, read_at: now, ingested_at: now,
          });
          per[e.client_code] = per[e.client_code] || { n: 0, est: new Set() };
          per[e.client_code].n++; per[e.client_code].est.add(e.estate_code);
        }
      }
      // keep the window bounded
      const cutoff = now - 30 * MIN;
      this.db.sensor_reading = this.db.sensor_reading.filter((r) => r.read_at >= cutoff);
      for (const [client, x] of Object.entries(per)) {
        this.log(client, null, 'IoT / Event Hub', 'Telemetry window', null, `${x.n} readings · ${x.est.size} estates · eventstream`);
      }
    }

    ta(now) {
      const e = this.pickEstate(), code = e.estate_code, t = this.targets[code];
      const on = this.db.clock_event.filter((c) => c.estate_code === code && c.clock_out_at == null);
      const n = 1 + Math.floor(this.rng() * 3);
      let ins = 0, outs = 0;
      if (on.length < t.staff || (on.length === t.staff && this.rng() < 0.5)) {
        for (let i = 0; i < n; i++) {
          let r = this.rng(), cat = MIX[0][0];
          for (const [c, sh] of MIX) { r -= sh; if (r <= 0) { cat = c; break; } }
          this.db.clock_event.push({ staff_ref: `S${code.slice(2)}-${5000 + Math.floor(this.rng() * 4999)}`, client_code: e.client_code,
            estate_code: code, category: cat, clock_in_at: now, clock_out_at: null });
          ins++;
        }
      } else {
        on.sort((a, b) => a.clock_in_at - b.clock_in_at);
        for (const c of on.slice(0, n)) { c.clock_out_at = now; outs++; }
      }
      this.log(e.client_code, code, 'D365 HR + T&A', 'Shift movements', null, `${ins} clock-ins · ${outs} clock-outs`);
    }

    tenderGate(now, ref) {
      const live = this.db.tender.filter((t) => t.status !== 'Completed' && t.status !== 'Overdue');
      const t = ref ? this.db.tender.find((x) => x.tender_ref === ref) : live[Math.floor(this.rng() * live.length)];
      if (!t || t.status === 'Completed') return;
      const g = t.gates_passed + 1;
      this.db.tender_gate_event.push({ tender_ref: t.tender_ref, gate_no: g, client_code: t.client_code, passed_at: now });
      t.gates_passed = g;
      t.status = g === 13 ? 'Completed' : t.status === 'At Risk' && this.rng() < 0.5 ? 'At Risk' : 'On Track';
      if (g === 11) t.awarded_at = now;
      if (g === 13) t.go_live_at = now;
      const name = this.db.procurement_gate.find((x) => x.gate_no === g).gate_name;
      this.log(t.client_code, t.estate_code, 'D365 F&O', 'Tender gate passed', t.tender_ref,
        `Passed gate ${g} · ${name} · AED ${(t.est_value_aed / 1e6).toFixed(1)}m`);
      if (g === 13) this.newTender(now, t.client_code);
    }
    newTender(now, client) {
      const est = this.db.estate.filter((e) => e.client_code === client);
      const spec = NEW_TENDERS[Math.floor(this.rng() * NEW_TENDERS.length)];
      const e = est[Math.floor(this.rng() * est.length)];
      const ref = 'T-0' + (300 + Math.floor(this.rng() * 600));
      if (this.db.tender.some((t) => t.tender_ref === ref)) return;
      this.db.tender.push({ tender_ref: ref, client_code: client, estate_code: e.estate_code, scope: spec[0], category: spec[1],
        bidders: 3 + Math.floor(this.rng() * 3), gates_passed: 0, status: 'On Track', est_value_aed: Math.round(spec[2] * 1e6),
        baseline_var_pct: 0, scoped_at: now, awarded_at: null, go_live_at: null });
      this.log(client, e.estate_code, 'D365 F&O', 'Tender registered', ref, `${spec[0]} · AED ${spec[2].toFixed(1)}m`);
    }

    heartbeat(now) {
      const src = this.rng() < 0.5 ? 'D365 F&O' : 'D365 Projects';
      for (const c of this.db.client) {
        this.log(c.client_code, null, src, 'Scheduled sync', null, src === 'D365 F&O' ? 'Ledger sync · no new postings' : 'Projects sync · stages reconciled');
      }
    }

    // ------------------------------------------------------- HTTP surface
    request(method, url, headers = {}) {
      const started = Date.now();
      const h = Object.fromEntries(Object.entries(headers).map(([k, v]) => [k.toLowerCase(), v]));
      const u = new URL(url, 'http://emulator.local');
      const reply = (status, body) => ({ status, body, ms: Date.now() - started, headers: { 'content-type': 'application/json' } });
      if (u.pathname === '/health' || u.pathname === '/') return reply(200, { status: 'Healthy', version: 'emulator', 'app-name': 'dab_oss_emulator' });
      const key = h['ocp-apim-subscription-key'];
      if (!key) return reply(401, { statusCode: 401, message: 'Access denied due to missing subscription key. Make sure to include subscription key when making requests to an API.' });
      const who = KEYS[key];
      if (!who) return reply(401, { statusCode: 401, message: 'Access denied due to invalid subscription key. Make sure to provide a valid key for an active subscription.' });
      // the gateway allows GET on /api only (nginx limit_except -> 403; APIM -> 405)
      if (method !== 'GET') return reply(403, { statusCode: 403, message: 'Read-only API: only GET is permitted on /api.' });
      // the gateway overwrites any client-supplied X-MS-CLIENT-PRINCIPAL, so a spoofed header changes nothing
      const m = u.pathname.match(/^\/api\/([A-Za-z0-9_]+)$/);
      if (!m) return reply(404, { error: { code: 'BadRequest', message: 'Invalid path', status: 404 } });
      const entity = m[1];
      if (!(entity in KEYS_BY_ENTITY)) return reply(404, { error: { code: 'EntityNotFound', message: `Invalid Entity path: ${entity}.`, status: 404 } });
      const now = this.now();
      const v = views(scope(this.db, who.client_code), now)[entity];
      try {
        const r = applyQuery(entity, v, u.searchParams);
        const body = { value: r.value };
        if (r.more) body.nextLink = u.pathname + '?$after=emulator-cursor';
        return reply(200, body);
      } catch (err) {
        return reply(err.status || 500, { error: { code: 'BadRequest', message: err.message, status: err.status || 500 } });
      }
    }
  }

  const api = { Emulator, KEYS, views, scope, load, KEYS_BY_ENTITY };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  else root.CipEmulator = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
