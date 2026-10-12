#!/usr/bin/env python3
"""
Contract consistency check - run before every commit that touches a view.

  1. Every contract view in sql/30_contract_views.sql has a DAB entity, and
     every DAB entity points at a contract view.
  2. DAB primary-key fields exist as columns of their view.
  3. The in-browser emulator returns exactly the view's columns (same JSON
     keys the portal binds to), so the offline demo cannot drift from SQL.
  4. Both DAB configs validate against the DAB JSON schema (if available).

Usage: python3 tools/check_contract.py [--schema path/to/dab.draft.schema.json]
Exit code 0 = consistent.
"""
import argparse
import json
import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def split_top(s: str, sep: str = ","):
    out, depth, cur, quote = [], 0, [], False
    for ch in s:
        if ch == "'":
            quote = not quote
        if not quote:
            if ch == "(":
                depth += 1
            elif ch == ")":
                depth -= 1
            elif ch == sep and depth == 0:
                out.append("".join(cur))
                cur = []
                continue
        cur.append(ch)
    out.append("".join(cur))
    return out


def top_level_select(body: str) -> str:
    """Text between the first depth-0 SELECT and its depth-0 FROM."""
    depth, i, n = 0, 0, len(body)
    start = None
    up = body.upper()
    while i < n:
        ch = body[i]
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
        elif depth == 0:
            if start is None and up.startswith("SELECT", i) and not body[i - 1].isalnum():
                start = i + 6
            elif start is not None and up.startswith("FROM", i) and not body[i - 1].isalnum() and not body[i + 4].isalnum():
                return body[start:i]
        i += 1
    raise ValueError("no top-level SELECT ... FROM")


def view_columns(sql: str):
    sql = re.sub(r"--[^\n]*", "", sql)
    views = {}
    for m in re.finditer(r"CREATE OR ALTER VIEW contract\.(\w+)\s+AS(.*?)\nGO", sql, re.S | re.I):
        name, body = m.group(1), m.group(2)
        cols = []
        for item in split_top(top_level_select(body)):
            item = " ".join(item.split())
            am = re.search(r"\bAS\s+(\w+)$", item, re.I)
            if am:
                cols.append(am.group(1))
            else:
                cols.append(item.split(".")[-1].strip())
        views[name] = cols
    return views


def emulator_columns():
    node = shutil.which("node")
    if not node:
        return None
    js = r"""
const E=require(process.argv[1]+'/portal/js/emulator.js');
const seed=require(process.argv[1]+'/portal/data/seed.json');
const out={};
for (const key of Object.keys(E.KEYS)) {
  const emu=new E.Emulator(seed);
  for (const ent of Object.keys(E.KEYS_BY_ENTITY)) {
    const r=emu.request('GET','/api/'+ent,{'Ocp-Apim-Subscription-Key':key});
    if (r.status!==200) { out[ent]={error:r.status}; continue; }
    if (r.body.value.length) out[ent]=Object.keys(r.body.value[0]);
  }
}
console.log(JSON.stringify(out));
"""
    res = subprocess.run([node, "-e", js, str(ROOT)], capture_output=True, text=True, check=True)
    return json.loads(res.stdout)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--schema", help="dab.draft.schema.json to validate the configs against")
    a = ap.parse_args()
    problems = []

    views = view_columns((ROOT / "sql" / "30_contract_views.sql").read_text(encoding="utf-8"))
    cfg = json.loads((ROOT / "dab" / "dab-config.json").read_text())
    ents = cfg["entities"]

    for name in views:
        if name not in ents:
            problems.append(f"view contract.{name} has no DAB entity")
    for name, e in ents.items():
        obj = e["source"]["object"].split(".")[-1]
        if obj not in views:
            problems.append(f"entity {name} -> {e['source']['object']} is not a contract view")
            continue
        for f in e.get("fields", []):
            if f.get("primary-key") and f["name"] not in views[obj]:
                problems.append(f"entity {name}: key field {f['name']} not in view columns")
        perms = {p["role"] for p in e["permissions"]}
        if perms != {"client_reader"}:
            problems.append(f"entity {name}: permissions should be client_reader only, got {perms}")

    emu = emulator_columns()
    if emu is None:
        print("node not found - skipping emulator check")
    else:
        for name, cols in views.items():
            got = emu.get(name)
            if got is None:
                problems.append(f"emulator returned no rows for {name}")
            elif isinstance(got, dict):
                problems.append(f"emulator error for {name}: {got}")
            elif got != cols:
                problems.append(f"{name}: SQL {cols} != emulator {got}")

    if a.schema:
        try:
            import jsonschema
        except ImportError:
            print("jsonschema not installed - skipping schema validation")
        else:
            schema = json.loads(Path(a.schema).read_text())
            v = jsonschema.Draft7Validator(schema)
            for f in ["dab-config.json", "dab-config.azure.json"]:
                for err in v.iter_errors(json.loads((ROOT / "dab" / f).read_text())):
                    problems.append(f"{f}: {list(err.path)} {err.message[:160]}")

    print(f"{len(views)} contract views · {len(ents)} DAB entities")
    for name, cols in views.items():
        print(f"  {name:22s} {len(cols):2d} cols")
    if problems:
        print("\nPROBLEMS:")
        for p in problems:
            print("  -", p)
        sys.exit(1)
    print("\ncontract consistent: SQL views = DAB entities = emulator output")


if __name__ == "__main__":
    main()
