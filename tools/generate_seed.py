#!/usr/bin/env python3
"""
Generate the POC seed once, write it twice:

  sql/40_seed.sql          loaded into Azure SQL / SQL Server by the init job
  portal/data/seed.json    loaded by the in-browser DAB emulator

Both carry the same rows. Every timestamp is stored as "seconds before load"
so the data is always fresh relative to when it is loaded; finance is the
exception and uses fixed closed periods (FY of --as-of, closed through the
previous month), which is how a ledger behaves.

Estate figures for CL01 are calibrated to the v3 console (portfolio-
intelligence-v3.html) so the live console reads like the mock-up. CL02 is a
second, smaller client that exists to prove row-level isolation.

Usage:  python3 tools/generate_seed.py [--as-of 2026-10-12]
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import math
import random
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DAY = 86400
HOUR = 3600
MIN = 60

# --------------------------------------------------------------------------
# Reference data
# --------------------------------------------------------------------------
CLIENTS = [
    ("CL01", "Private estates portfolio · 10 assets"),
    ("CL02", "Private estates portfolio · 3 assets"),
]

# code, client, emirate, region, tier, x, y, label, status, class,
# staff, opex(FY plan AED m), var%, capex(AED m), draw, ppm%, planned%, mttr h,
# open wo, backlog, assets, health target, response min, env(iaq, water, humid, fire), temp C, condition
E = [
    ("SP11021", "CL01", "Abu Dhabi", "Abu Dhabi", 1, 395.0, 244.4, "l", "Active", "Icon",
     512, 56.0, 1.2, 22.0, .52, 98.4, 81, 3.6, 64, 5, 14820, 94, 11, (96, 98, 93, 99), 22.4, 78),
    ("SP11047", "CL01", "Abu Dhabi", "Abu Dhabi", 1, 418.7, 252.3, "br", "Active", "Icon",
     436, 47.5, -0.8, 18.5, .47, 97.9, 80, 3.9, 57, 6, 12140, 92, 12, (95, 97, 91, 99), 22.6, 77),
    ("SP11102", "CL01", "Abu Dhabi", "Abu Dhabi", 2, 308.5, 286.1, "bl", "Dormant", "Residential",
     242, 26.5, 2.1, 9.5, .55, 97.1, 77, 4.4, 38, 4, 7420, 90, 14, (93, 96, 90, 98), 22.9, 75),
    ("SP11136", "CL01", "Abu Dhabi", "Abu Dhabi", 2, 551.5, 272.6, "bl", "Active", "Residential",
     198, 22.0, 7.3, 8.0, .61, 94.2, 71, 5.8, 47, 11, 6380, 81, 17, (88, 95, 78.6, 97), 23.6, 64),
    ("SP11158", "CL01", "Abu Dhabi", "Abu Dhabi", 2, 409.3, 289.5, "b", "Dormant", "Residential",
     176, 19.5, -1.4, 7.0, .49, 97.6, 78, 4.1, 29, 3, 5910, 91, 13, (94, 97, 92, 99), 22.5, 76),
    ("SP11203", "CL01", "Abu Dhabi", "Abu Dhabi", 3, 320.4, 396.7, "r", "Dormant", "Residential",
     96, 11.0, 0.6, 3.8, .50, 96.8, 76, 4.8, 18, 2, 3240, 89, 15, (92, 96, 88, 98), 23.1, 74),
    ("SP11247", "CL01", "Abu Dhabi", "Abu Dhabi", 3, 435.3, 229.7, "tr", "Active", "Residential",
     88, 9.8, -2.2, 3.2, .44, 98.1, 79, 3.8, 14, 1, 2980, 93, 12, (95, 98, 92, 99), 22.3, 79),
    ("SP21014", "CL01", "Dubai", "Northern Emirates", 2, 501.7, 165.4, "r", "Active", "Icon",
     214, 24.5, 1.8, 9.0, .53, 97.3, 78, 4.3, 33, 4, 6890, 90, 13, (93, 97, 90, 98), 22.8, 75),
    ("SP31009", "CL01", "Ras Al Khaimah", "Northern Emirates", 3, 578.7, 101.1, "l", "Dormant", "Residential",
     72, 8.2, 0.9, 2.8, .46, 96.4, 75, 5.1, 16, 3, 2410, 87, 16, (91, 95, 86, 98), 23.0, 73),
    ("SP41012", "CL01", "Fujairah", "Northern Emirates", 3, 622.6, 171.0, "b", "Dormant", "Residential",
     78, 8.8, -0.5, 3.0, .48, 97.0, 76, 4.6, 15, 2, 2650, 88, 15, (92, 96, 85, 99), 23.2, 75),
    # CL02 - second client, exists to prove isolation
    ("SP51003", "CL02", "Abu Dhabi", "Abu Dhabi", 2, 536.0, 318.0, "r", "Active", "Residential",
     164, 17.2, 2.6, 6.0, .41, 96.1, 74, 4.9, 31, 4, 5120, 84, 15, (91, 95, 78.2, 98), 23.4, 70),
    ("SP51017", "CL02", "Dubai", "Northern Emirates", 3, 486.0, 183.0, "l", "Active", "Residential",
     82, 9.1, -1.1, 3.1, .52, 97.4, 77, 4.4, 17, 2, 2760, 91, 13, (93, 96, 90, 99), 22.7, 76),
    ("SP51029", "CL02", "Sharjah", "Northern Emirates", 3, 521.0, 146.0, "tr", "Dormant", "Residential",
     70, 7.4, 5.6, 2.6, .37, 96.6, 76, 4.7, 15, 2, 2200, 87, 14, (92, 95, 88, 98), 22.9, 72),
]
KEYS = ["code", "client", "emirate", "region", "tier", "x", "y", "lab", "status", "cls",
        "staff", "opex", "var", "capex", "draw", "ppm", "planned", "mttr",
        "wo", "backlog", "assets", "health", "resp", "env", "temp", "cond"]
ESTATES = [dict(zip(KEYS, row)) for row in E]

INDEX_WEIGHTS = [
    ("environmental", 0.40, "IAQ, water quality, humidity, fire integrity (pending SME sign-off, M011)"),
    ("ppm_compliance", 0.30, "Rolling 90-day PPM completion"),
    ("critical_wo", 0.20, "Open P1/P2 per 1,000 tagged assets"),
    ("asset_condition", 0.10, "Validated condition index"),
]

GATES = ["Scope of Work", "Bidders Identified", "Client Pre-Approval", "Tender Launched", "Site Visits",
         "Technical Evaluation", "Commercial Evaluation", "Internal Approval", "Client Approval",
         "Award Recommendation", "Letter of Award", "Contract Finalised", "Go-Live / Stabilised"]
PROJECT_STAGES = ["Scope Defined", "Scope Approved by Client", "Commercial Proposal Submitted",
                  "Commercial Approved by Client", "Mobilisation", "Works in Progress", "QA & Snagging", "Completed"]
ONDEMAND_STAGES = ["Reported", "Assigned", "In Progress", "Completed"]

ZONES = ["Main Residence", "Majlis & Reception", "Guest Villas", "Service & BOH",
         "Energy Centre", "Landscape & Water Features", "Mobility & Fleet"]
FAULTS = [  # asset class, weight, reactive fault text
    ("AHUs & FAHUs", 31, "AHU filter differential pressure high"),
    ("Water features & fountains", 18, "fountain pump seal leak"),
    ("Irrigation systems", 16, "irrigation zone valve fault"),
    ("Kitchen & F&B equipment", 14, "cold room temperature alarm"),
    ("Elevators & escalators", 10, "lift door sensor fault"),
    ("Chillers", 8, "chiller high head-pressure trip"),
    ("Fire alarm devices", 6, "detector fault on loop"),
    ("UPS systems", 4, "UPS battery alarm"),
]
SLA_MIN = {1: 30, 2: 60, 3: 240, 4: 1440}
STAFF_MIX = [("Technical", .58), ("Soft services", .27), ("Professional", .11), ("Admin", .04)]
COST_DIMS = ["Manpower", "Materials", "Subcontracts", "Utilities", "Overheads"]
# v3 cost-dimension YTD plan / actual (AED m) - drives dimension shares and overruns
COSTDIM_V3 = {"Manpower": (76.0, 77.1), "Materials": (16.6, 17.4), "Subcontracts": (24.8, 26.1),
              "Utilities": (15.2, 14.6), "Overheads": (5.4, 4.3)}
# v3 portfolio OPEX by month (AED m)
OPEX_PLAN = [19.0, 18.4, 19.6, 19.2, 19.8, 20.6, 21.4, 21.8, 20.2, 19.6, 19.4, 19.8]
OPEX_ACT = [18.7, 18.9, 19.4, 19.8, 20.1, 20.9, 21.7]          # Jan-Jul; later closed months at k=1

TENDERS = [  # ref, client, estate, scope, category, bidders, gates passed, status, value AED m, baseline var
    ("T-0131", "CL01", "SP11021", "Specialist landscape & irrigation services", "Landscaping", 5, 11, "On Track", 4.4, 4.0),
    ("T-0138", "CL01", "SP11047", "Security systems integration (ELV)", "Security", 4, 6, "At Risk", 3.2, -3.0),
    ("T-0112", "CL01", None, "Lift maintenance AMC consolidation", "Vertical transport", 3, 13, "Completed", 2.0, 5.0),
    ("T-0152", "CL01", "SP11136", "Chiller plant replacement works", "HVAC works", 6, 4, "On Track", 1.1, 0.0),
    ("T-0141", "CL01", "SP11102", "Fire & life safety systems upgrade", "FLS", 5, 7, "Overdue", 3.6, 8.0),
    ("T-0147", "CL01", "SP31009", "Waste management services", "Environmental", 4, 5, "On Track", 0.8, -2.0),
    ("T-0203", "CL02", "SP51003", "MEP maintenance AMC renewal", "Hard FM", 4, 8, "On Track", 2.6, 1.0),
    ("T-0209", "CL02", "SP51017", "Pool & water feature services", "Water features", 3, 3, "At Risk", 0.6, -1.0),
]

WORKS = [  # ref, client, estate, name, type, stages done, status, value AED, resolution days if done
    ("PRJ-0201", "CL01", "SP11021", "Majlis wing refurbishment", "Project", 6, "On Track", 680000, None),
    ("PRJ-0207", "CL01", "SP11047", "Water feature renewal — principal courtyard", "Project", 7, "At Risk", 350000, None),
    ("PRJ-0188", "CL01", "SP11158", "Roof waterproofing replacement", "Project", 8, "Completed", 1140000, 96),
    ("PRJ-0214", "CL01", "SP11136", "Perimeter security enhancement", "Project", 2, "On Track", 240000, None),
    ("OD-1102", "CL01", "SP11021", "EV charging bays", "On-Demand", 4, "Completed", 33000, 16),
    ("OD-1109", "CL01", "SP11102", "CCTV camera additions", "On-Demand", 3, "On Track", 15000, None),
    ("OD-1113", "CL01", "SP41012", "Entrance signage upgrade", "On-Demand", 2, "Overdue", 11000, None),
    ("OD-1117", "CL01", "SP11047", "Staff cycle store", "On-Demand", 1, "On Track", 26000, None),
    ("OD-1094", "CL01", "SP11203", "External lighting upgrade", "On-Demand", 4, "Completed", 18000, 19),
    ("PRJ-0302", "CL02", "SP51003", "Guest villa MEP upgrade", "Project", 5, "On Track", 420000, None),
    ("OD-1201", "CL02", "SP51029", "Gate barrier replacement", "On-Demand", 2, "On Track", 22000, None),
]

EXCEPTION_ACTIONS = [  # key, client, cause note, action, owner
    ("OPEX:SP11136", "CL01", "unplanned chiller-bank replacement (AED 1.9m) brought forward from FY27",
     "Recovery plan active from month 8 · variance closes to +3% by year end", "Asset Finance"),
    ("ENV:SP11136:humidity", "CL01", "majlis wing dehumidification underperforming in peak season",
     "Remediation in progress · desiccant units on site · ETA 3 weeks", "Hard FM"),
    ("TENDER:T-0141", "CL01", "12 days behind milestone",
     "Escalated to procurement committee · revised award date within 3 weeks", "Procurement"),
    ("OPEX:SP51029", "CL02", "gate automation and access-control spares above plan",
     "Spares call-off renegotiated · variance reviewed monthly", "Asset Finance"),
    # ENV:SP51003:humidity deliberately has no action -> shows "No action logged"
]


# --------------------------------------------------------------------------
def tri(rng: random.Random, lo: float, hi: float, mode: float) -> float:
    return rng.triangular(lo, hi, mode)


def pick_fault(rng: random.Random):
    total = sum(w for _, w, _ in FAULTS)
    r = rng.uniform(0, total)
    for cls, w, text in FAULTS:
        r -= w
        if r <= 0:
            return cls, text
    return FAULTS[-1][0], FAULTS[-1][2]


def pick_priority(rng: random.Random) -> int:
    r = rng.random()
    return 1 if r < .05 else 2 if r < .20 else 3 if r < .70 else 4


def health_open_p1p2(e) -> int:
    """Open P1/P2 count that lands the Invisible Care Index on the v3 value."""
    env = sum(e["env"]) / 4
    w = {k: v for k, v, _ in INDEX_WEIGHTS}
    rest = w["environmental"] * env + w["ppm_compliance"] * e["ppm"] + w["asset_condition"] * e["cond"]
    crit = max(0.0, min(100.0, (e["health"] - rest) / w["critical_wo"]))
    return max(0, round((100 - crit) * e["assets"] / 1000 / 20))


# --------------------------------------------------------------------------
def build(as_of: dt.date):
    T: dict[str, list[dict]] = {k: [] for k in [
        "client", "estate", "index_weight", "procurement_gate", "work_stage", "work_order",
        "sensor_reading", "tender", "tender_gate_event", "clock_event", "roster_plan", "gl_actual",
        "budget", "capex_programme", "asset_condition", "work_item", "exception_action", "ingest_log"]}

    for code, label in CLIENTS:
        T["client"].append({"client_code": code, "portfolio_label": label})
    for e in ESTATES:
        T["estate"].append({
            "estate_code": e["code"], "client_code": e["client"], "emirate": e["emirate"],
            "region": e["region"], "tier": e["tier"], "status_label": e["status"], "class_label": e["cls"],
            "map_x": e["x"], "map_y": e["y"], "label_pos": e["lab"], "managed_since": 2025})
    for comp, w, note in INDEX_WEIGHTS:
        T["index_weight"].append({"component": comp, "weight": w, "note": note})
    for i, g in enumerate(GATES, 1):
        T["procurement_gate"].append({"gate_no": i, "gate_name": g})
    for i, s in enumerate(PROJECT_STAGES, 1):
        T["work_stage"].append({"item_type": "Project", "stage_no": i, "stage_name": s})
    for i, s in enumerate(ONDEMAND_STAGES, 1):
        T["work_stage"].append({"item_type": "On-Demand", "stage_no": i, "stage_name": s})

    seq = 4000
    sla_misses = {"SP11136": 1, "SP11021": 1, "SP51003": 1}

    for e in ESTATES:
        rng = random.Random("wo-" + e["code"])
        code, client = e["code"], e["client"]

        def wo(**kw):
            nonlocal seq
            seq += 1
            row = {"source_ref": f"WO-{seq:06d}", "client_code": client, "estate_code": code,
                   "asset_class": None, "summary": None, "due_s": None, "respond_by_s": None,
                   "responded_s": None, "completed_s": None}
            row.update(kw)
            T["work_order"].append(row)
            return row

        n_ppm = round(e["staff"] * 0.9)                       # PPM due in the last 90 days
        n_done = round(n_ppm * e["ppm"] / 100)
        n_overdue = n_ppm - n_done
        n_p1p2 = health_open_p1p2(e)
        n_or = max(round(e["wo"] * 0.45), n_p1p2 + 2)         # open reactive
        n_fp = e["wo"] - n_overdue - n_or                     # open future PPM
        if n_fp < 0:
            n_or += n_fp
            n_fp = 0
        ppm_total_12m = n_ppm + n_fp
        reactive_total_12m = round(ppm_total_12m * (100 - e["planned"]) / e["planned"])
        n_rc = max(10, reactive_total_12m - n_or)             # reactive completed, last 90 days

        # completed PPM
        for _ in range(n_done):
            cls, _t = pick_fault(rng)
            zone = rng.choice(ZONES)
            due = rng.randint(1 * DAY, 89 * DAY)
            done_at = max(10 * MIN, due + rng.randint(-1 * DAY, 2 * DAY))
            wo(wo_type="PPM", priority=3, status="Completed", asset_class=cls,
               summary=f"{zone} · {cls} planned maintenance (SFG20)",
               created_s=due + 7 * DAY, due_s=due, completed_s=done_at)

        # overdue PPM (open). The first ones are old enough to count as backlog.
        backlog_left = e["backlog"]
        for i in range(n_overdue):
            cls, _t = pick_fault(rng)
            zone = rng.choice(ZONES)
            if backlog_left > 0:
                due = rng.randint(25 * DAY, 55 * DAY)
                backlog_left -= 1
            else:
                due = rng.randint(1 * DAY, 20 * DAY)
            wo(wo_type="PPM", priority=3, status="Open", asset_class=cls,
               summary=f"{zone} · {cls} planned maintenance (SFG20)",
               created_s=due + 7 * DAY, due_s=due)

        # open reactive: P1/P2 first, backlog extras on hold, most raised today
        for i in range(n_or):
            cls, text = pick_fault(rng)
            zone = rng.choice(ZONES)
            pr = rng.choice([1, 2, 2]) if i < n_p1p2 else rng.choice([3, 3, 4])
            if backlog_left > 0 and i >= n_p1p2:
                created = rng.randint(31 * DAY, 70 * DAY)
                status = "OnHold"
                backlog_left -= 1
            elif i >= n_p1p2 and rng.random() < 0.25:
                created = rng.randint(1 * DAY, 26 * DAY)
                status = "OnHold"
            else:
                created = rng.randint(5 * MIN, 9 * HOUR)
                status = rng.choice(["Open", "InProgress"])
            responded = None
            if status != "Open":
                responded = max(0, created - rng.randint(4 * MIN, 25 * MIN))
            wo(wo_type="Reactive", priority=pr, status=status, asset_class=cls,
               summary=f"{zone} · {text}", created_s=created,
               respond_by_s=created - SLA_MIN[pr] * MIN, responded_s=responded)

        # open future PPM
        for _ in range(n_fp):
            cls, _t = pick_fault(rng)
            zone = rng.choice(ZONES)
            created = rng.randint(1 * HOUR, 6 * DAY)
            due = -rng.randint(1 * DAY, 14 * DAY)               # in the future
            wo(wo_type="PPM", priority=3, status="Open", asset_class=cls,
               summary=f"{zone} · {cls} planned maintenance (SFG20)", created_s=created, due_s=due)

        # completed reactive over the last 90 days
        misses = sla_misses.get(code, 0)
        recent = []
        for i in range(n_rc):
            cls, text = pick_fault(rng)
            zone = rng.choice(ZONES)
            pr = pick_priority(rng)
            created = rng.randint(6 * HOUR, 90 * DAY)
            resp_min = e["resp"] * tri(rng, 0.45, 1.9, 0.8) / 1.05
            resp_min = min(resp_min, SLA_MIN[pr] - 1)
            repair_h = max(resp_min / 60 + 0.4, e["mttr"] * tri(rng, 0.35, 2.3, 0.8) / 1.15)
            row = wo(wo_type="Reactive", priority=pr, status="Completed", asset_class=cls,
                     summary=f"{zone} · {text}", created_s=created,
                     respond_by_s=created - SLA_MIN[pr] * MIN,
                     responded_s=created - round(resp_min * MIN),
                     completed_s=max(60, created - round(repair_h * HOUR)))
            if pr <= 2 and row["completed_s"] < 28 * DAY and row["created_s"] > SLA_MIN[pr] * MIN + 3 * HOUR:
                recent.append(row)
        for row in recent[:misses]:                           # deliberate SLA breaches
            pr_sla = (row["created_s"] - row["respond_by_s"])
            row["responded_s"] = row["created_s"] - pr_sla - 15 * MIN
            row["completed_s"] = min(row["completed_s"], row["responded_s"] - 30 * MIN)

        # --- telemetry: three 5-minute windows per metric
        rng = random.Random("iot-" + code)
        sensors = round(e["assets"] * 0.045)
        split = {"iaq": .35, "water_quality": .15, "humidity": .25, "fire_integrity": .20, "temp_c": .05}
        bases = dict(zip(["iaq", "water_quality", "humidity", "fire_integrity"], e["env"]))
        bases["temp_c"] = e["temp"]
        for metric, base in bases.items():
            for off in (11 * MIN, 6 * MIN, 1 * MIN):
                jitter = rng.uniform(-0.3, 0.3) if metric != "temp_c" else rng.uniform(-0.2, 0.2)
                T["sensor_reading"].append({
                    "client_code": client, "estate_code": code,
                    "zone": "Majlis & Reception" if metric == "temp_c" else "Estate",
                    "metric": metric, "value": round(base + jitter, 2),
                    "sensor_count": max(1, round(sensors * split[metric])), "read_s": off})

        # --- people on site + roster
        rng = random.Random("ta-" + code)
        n = 0
        for cat, share in STAFF_MIX:
            on_site = round(e["staff"] * share)
            T["roster_plan"].append({"estate_code": code, "category": cat, "client_code": client,
                                     "planned_headcount": round(on_site / 0.985)})
            for _ in range(on_site):
                n += 1
                T["clock_event"].append({
                    "staff_ref": f"S{code[2:]}-{n:04d}", "client_code": client, "estate_code": code,
                    "category": cat, "clock_in_s": rng.randint(20 * MIN, 7 * HOUR + 30 * MIN), "clock_out_s": None})

        # --- asset condition summary
        T["asset_condition"].append({
            "estate_code": code, "client_code": client, "assets_tagged": e["assets"],
            "condition_idx": e["cond"], "good_fair_pct": min(97, e["health"] + 3),
            "critical_monitored": round(e["assets"] * 0.06), "beyond_life": round(e["assets"] * 0.031),
            "surveyed_s": random.Random("cs-" + code).randint(30, 120) * DAY})

        # --- capex
        T["capex_programme"].append({
            "estate_code": code, "fy": as_of.year, "client_code": client,
            "budget_aed": round(e["capex"] * 1e6), "drawn_aed": round(e["capex"] * e["draw"] * 1e6)})

    build_finance(T, as_of)

    # --- tenders and gate history
    for ref, client, estate, scope, cat, bidders, p, status, value, base in TENDERS:
        rng = random.Random("t-" + ref)
        if p == 13:
            go_live = 20 * DAY
            step = 181 * DAY / 13
            passed = {g: round(go_live + (13 - g) * step) for g in range(1, 14)}
            scoped = go_live + 181 * DAY
        else:
            last = rng.randint(2, 6) * DAY
            passed = {g: last + (p - g) * 14 * DAY + rng.randint(0, 2 * DAY) for g in range(1, p + 1)}
            scoped = (passed[1] if p else last) + 5 * DAY
        for g, s in passed.items():
            T["tender_gate_event"].append({"tender_ref": ref, "gate_no": g, "client_code": client, "passed_s": s})
        T["tender"].append({
            "tender_ref": ref, "client_code": client, "estate_code": estate, "scope": scope, "category": cat,
            "bidders": bidders, "gates_passed": p, "status": status, "est_value_aed": round(value * 1e6),
            "baseline_var_pct": base, "scoped_s": scoped,
            "awarded_s": passed.get(11), "go_live_s": passed.get(13)})

    for ref, client, estate, name, typ, done, status, value, res_days in WORKS:
        rng = random.Random("w-" + ref)
        stages = len(PROJECT_STAGES if typ == "Project" else ONDEMAND_STAGES)
        if res_days is not None:
            completed = rng.randint(3, 25) * DAY
            reported = completed + res_days * DAY
        else:
            completed = None
            reported = (done + 1) * (9 if typ == "Project" else 5) * DAY + rng.randint(0, 4) * DAY
        T["work_item"].append({
            "item_ref": ref, "client_code": client, "estate_code": estate, "item_name": name, "item_type": typ,
            "stages_done": min(done, stages), "status": status, "value_aed": value,
            "reported_s": reported, "completed_s": completed})

    for key, client, note, action, owner in EXCEPTION_ACTIONS:
        T["exception_action"].append({"exception_key": key, "client_code": client, "cause_note": note,
                                      "action_text": action, "owner_team": owner})

    # --- ingest log so data health and the activity feed start populated
    for client, _ in CLIENTS:
        est = [e["code"] for e in ESTATES if e["client"] == client]
        rng = random.Random("log-" + client)
        recent_wo = [w for w in T["work_order"] if w["client_code"] == client and w["status"] == "Completed"
                     and w["wo_type"] == "Reactive"]
        recent_wo.sort(key=lambda w: w["completed_s"])
        for w in recent_wo[:4]:
            T["ingest_log"].append({"client_code": client, "estate_code": w["estate_code"],
                                    "source_system": "MRI CAFM", "event_type": "WO completed",
                                    "entity_ref": w["source_ref"], "detail": w["summary"],
                                    "ingested_s": rng.randint(2, 14) * MIN})
        T["ingest_log"] += [
            {"client_code": client, "estate_code": None, "source_system": "IoT / Event Hub",
             "event_type": "Telemetry window", "entity_ref": None,
             "detail": f"{len(est) * 5} readings · {len(est)} estates · eventstream", "ingested_s": 60},
            {"client_code": client, "estate_code": None, "source_system": "D365 HR + T&A",
             "event_type": "Shift movements", "entity_ref": None,
             "detail": "Day shift roll-call reconciled", "ingested_s": 18 * MIN},
            {"client_code": client, "estate_code": None, "source_system": "D365 F&O",
             "event_type": "Scheduled sync", "entity_ref": None,
             "detail": "Daily ledger sync · 06:00 GST", "ingested_s": 5 * HOUR + rng.randint(0, 40) * MIN},
            {"client_code": client, "estate_code": None, "source_system": "D365 Projects",
             "event_type": "Scheduled sync", "entity_ref": None,
             "detail": "Daily projects sync", "ingested_s": 6 * HOUR + rng.randint(0, 40) * MIN},
        ]
    T["ingest_log"].sort(key=lambda r: -r["ingested_s"])     # oldest first -> ascending event ids
    return T


def build_finance(T, as_of: dt.date):
    fy = as_of.year
    last_closed = as_of.month - 1 if as_of.month > 1 else 12
    if as_of.month == 1:
        fy -= 1
    ytd_plan = sum(v[0] for v in COSTDIM_V3.values())
    ytd_act = sum(v[1] for v in COSTDIM_V3.values())
    dim_share = {d: COSTDIM_V3[d][0] / ytd_plan for d in COST_DIMS}
    dim_g = {d: (COSTDIM_V3[d][1] / COSTDIM_V3[d][0]) / (ytd_act / ytd_plan) for d in COST_DIMS}

    for client, _ in CLIENTS:
        est = [e for e in ESTATES if e["client"] == client]
        total_fy = sum(e["opex"] for e in est)
        if client == "CL01":
            plan_m = OPEX_PLAN
        else:
            plan_m = [v / sum(OPEX_PLAN) * total_fy for v in OPEX_PLAN]
        weights = {e["code"]: e["opex"] / total_fy for e in est}
        for m in range(12):
            month_plan = plan_m[m] * 1e6
            # actual_i,d = plan_i,d x (1 + estate variance) x month factor k x dimension factor g_d
            # k pins CL01's monthly portfolio actuals to the v3 series; g_d reproduces the v3
            # cost-dimension overruns without changing any total.
            raw = sum(month_plan * weights[e["code"]] * (1 + e["var"] / 100) for e in est)
            k = OPEX_ACT[m] * 1e6 / raw if (client == "CL01" and m < len(OPEX_ACT)) else 1.0
            period = fy * 100 + m + 1
            for e in est:
                for d in COST_DIMS:
                    plan = month_plan * weights[e["code"]] * dim_share[d]
                    T["budget"].append({"estate_code": e["code"], "period": period, "cost_dimension": d,
                                        "client_code": client, "amount_aed": round(plan)})
                    if m + 1 <= last_closed:
                        act = plan * (1 + e["var"] / 100) * k * dim_g[d]
                        T["gl_actual"].append({"estate_code": e["code"], "period": period, "cost_dimension": d,
                                               "client_code": client, "amount_aed": round(act)})


# --------------------------------------------------------------------------
# Writers
# --------------------------------------------------------------------------
TIME_COLS = {  # json key -> sql column
    "due_s": "due_at", "respond_by_s": "respond_by", "responded_s": "responded_at", "completed_s": "completed_at",
    "created_s": "created_at", "read_s": "read_at", "passed_s": "passed_at", "scoped_s": "scoped_at",
    "awarded_s": "awarded_at", "go_live_s": "go_live_at", "clock_in_s": "clock_in_at", "clock_out_s": "clock_out_at",
    "surveyed_s": "surveyed_at", "reported_s": "reported_at", "ingested_s": "ingested_at",
}
SQL_TABLE = {
    "client": "core.client", "estate": "core.estate", "index_weight": "core.index_weight",
    "procurement_gate": "core.procurement_gate", "work_stage": "core.work_stage",
    "work_order": "silver.work_order", "sensor_reading": "silver.sensor_reading", "tender": "silver.tender",
    "tender_gate_event": "silver.tender_gate_event", "clock_event": "silver.clock_event",
    "roster_plan": "silver.roster_plan", "gl_actual": "silver.gl_actual", "budget": "silver.budget",
    "capex_programme": "silver.capex_programme", "asset_condition": "silver.asset_condition",
    "work_item": "silver.work_item", "exception_action": "silver.exception_action",
    "ingest_log": "silver.ingest_log",
}
ORDER = ["client", "estate", "index_weight", "procurement_gate", "work_stage", "asset_condition",
         "work_order", "sensor_reading", "tender", "tender_gate_event", "roster_plan", "clock_event",
         "budget", "gl_actual", "capex_programme", "work_item", "exception_action", "ingest_log"]


def sql_lit(v):
    if v is None:
        return "NULL"
    if isinstance(v, bool):
        return "1" if v else "0"
    if isinstance(v, (int,)):
        return str(v)
    if isinstance(v, float):
        return repr(round(v, 4))
    return "N'" + str(v).replace("'", "''") + "'"


def write_sql(T, path: Path, as_of: dt.date):
    out = [
        "-- =============================================================================",
        "-- 40 · seed data  (GENERATED by tools/generate_seed.py - do not edit by hand)",
        f"-- Generated for as-of {as_of.isoformat()}. Event timestamps are relative to load",
        "-- time (seconds before SYSUTCDATETIME()); finance uses fixed closed periods.",
        "-- =============================================================================",
        "SET NOCOUNT ON;",
        "SET XACT_ABORT ON;",
        "DECLARE @now datetime2(3) = SYSUTCDATETIME();",
        "BEGIN TRANSACTION;",
        "",
    ]
    for name in ORDER:
        rows = T[name]
        if not rows:
            continue
        keys = list(rows[0].keys())
        cols = [TIME_COLS.get(k, k) for k in keys]
        sel = []
        for k, c in zip(keys, cols):
            if k in TIME_COLS:
                sel.append(f"DATEADD(second, -v.{k}, @now)")
            else:
                sel.append(f"v.{k}")
        for i in range(0, len(rows), 400):
            chunk = rows[i:i + 400]
            out.append(f"INSERT {SQL_TABLE[name]} ({', '.join(cols)})")
            out.append(f"SELECT {', '.join(sel)}")
            out.append("FROM (VALUES")
            vals = [" (" + ", ".join(sql_lit(r[k]) for k in keys) + ")" for r in chunk]
            out.append(",\n".join(vals))
            out.append(f") AS v ({', '.join(keys)});")
            out.append("")
    out += ["COMMIT TRANSACTION;", "GO", ""]
    path.write_text("\n".join(out), encoding="utf-8")


def write_json(T, path: Path, as_of: dt.date):
    doc = {"generated_for": as_of.isoformat(),
           "note": "Same rows as sql/40_seed.sql. Keys ending _s are seconds before load time.",
           "tables": {}}
    for name in ORDER:
        rows = T[name]
        keys = list(rows[0].keys())
        doc["tables"][name] = {"cols": keys, "rows": [[r[k] for k in keys] for r in rows]}
    path.write_text(json.dumps(doc, separators=(",", ":"), ensure_ascii=False), encoding="utf-8")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--as-of", default="2026-10-12")
    a = ap.parse_args()
    as_of = dt.date.fromisoformat(a.as_of)
    T = build(as_of)
    write_sql(T, ROOT / "sql" / "40_seed.sql", as_of)
    (ROOT / "portal" / "data").mkdir(parents=True, exist_ok=True)
    write_json(T, ROOT / "portal" / "data" / "seed.json", as_of)
    print("rows:", {k: len(v) for k, v in T.items()})


if __name__ == "__main__":
    main()
