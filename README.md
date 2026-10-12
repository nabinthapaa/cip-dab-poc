# Client Intelligence Portal · Data API builder live-read POC

A working version of the Scenario 1 architecture: source events land in a governed SQL core, Data API builder (DAB) exposes 16 contract views as REST and GraphQL with no custom API code, a gateway stands in for API Management, and the v3 Portfolio Intelligence console reads every live figure through that path. Row-level security in the database keeps each client to its own estates.

```
 simulator ─────► SQL Server ─────────────────────────► DAB ─────────► gateway ─────► portal
 (MRI, D365,      silver tables → calc → contract views    REST/GraphQL   key → client    v3 console,
  IoT events)     RLS: client_code = SESSION_CONTEXT        claims → SQL   rate limit,     LIVE / STATIC
 stand-in for                                               session ctx    cache, audit    chip per panel
 Fabric                                                                    stand-in for APIM
```

## What it proves

| Claim in the architecture | Where to see it |
|---|---|
| One JSON file replaces custom middleware | `dab/dab-config.json` — 16 entities, no code |
| One definition per figure | `sql/20_calc_views.sql` defines each metric once; GROUPING SETS give estate and client grain from the same definition |
| Client isolation is enforced by the database | `sql/60_security.sql`; the init job proves it (`CL01=10 CL02=3 no claim=0`); the console's *Data Pipeline → Prove the isolation* runs 8 attack-style checks |
| The portal cannot write | gateway allows GET on `/api` only; DAB role `client_reader` has `read` only; `dab_reader` can only SELECT the contract schema |
| Live, not batch | the simulator writes MRI, D365, T&A and IoT events every 3 s; the console polls every 5 s and flashes what changed |
| Gaps are visible, not hidden | every panel carries a chip: `LIVE · <view>` (tap for the request trace) or `STATIC · <mapping item>` e.g. `M080 gap` |

## Run it

### Option A — full stack (SQL Server 2022 + DAB 2.1.5 + gateway + simulator)

Needs Docker Desktop (on Apple silicon, turn on Rosetta for x86/amd64 emulation).

```bash
cp .env.example .env          # change the passwords
docker compose up --build     # first start pulls images and loads the seed (1–2 min)
open http://localhost:8080
```

Check the init job proved RLS before DAB started:

```bash
docker compose logs db-init | tail -4
# [init] RLS check as dab_reader: no claim=0  CL01=10  CL02=3
```

Then run the smoke test (28 checks, plus GraphQL):

```bash
tests/smoke.sh
```

Rebuild the database from scratch: `RESET_DB=1 docker compose up db-init`.
If your registry mirror doesn't have the `data-api-builder:2.1.5` tag yet, use `:latest` in `docker-compose.yml`; the config targets the 2.x schema.
Inspect SQL directly on `localhost,14330` (sa, password from `.env`).

### Option B — no Docker

```bash
node tools/dev-server.js      # http://localhost:8080
```

Same portal, same HTTP surface (keys, 401/403/404, `{"value":[...]}`), with the database replaced by the in-memory emulator. Good for front-end work and demos on a laptop. `BASE=http://localhost:8080 SKIP_GRAPHQL=1 tests/smoke.sh` passes against it.

### Option C — one file

Open `dist/cip-console-standalone.html` in a browser. The pipeline runs inside the page (same seed rows, same view definitions, same RLS rule). Nothing is sent anywhere.

### Option D — hosted: Netlify + Supabase

The same contract, hosted without containers. Data API builder needs a container host, so on this stack Supabase's Data API (PostgREST) plays DAB's part and a Netlify Function plays API Management.

```
 pg_cron simulator ──► Supabase Postgres ─────────────────────► Supabase Data API ──► Netlify Function ──► portal
 every 5 s, inside     cip_silver → cip_calc → public.vw_*        PostgREST, only the    /api/<view>         (Netlify static)
 the database          RLS: client_code = cip_sec.request_client()  public schema exposed  key → client,
                       (gateway secret verified in SQL)                                  GET only, audit
```

| Piece | Where |
|---|---|
| Schema, calc views, contract views | `supabase/migrations/001…003` (same tables, columns and view outputs as `sql/`) |
| Grants and row-level security | `supabase/migrations/004_security.sql` |
| Ingest functions and simulator | `supabase/migrations/005_ingest_and_simulator.sql` |
| Seed (generated in the database) | `supabase/migrations/006_seed.sql` from `tools/generate_pg_seed.py` |
| Schedules (`pg_cron`) | `supabase/migrations/007_schedule.sql`: simulator every 5 s, reseed 02:00 GST, history cleanup hourly |
| Gateway | `netlify/functions/api.mts` (`/api`, `/api/:entity`) |
| Live-mode switch | `netlify/functions/config.mts` (`/config.js`) |
| Site config | `netlify.toml` (publishes `portal/`) |

Set up:

1. **Supabase.** Run `001`, `002`, `003` in order in the SQL editor (or as migrations), then `supabase/setup_004_007.sql` (004–007 in one transaction). Then register the gateway secret's hash:
   ```sql
   insert into cip_sec.gateway_secret (label, secret_sha256)
   values ('netlify-gateway', encode(sha256(convert_to('<the secret>', 'UTF8')), 'hex'));
   ```
   Generate the secret with `openssl rand -hex 32`. Only its hash is stored in the database.
2. **Netlify.** Set these environment variables, scoped to Functions:

   | Variable | Value |
   |---|---|
   | `SUPABASE_URL` | `https://<project-ref>.supabase.co` |
   | `SUPABASE_PUBLISHABLE_KEY` | the project's `sb_publishable_…` key |
   | `CIP_GATEWAY_SECRET` | the secret from step 1 (mark as secret) |
   | `CIP_CLIENT_KEYS` | `cl01-demo-7f3a9c:CL01,cl02-demo-41be07:CL02` |

3. Link this repository to the Netlify project (Project configuration → Build & deploy → Link repository). No build command is needed.

Stop the simulator with `select cron.unschedule('cip-simulator');`. Rebuild the demo data at any time with `select cip_ingest.seed_demo();`.

## Five-minute demo

1. **Home.** Every number in the KPI strip, the health ranking, the map and *Attention & Actions* comes from a view. Watch *Open work orders* and *Personnel on site* move as source events land. Tap any `LIVE` chip to see the exact request, latency and JSON.
2. **Attention & Actions.** Exceptions are computed in SQL (OPEX ≥ +5%, an environmental index < 80, tender overdue). Teams only log the action. CL02's humidity alert shows *No action logged — assign an owner*.
3. **Viewing as → CL02.** The console now shows three estates. Nothing in the browser filtered this; the database returned only CL02 rows. STATIC panels collapse because illustrative data has no client scope.
4. **Data Pipeline.** Live source events (`vw_activity`), data health per source (M090), the request log, and *Run all checks*: no key, unknown key, CL02 filtering for a CL01 estate, a forged principal header, a write attempt and an object outside the contract all fail closed.
5. **Definitions.** The contract table and KPI dictionary name the view and column behind each KPI.

## Repository map

```
sql/             00 database & logins · 10 tables · 20 calc views · 30 contract views
                 40 seed (generated) · 50 ingest procedures · 60 users, grants, RLS · run-init.sh
dab/             dab-config.json (local, AppService provider) · dab-config.azure.json (generated, Entra ID)
gateway/         nginx.conf + dab-proxy.inc — APIM stand-in
apim/policy.xml  the real API Management policy for Azure
simulator/       source-event simulator (calls the same ingest.* procedures Fabric would)
portal/          the console · js/emulator.js · data/seed.json · img/
tools/           generate_seed.py · check_contract.py · make_azure_config.py · gen_contract_doc.py
                 build_artifact.py · dev-server.js
tests/smoke.sh   end-to-end checks against the running stack
docs/            data-contract.md (generated) · architecture-flow.html (the Scenario 1 animation)
dist/            self-contained builds of the console
supabase/        Postgres port for the hosted stack: migrations 001–007 · setup_004_007.sql
netlify/         functions/api.mts (gateway) · functions/config.mts (live-mode switch)
netlify.toml     Netlify site config
```

## How a request is isolated

1. The console sends `GET /api/vw_estate` with `Ocp-Apim-Subscription-Key`.
2. The gateway maps the key to a client and **overwrites** `X-MS-CLIENT-PRINCIPAL` with that client's claims (`roles=client_reader`, `client_code=CL02`). Whatever the caller sent under that name is discarded.
3. DAB (provider `AppService` locally, `EntraID` in Azure) authenticates the principal, checks the `client_reader` role has `read` on the entity, and, because `set-session-context` is on, runs `EXEC sp_set_session_context 'client_code', 'CL02'` before its SELECT.
4. `sec.fn_client_filter` keeps only rows where `client_code = SESSION_CONTEXT('client_code')` on every silver and core table. Every contract view sits on top of those tables, so every endpoint is filtered. No claim means no rows.

DAB switches off its own response cache when session context is on (verified in the DAB source), so caching lives in the gateway and APIM and is keyed per client.

**On Netlify + Supabase** the identity travels as request headers instead of a token:

1. The Netlify Function maps the subscription key to a client, rejects anything but GET, and allows only the 16 `vw_*` names. It calls `https://<ref>.supabase.co/rest/v1/<view>` with the publishable key and two headers it sets itself: `x-cip-client` and `x-cip-gateway` (the shared secret). Headers sent by the browser are not forwarded.
2. PostgREST runs the query as role `anon` and exposes the request headers to SQL. `cip_sec.request_client()` returns the client only when the SHA-256 of `x-cip-gateway` matches `cip_sec.gateway_secret`.
3. Every client table has the policy `client_code = (select cip_sec.request_client())`; the contract views are `security_invoker`, so the policy applies through them.
4. Anyone calling Supabase directly with the public key, with or without a forged `x-cip-client`, gets an empty list. Tables outside `public` are not exposed at all, and `anon` can only SELECT. The console's isolation checks include three such bypass attempts.

## Path to Azure

| POC component | Azure | Change |
|---|---|---|
| SQL Server container | Azure SQL Database (UAE North) | run `sql/10…60`; replace SQL logins with managed identities (`CREATE USER [dab-identity] FROM EXTERNAL PROVIDER`) |
| simulator | Fabric pipelines + eventstream | call the same `ingest.*` procedures (or MERGE into silver with the same keys) as the ingestion identity |
| DAB container | Azure Container Apps, internal ingress, private endpoint to SQL | mount `dab/dab-config.azure.json`; set `DAB_CONNECTION_STRING`, `DAB_JWT_AUDIENCE`, `DAB_JWT_ISSUER`, `APPLICATIONINSIGHTS_CONNECTION_STRING` |
| gateway | API Management | apply `apim/policy.xml`; one subscription per client named `client-<CODE>`; enable diagnostics for audit |
| portal | Static Web Apps or App Service | sign-in with Entra ID; call APIM with the bearer token and the client's key |

Open decision for go-live: how the `client_code` claim gets into the Entra token (directory extension attribute with a claims-mapping policy, or a custom claims provider). The APIM policy rejects a token whose `client_code` does not match the subscription's client.

## What was verified in the build environment

The build sandbox had no Docker daemon and no access to Microsoft's container registry, so the SQL Server + DAB stack itself was not started there. What was checked:

- All T-SQL (schema, views, seed, procedures, RLS policy, and every statement the simulator generated in an 800-tick run) parses with Microsoft's T-SQL parser (ScriptDom, SQL Server 2019 level).
- Both DAB configs validate against the official DAB v2.1.5 JSON schema; the RLS, auth-header and caching behaviour above was confirmed in the DAB v2.1.5 source.
- `tools/check_contract.py`: the 16 SQL views, the 16 DAB entities and the emulator's output have identical columns.
- The simulator's code paths ran against a stub database.
- `docker compose config` validates the compose file; the gateway's nginx config parses cleanly with directive and context checks (crossplane).
- The console ran in Chromium at desktop and phone width against the dev server and as a standalone file: all 8 isolation checks pass, no console errors, no horizontal scroll; `tests/smoke.sh` passes 28/28 against the dev server.

So the first `docker compose up` on your machine is the first full run against real SQL Server and DAB. If anything fails it will most likely be in `db-init`'s log (SQL) or the `dab` container log (config); both report the failing object by name.

## Regenerating

```bash
python3 tools/generate_seed.py          # sql/40_seed.sql + portal/data/seed.json
python3 tools/generate_pg_seed.py       # supabase/migrations/006_seed.sql
python3 tools/make_azure_config.py      # dab/dab-config.azure.json
python3 tools/check_contract.py         # SQL views = DAB entities = emulator
python3 tools/gen_contract_doc.py       # docs/data-contract.md
python3 tools/build_artifact.py         # dist/*.html
```

## Limits of this POC

- Synthetic data; CL01 is calibrated to the v3 mock-up, CL02 exists to prove isolation. Estates are coded; map positions are approximate.
- STATIC panels (energy, water, HSE, spares, partner scorecards, lifecycle strategy) have no contract source yet; each chip names the mapping item that would make it live.
- Finance uses fixed closed periods (FY2026, closed through September); event data is timestamped relative to load time.
- Trend panels ("Top Movements") need a daily snapshot of the contract views; that is the first step of the predictive phase.
