-- =============================================================================
-- CIP POC on Supabase · 004 grants and row-level security
--
-- Same rule as sql/60_security.sql: a caller sees only rows whose client_code
-- equals its client identity; no identity, no rows.
--
-- Where the identity comes from. DAB put the caller's token claims into SQL
-- Server SESSION_CONTEXT. Here the Netlify gateway (the only intended caller)
-- calls Supabase's Data API with two headers:
--   x-cip-client   the client the gateway resolved from the subscription key
--   x-cip-gateway  a shared secret only the gateway holds
-- PostgREST exposes request headers to SQL; cip_sec.request_client() returns
-- the client only when the secret's SHA-256 matches. Anyone calling the Data
-- API directly with the public key, with or without a forged x-cip-client,
-- gets zero rows.
-- =============================================================================

create table if not exists cip_sec.gateway_secret (
  label          text primary key,
  secret_sha256  text not null,
  created_at     timestamp(0) not null default cip_core.utc_now()
);
revoke all on cip_sec.gateway_secret from public, anon, authenticated;

create or replace function cip_sec.request_client() returns text
language plpgsql stable security definer set search_path = '' as $$
declare
  h      json := nullif(current_setting('request.headers', true), '')::json;
  client text;
  secret text;
begin
  if h is null then
    -- not an HTTP request (SQL console / tests): use an explicitly set session value
    return nullif(current_setting('cip.client_code', true), '');
  end if;
  client := h ->> 'x-cip-client';
  secret := h ->> 'x-cip-gateway';
  if client is null or secret is null then
    return null;
  end if;
  if exists (select 1 from cip_sec.gateway_secret g
              where g.secret_sha256 = encode(sha256(convert_to(secret, 'UTF8')), 'hex')) then
    return client;
  end if;
  return null;
end $$;

revoke all on function cip_sec.request_client() from public;
grant execute on function cip_sec.request_client() to anon;

-- ---------------------------------------------------------------- grants ----
-- anon reads through the invoker views, so it needs SELECT underneath. None of
-- these schemas are exposed by the Data API, so this adds no HTTP surface.
grant usage on schema cip_core, cip_silver, cip_calc, cip_sec to anon;
grant select on all tables in schema cip_core   to anon;
grant select on all tables in schema cip_silver to anon;
grant select on all tables in schema cip_calc   to anon;
revoke select on cip_sec.gateway_secret from anon;

-- contract views: read-only for anon, nothing for signed-in users
revoke all on public.vw_estate, public.vw_service_delivery, public.vw_invisible_care, public.vw_asset_mgmt,
              public.vw_finance, public.vw_finance_monthly, public.vw_finance_dimension, public.vw_hr,
              public.vw_procurement, public.vw_tender, public.vw_tender_gate, public.vw_works,
              public.vw_exceptions, public.vw_activity, public.vw_data_health, public.vw_portfolio_kpi
  from anon, authenticated;
grant select on public.vw_estate, public.vw_service_delivery, public.vw_invisible_care, public.vw_asset_mgmt,
                public.vw_finance, public.vw_finance_monthly, public.vw_finance_dimension, public.vw_hr,
                public.vw_procurement, public.vw_tender, public.vw_tender_gate, public.vw_works,
                public.vw_exceptions, public.vw_activity, public.vw_data_health, public.vw_portfolio_kpi
  to anon;

-- ------------------------------------------------------------------- RLS ----
do $$
declare t text;
begin
  foreach t in array array[
    'cip_core.client', 'cip_core.estate',
    'cip_silver.work_order', 'cip_silver.sensor_reading', 'cip_silver.sensor_window', 'cip_silver.tender', 'cip_silver.tender_gate_event',
    'cip_silver.clock_event', 'cip_silver.roster_plan', 'cip_silver.gl_actual', 'cip_silver.budget',
    'cip_silver.capex_programme', 'cip_silver.asset_condition', 'cip_silver.work_item',
    'cip_silver.exception_action', 'cip_silver.ingest_log']
  loop
    execute format('alter table %s enable row level security', t);
    execute format('drop policy if exists cip_client_isolation on %s', t);
    execute format('create policy cip_client_isolation on %s for select to anon '
                   'using (client_code = (select cip_sec.request_client()))', t);
  end loop;
end $$;

-- Reference tables hold no client data; RLS on, readable by anon.
alter table cip_core.index_weight     enable row level security;
alter table cip_core.procurement_gate enable row level security;
alter table cip_core.work_stage       enable row level security;
drop policy if exists cip_reference_read on cip_core.index_weight;
drop policy if exists cip_reference_read on cip_core.procurement_gate;
drop policy if exists cip_reference_read on cip_core.work_stage;
create policy cip_reference_read on cip_core.index_weight     for select to anon using (true);
create policy cip_reference_read on cip_core.procurement_gate for select to anon using (true);
create policy cip_reference_read on cip_core.work_stage       for select to anon using (true);
alter table cip_sec.gateway_secret enable row level security;
