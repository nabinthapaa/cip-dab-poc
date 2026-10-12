/* =============================================================================
   CIP POC · /config.js — switches the portal from its in-browser emulator to
   the live gateway, and tells it which stack it is on.

   The Supabase URL and publishable key are public by design (they are what any
   browser client of Supabase ships with). The portal uses them for one thing:
   the isolation test that calls Supabase directly, bypassing the gateway, to
   show that the database returns nothing without the gateway secret.
   ============================================================================= */
import type { Config } from "@netlify/functions";

export default async () => {
  const supabaseUrl = Netlify.env.get("SUPABASE_URL") ?? "";
  const publishableKey = Netlify.env.get("SUPABASE_PUBLISHABLE_KEY") ?? "";
  const cfg = {
    mode: "live",
    base: "",
    stack: "supabase",
    supabase: supabaseUrl && publishableKey ? { url: supabaseUrl, key: publishableKey } : null,
  };
  return new Response(`window.CIP_CONFIG = ${JSON.stringify(cfg)};\n`, {
    headers: {
      "content-type": "application/javascript; charset=utf-8",
      "cache-control": "no-store",
      "x-content-type-options": "nosniff",
    },
  });
};

export const config: Config = { path: "/config.js" };
