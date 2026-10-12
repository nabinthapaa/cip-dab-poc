/* =============================================================================
   CIP POC · API gateway on Netlify (the API Management role)
   GET /api/<contract view>?$filter=&$orderby=&$first=&$select=&$after=

   Same contract as the Data API builder stack: the portal cannot tell which
   one it is talking to. What happens per request:
     1. subscription key  -> client code      (401 if missing or unknown)
     2. GET only                              (403 otherwise)
     3. entity allow-list = the 16 vw_* views (404 "Invalid Entity path")
     4. OData-style query -> PostgREST query  (400 on anything unsupported)
     5. Supabase Data API call carrying x-cip-client + x-cip-gateway; the
        database checks the gateway secret and applies row-level security, so
        rows for other clients never leave Postgres
     6. {"value":[...], "nextLink"?} back to the caller, plus one audit line

   Environment (Netlify → Project configuration → Environment variables, scope
   Functions):
     SUPABASE_URL              https://<ref>.supabase.co
     SUPABASE_PUBLISHABLE_KEY  sb_publishable_... (or the legacy anon key)
     CIP_GATEWAY_SECRET        shared secret; only its SHA-256 is in the database
     CIP_CLIENT_KEYS           "key1:CL01,key2:CL02"
   ============================================================================= */
import type { Config, Context } from "@netlify/functions";

// Contract views and their key fields (dab/dab-config.json "primary-key" fields).
const ENTITIES: Record<string, string[]> = {
  vw_estate: ["estate_code"], vw_service_delivery: ["estate_code"], vw_invisible_care: ["estate_code"],
  vw_asset_mgmt: ["estate_code"], vw_finance: ["estate_code"], vw_finance_monthly: ["client_code", "period"],
  vw_finance_dimension: ["client_code", "cost_dimension"], vw_hr: ["estate_code"],
  vw_procurement: ["client_code"], vw_tender: ["tender_ref"], vw_tender_gate: ["tender_ref", "gate_no"],
  vw_works: ["item_ref"], vw_exceptions: ["exception_key"], vw_activity: ["event_id"],
  vw_data_health: ["health_key"], vw_portfolio_kpi: ["client_code"],
};
const DEFAULT_FIRST = 100;
const MAX_FIRST = 1000;
const UPSTREAM_TIMEOUT_MS = 8000;
const IDENT = /^[a-z_][a-z0-9_]*$/;

class BadRequest extends Error {}

const json = (status: number, body: unknown, extra: Record<string, string> = {}) =>
  new Response(JSON.stringify(body), {
    status,
    headers: {
      "content-type": "application/json; charset=utf-8",
      "cache-control": "no-store",
      "x-content-type-options": "nosniff",
      ...extra,
    },
  });

const dabError = (status: number, code: string, message: string) =>
  json(status, { error: { code, message, status } });

function clientKeys(): Map<string, string> {
  const map = new Map<string, string>();
  for (const pair of (Netlify.env.get("CIP_CLIENT_KEYS") ?? "").split(",")) {
    const i = pair.lastIndexOf(":");
    if (i > 0) map.set(pair.slice(0, i).trim(), pair.slice(i + 1).trim());
  }
  return map;
}

// "a eq 'x' and b eq 3"  ->  [["a","eq.x"],["b","eq.3"]]
function translateFilter(filter: string): [string, string][] {
  const out: [string, string][] = [];
  for (const clause of filter.split(/\s+and\s+/i)) {
    const m = clause.match(/^\s*([A-Za-z_][A-Za-z0-9_]*)\s+(eq|ne|gt|ge|lt|le)\s+(?:'((?:[^']|'')*)'|(-?\d+(?:\.\d+)?)|(null))\s*$/i);
    if (!m) throw new BadRequest(`Unsupported $filter: ${filter}. Use <field> eq|ne|gt|ge|lt|le <'text'|number|null>, joined with 'and'.`);
    const field = m[1].toLowerCase();
    const op = m[2].toLowerCase();
    if (m[5]) {
      if (op !== "eq" && op !== "ne") throw new BadRequest("null can only be compared with eq or ne.");
      out.push([field, op === "eq" ? "is.null" : "not.is.null"]);
    } else {
      const value = m[3] != null ? m[3].replace(/''/g, "'") : m[4];
      out.push([field, `${op === "ne" ? "neq" : op}.${value}`]);
    }
  }
  return out;
}

// "event_id desc, estate_code"  ->  "event_id.desc,estate_code.asc"
function translateOrderBy(orderby: string | null, keys: string[]): string {
  if (!orderby) return keys.map((k) => `${k}.asc`).join(",");
  return orderby.split(",").map((part) => {
    const [field, dir = "asc", ...rest] = part.trim().split(/\s+/);
    const f = (field ?? "").toLowerCase();
    const d = dir.toLowerCase();
    if (!IDENT.test(f) || rest.length || (d !== "asc" && d !== "desc")) throw new BadRequest(`Unsupported $orderby: ${orderby}`);
    return `${f}.${d}`;
  }).join(",");
}

function translateSelect(select: string | null): string {
  if (!select) return "*";
  const fields = select.split(",").map((s) => s.trim().toLowerCase());
  if (!fields.every((f) => IDENT.test(f))) throw new BadRequest(`Unsupported $select: ${select}`);
  return fields.join(",");
}

const encodeCursor = (offset: number) => btoa(JSON.stringify({ o: offset })).replace(/=+$/, "");
function decodeCursor(after: string | null): number {
  if (!after) return 0;
  try {
    const o = JSON.parse(atob(after)).o;
    if (Number.isInteger(o) && o >= 0) return o;
  } catch { /* fall through */ }
  throw new BadRequest("Invalid $after cursor.");
}

export default async (req: Request, context: Context) => {
  const started = Date.now();
  const url = new URL(req.url);
  const entity = (context.params?.entity ?? "").toString();
  const audit = (status: number, client: string | null, rows: number | null, note?: string) =>
    console.log(JSON.stringify({ at: new Date().toISOString(), client, method: req.method, entity: entity || "/", status, rows, ms: Date.now() - started, ip: context.ip, note }));

  // Root: health, no key needed (same as DAB's /health)
  if (!entity) {
    audit(200, null, null, "health");
    return json(200, { status: "Healthy", "app-name": "cip-gateway", stack: "supabase" });
  }

  // 1. subscription key
  const key = req.headers.get("ocp-apim-subscription-key");
  if (!key) {
    audit(401, null, null, "missing key");
    return json(401, { statusCode: 401, message: "Access denied due to missing subscription key. Make sure to include subscription key when making requests to an API." });
  }
  const client = clientKeys().get(key);
  if (!client) {
    audit(401, null, null, "invalid key");
    return json(401, { statusCode: 401, message: "Access denied due to invalid subscription key. Make sure to provide a valid key for an active subscription." });
  }

  // 2. read-only
  if (req.method !== "GET") {
    audit(403, client, null, "write blocked");
    return json(403, { statusCode: 403, message: "Read-only API: only GET is permitted on /api." });
  }

  // 3. only contract views are reachable
  const keys = ENTITIES[entity];
  if (!keys) {
    audit(404, client, null, "not in contract");
    return dabError(404, "EntityNotFound", `Invalid Entity path: ${entity}.`);
  }

  const supabaseUrl = Netlify.env.get("SUPABASE_URL");
  const apiKey = Netlify.env.get("SUPABASE_PUBLISHABLE_KEY");
  const secret = Netlify.env.get("CIP_GATEWAY_SECRET");
  if (!supabaseUrl || !apiKey || !secret) {
    audit(500, client, null, "gateway not configured");
    return dabError(500, "GatewayNotConfigured", "The gateway is missing SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY or CIP_GATEWAY_SECRET.");
  }

  // 4. query translation
  let upstream: URL, first: number, offset: number;
  try {
    const p = url.searchParams;
    first = p.get("$first") ? parseInt(p.get("$first")!, 10) : DEFAULT_FIRST;
    if (!Number.isInteger(first) || first < 1) throw new BadRequest("$first must be a positive integer.");
    first = Math.min(first, MAX_FIRST);
    offset = decodeCursor(p.get("$after"));
    upstream = new URL(`/rest/v1/${entity}`, supabaseUrl);
    upstream.searchParams.set("select", translateSelect(p.get("$select")));
    for (const [f, v] of p.get("$filter") ? translateFilter(p.get("$filter")!) : []) upstream.searchParams.append(f, v);
    upstream.searchParams.set("order", translateOrderBy(p.get("$orderby"), keys));
    upstream.searchParams.set("limit", String(first + 1));
    if (offset) upstream.searchParams.set("offset", String(offset));
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    audit(400, client, null, msg);
    return dabError(400, "BadRequest", msg);
  }

  // 5. Supabase Data API; identity travels as headers the database verifies
  let res: Response;
  try {
    res = await fetch(upstream, {
      headers: {
        apikey: apiKey,
        accept: "application/json",
        "x-cip-client": client,
        "x-cip-gateway": secret,
      },
      signal: AbortSignal.timeout(UPSTREAM_TIMEOUT_MS),
    });
  } catch (err) {
    audit(504, client, null, "upstream unreachable");
    return dabError(504, "UpstreamTimeout", "The data API did not answer in time.");
  }

  if (!res.ok) {
    const detail = await res.json().catch(() => ({})) as { message?: string; code?: string };
    const status = res.status === 400 ? 400 : 502;
    audit(status, client, null, `upstream ${res.status} ${detail.code ?? ""}`);
    return dabError(status, status === 400 ? "BadRequest" : "UpstreamError",
      status === 400 ? (detail.message ?? "Bad request.") : `The data API answered ${res.status}.`);
  }

  // 6. DAB-shaped response
  const rows = (await res.json()) as unknown[];
  const more = rows.length > first;
  const body: { value: unknown[]; nextLink?: string } = { value: more ? rows.slice(0, first) : rows };
  if (more) {
    const next = new URL(url);
    next.searchParams.set("$after", encodeCursor(offset + first));
    body.nextLink = next.pathname + next.search;
  }
  audit(200, client, body.value.length);
  return json(200, body);
};

export const config: Config = {
  path: ["/api", "/api/:entity"],
  rateLimit: { windowLimit: 600, windowSize: 60, aggregateBy: ["ip", "domain"] },
};
