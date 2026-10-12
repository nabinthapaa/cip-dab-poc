#!/usr/bin/env python3
"""
CIP source-event simulator - stands in for the ingestion layer.

In Azure, Fabric pipelines and an eventstream land MRI CAFM, D365 and IoT
changes into silver. Here this process does it, through exactly the same
ingest.* stored procedures and as the same least-privilege identity
(cip_ingest), so nothing downstream can tell the difference.

Events (one per tick, plus a telemetry window every 5th tick):
  MRI CAFM      reactive work order raised / completed (keeps each estate
                near its starting open count so the console stays recognisable)
  D365 HR+T&A   clock-ins / clock-outs around the roster plan
  D365 F&O      tender passes its next stage-gate; new tender when one completes
  IoT           environmental indices, mean-reverting around each estate's level
  heartbeat     daily-pipeline "no new postings" syncs for data-health

The first tender event is T-0147 passing gate 6 (Technical Evaluation) - the
same event the architecture animation traces.
"""
from __future__ import annotations

import datetime as dt
import json
import logging
import os
import random
import signal
import sys
import time

import pymssql

log = logging.getLogger("simulator")
OPEN = ("Open", "InProgress", "OnHold")
SLA_MIN = {1: 30, 2: 60, 3: 240, 4: 1440}
FAULTS = [
    ("AHUs & FAHUs", 31, "AHU filter differential pressure high"),
    ("Water features & fountains", 18, "fountain pump seal leak"),
    ("Irrigation systems", 16, "irrigation zone valve fault"),
    ("Kitchen & F&B equipment", 14, "cold room temperature alarm"),
    ("Elevators & escalators", 10, "lift door sensor fault"),
    ("Chillers", 8, "chiller high head-pressure trip"),
    ("Fire alarm devices", 6, "detector fault on loop"),
    ("UPS systems", 4, "UPS battery alarm"),
]
ZONES = ["Main Residence", "Majlis & Reception", "Guest Villas", "Service & BOH",
         "Energy Centre", "Landscape & Water Features", "Mobility & Fleet"]
MIX = [("Technical", .58), ("Soft services", .27), ("Professional", .11), ("Admin", .04)]
METRICS = ["iaq", "water_quality", "humidity", "fire_integrity", "temp_c"]
NEW_TENDERS = [
    ("Façade cleaning & rope access services", "Soft services", 0.9),
    ("BMS head-end modernisation", "Special systems", 2.4),
    ("Pest control & hygiene services", "Soft services", 0.4),
    ("Generator load-bank & overhaul", "Electrical", 0.7),
]


def utcnow() -> dt.datetime:
    return dt.datetime.now(dt.timezone.utc).replace(tzinfo=None, microsecond=0)


def connect():
    for attempt in range(60):
        try:
            conn = pymssql.connect(
                server=os.environ.get("SQL_SERVER", "sql"),
                user=os.environ.get("SQL_USER", "cip_ingest"),
                password=os.environ["SQL_PASSWORD"],
                database=os.environ.get("SQL_DATABASE", "cip"),
                autocommit=True, tds_version="7.4", charset="UTF-8", login_timeout=10)
            log.info("connected as %s", os.environ.get("SQL_USER", "cip_ingest"))
            return conn
        except pymssql.Error as e:  # SQL still starting
            log.warning("waiting for database (%s)", str(e).splitlines()[0][:120])
            time.sleep(min(2 + attempt, 10))
    sys.exit("could not connect to the database")


class Simulator:
    def __init__(self, conn, rng: random.Random):
        self.c = conn
        self.rng = rng
        self.tick = 0
        cur = self.cur()
        cur.execute("SELECT estate_code, client_code FROM core.estate ORDER BY estate_code")
        self.estates = [{"code": r[0], "client": r[1]} for r in cur.fetchall()]
        self.clients = sorted({e["client"] for e in self.estates})
        self.t = {}
        for e in self.estates:
            code = e["code"]
            cur.execute("""
                SELECT COUNT(*), SUM(CASE WHEN priority <= 2 THEN 1 ELSE 0 END)
                FROM silver.work_order WHERE estate_code = %s AND status IN ('Open','InProgress','OnHold')""", (code,))
            open_n, p1p2 = cur.fetchone()
            cur.execute("""
                SELECT AVG(CAST(DATEDIFF(second, created_at, responded_at) AS float)) / 60.0
                FROM silver.work_order
                WHERE estate_code = %s AND wo_type = 'Reactive' AND status = 'Completed'
                  AND completed_at >= DATEADD(day, -30, SYSUTCDATETIME())""", (code,))
            resp = cur.fetchone()[0] or 14.0
            cur.execute("SELECT ISNULL(SUM(planned_headcount), 0) FROM silver.roster_plan WHERE estate_code = %s", (code,))
            plan = cur.fetchone()[0]
            self.t[code] = {"open": open_n, "p1p2": p1p2 or 0, "resp": resp, "staff": round(plan * 0.985)}
        # environmental base = recent average per estate/metric; the walk reverts to it
        cur.execute("""
            SELECT estate_code, metric, AVG(value), MAX(sensor_count), MAX(zone)
            FROM silver.sensor_reading
            WHERE read_at >= DATEADD(minute, -30, (SELECT MAX(read_at) FROM silver.sensor_reading))
            GROUP BY estate_code, metric""")
        self.env_base, self.env_meta = {}, {}
        for code, metric, v, n, zone in cur.fetchall():
            self.env_base[(code, metric)] = float(v)
            self.env_meta[(code, metric)] = (int(n), zone)
        self.env_now = dict(self.env_base)
        cur.execute("SELECT MAX(source_ref) FROM silver.work_order WHERE source_ref LIKE 'WO-9%'")
        last = cur.fetchone()[0]
        self.seq = int(last[3:]) if last else 900000
        cur.execute("SELECT gates_passed FROM silver.tender WHERE tender_ref = 'T-0147'")
        row = cur.fetchone()
        self.scripted = ["T-0147"] if row and row[0] == 5 else []
        log.info("loaded %d estates for %s; equilibrium targets set", len(self.estates), ", ".join(self.clients))

    def cur(self):
        return self.c.cursor()

    def pick_estate(self):
        w = [self.t[e["code"]]["staff"] + 20 for e in self.estates]
        return self.rng.choices(self.estates, weights=w, k=1)[0]

    # ------------------------------------------------------------------ loop
    def step(self):
        self.tick += 1
        now = utcnow()
        if self.tick % 5 == 1:
            self.iot(now)
        if self.tick % 40 == 0:
            self.cur().execute("EXEC ingest.usp_housekeeping")
        if self.tick == 3 and self.scripted:
            self.tender_gate(now, self.scripted.pop())
            return
        r = self.rng.random()
        if r < 0.70:
            self.mri(now)
        elif r < 0.96:
            self.ta(now)
        elif r < 0.966:
            self.tender_gate(now)
        elif r < 0.976:
            self.heartbeat()

    # ---------------------------------------------------------- MRI CAFM
    def mri(self, now):
        e = self.pick_estate()
        code, t = e["code"], self.t[e["code"]]
        cur = self.cur()
        cur.execute("""
            SELECT COUNT(*), ISNULL(SUM(CASE WHEN priority <= 2 THEN 1 ELSE 0 END), 0)
            FROM silver.work_order WHERE estate_code = %s AND status IN ('Open','InProgress','OnHold')""", (code,))
        open_n, p1p2 = cur.fetchone()
        cur.execute("""
            SELECT source_ref, priority, status, asset_class, summary, created_at, respond_by, responded_at
            FROM silver.work_order
            WHERE estate_code = %s AND wo_type = 'Reactive' AND status IN ('Open','InProgress')
              AND created_at >= DATEADD(hour, -72, SYSUTCDATETIME())""", (code,))
        cand = cur.fetchall()
        complete = bool(cand) and (open_n > t["open"] or (open_n == t["open"] and self.rng.random() < 0.5))
        if complete:
            hi = [w for w in cand if w[1] <= 2]
            lo = [w for w in cand if w[1] > 2]
            if p1p2 > t["p1p2"] and hi:
                cand = hi
            elif p1p2 < t["p1p2"] and lo:
                cand = lo
            ref, pr, _st, cls, summary, created, respond_by, responded = self.rng.choice(cand)
            late = self.rng.random() < 0.015
            resp = SLA_MIN[pr] + 12 if late else min(SLA_MIN[pr] - 1, t["resp"] * (0.5 + self.rng.random()))
            responded = responded or min(now, created + dt.timedelta(minutes=resp))
            cur.execute("""EXEC ingest.usp_mri_workorder_upsert
                @source_ref=%s, @estate_code=%s, @wo_type='Reactive', @priority=%s, @status='Completed',
                @created_at=%s, @respond_by=%s, @responded_at=%s, @completed_at=%s""",
                        (ref, code, pr, created, respond_by, responded, now))
            log.info("MRI  %s WO completed  %s  %s", code, ref, summary)
        else:
            cls, _w, text = self.rng.choices(FAULTS, weights=[f[1] for f in FAULTS], k=1)[0]
            zone = self.rng.choice(ZONES)
            u = self.rng.random()
            pr = 1 if u < .05 else 2 if u < .20 else 3 if u < .70 else 4
            if p1p2 < t["p1p2"] and self.rng.random() < 0.6:
                pr = 1 if self.rng.random() < 0.3 else 2
            if p1p2 > t["p1p2"] and pr <= 2:
                pr = 3
            self.seq += 1
            ref = f"WO-{self.seq:06d}"
            summary = f"{zone} · {text}"
            cur.execute("""EXEC ingest.usp_mri_workorder_upsert
                @source_ref=%s, @estate_code=%s, @wo_type='Reactive', @priority=%s, @status='Open',
                @asset_class=%s, @summary=%s, @created_at=%s, @respond_by=%s""",
                        (ref, code, pr, cls, summary, now, now + dt.timedelta(minutes=SLA_MIN[pr])))
            log.info("MRI  %s WO raised     %s  P%d %s", code, ref, pr, summary)

    # ---------------------------------------------------------------- IoT
    def iot(self, now):
        rows = []
        for (code, metric), base in self.env_base.items():
            amp = 0.15 if metric == "temp_c" else 0.5
            v = base + 0.6 * (self.env_now[(code, metric)] - base) + self.rng.uniform(-amp, amp)
            self.env_now[(code, metric)] = v
            n, zone = self.env_meta[(code, metric)]
            rows.append({"estate_code": code, "zone": zone, "metric": metric, "value": round(v, 2),
                         "sensor_count": n, "read_at": now.isoformat()})
        if rows:
            self.cur().execute("EXEC ingest.usp_iot_reading_batch @readings=%s", (json.dumps(rows),))
            log.info("IoT  telemetry window  %d readings", len(rows))

    # --------------------------------------------------------- D365 HR + T&A
    def ta(self, now):
        e = self.pick_estate()
        code, t = e["code"], self.t[e["code"]]
        cur = self.cur()
        cur.execute("""SELECT COUNT(*) FROM silver.clock_event
                       WHERE estate_code = %s AND clock_out_at IS NULL
                         AND clock_in_at >= DATEADD(hour, -16, SYSUTCDATETIME())""", (code,))
        on = cur.fetchone()[0]
        n = self.rng.randint(1, 3)
        events = []
        if on < t["staff"] or (on == t["staff"] and self.rng.random() < 0.5):
            for _ in range(n):
                cat = self.rng.choices([m[0] for m in MIX], weights=[m[1] for m in MIX], k=1)[0]
                events.append({"staff_ref": f"S{code[2:]}-{self.rng.randint(5000, 9999)}", "estate_code": code,
                               "category": cat, "direction": "IN", "at": now.isoformat()})
        else:
            cur.execute("""SELECT TOP (%s) staff_ref, category FROM silver.clock_event
                           WHERE estate_code = %s AND clock_out_at IS NULL ORDER BY clock_in_at""", (n, code))
            for ref, cat in cur.fetchall():
                events.append({"staff_ref": ref, "estate_code": code, "category": cat,
                               "direction": "OUT", "at": now.isoformat()})
        if events:
            cur.execute("EXEC ingest.usp_ta_clock_batch @events=%s", (json.dumps(events),))
            log.info("T&A  %s %d %s", code, len(events), events[0]["direction"])

    # ------------------------------------------------------------- D365 F&O
    def tender_gate(self, now, ref: str | None = None):
        cur = self.cur()
        if ref:
            cur.execute("SELECT tender_ref, client_code, gates_passed, status FROM silver.tender WHERE tender_ref = %s", (ref,))
        else:
            cur.execute("""SELECT tender_ref, client_code, gates_passed, status FROM silver.tender
                           WHERE status NOT IN ('Completed', 'Overdue')""")
        live = cur.fetchall()
        if not live:
            return
        ref, client, gates, status = self.rng.choice(live)
        gate = gates + 1
        new_status = "At Risk" if status == "At Risk" and self.rng.random() < 0.5 else "On Track"
        cur.execute("EXEC ingest.usp_d365_tender_gate_passed @tender_ref=%s, @gate_no=%s, @passed_at=%s, @status=%s",
                    (ref, gate, now, new_status))
        log.info("D365 %s passed gate %d", ref, gate)
        if gate == 13:
            self.new_tender(now, client)

    def new_tender(self, now, client):
        scope, cat, value = self.rng.choice(NEW_TENDERS)
        estate = self.rng.choice([e["code"] for e in self.estates if e["client"] == client])
        ref = f"T-0{self.rng.randint(300, 899)}"
        try:
            self.cur().execute("""EXEC ingest.usp_d365_tender_register @tender_ref=%s, @estate_code=%s, @client_code=%s,
                @scope=%s, @category=%s, @bidders=%s, @est_value_aed=%s, @scoped_at=%s""",
                               (ref, estate, client, scope, cat, self.rng.randint(3, 5), int(value * 1e6), now))
            log.info("D365 %s registered  %s", ref, scope)
        except pymssql.IntegrityError:
            pass  # reference collision - skip this one

    def heartbeat(self):
        src = self.rng.choice(["D365 F&O", "D365 Projects"])
        detail = "Ledger sync · no new postings" if src == "D365 F&O" else "Projects sync · stages reconciled"
        for client in self.clients:
            self.cur().execute("EXEC ingest.usp_log_sync @source_system=%s, @client_code=%s, @detail=%s",
                               (src, client, detail))
        log.info("SYNC %s", src)


def main():
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(message)s", datefmt="%H:%M:%S")
    tick = float(os.environ.get("SIM_TICK_SECONDS", "3"))
    stop = {"now": False}
    signal.signal(signal.SIGTERM, lambda *_: stop.update(now=True))
    conn = connect()
    sim = Simulator(conn, random.Random())
    while not stop["now"]:
        try:
            sim.step()
        except pymssql.Error as e:
            log.error("event failed: %s", str(e).splitlines()[0][:200])
            try:
                conn.close()
            except Exception:
                pass
            conn = connect()
            sim.c = conn
        time.sleep(tick)


if __name__ == "__main__":
    main()
