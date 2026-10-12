#!/usr/bin/env python3
"""
Derive dab/dab-config.azure.json from dab/dab-config.json so the entity
contract is defined once. Only the runtime posture changes for Azure:

  local (docker compose)                 azure (Container Apps behind APIM)
  -------------------------------------  --------------------------------------------
  AppService provider; the gateway       EntraID provider; DAB validates the same
  injects X-MS-CLIENT-PRINCIPAL          bearer token APIM validated (defence in depth)
  development mode (OpenAPI, detail)     production mode
  GraphQL introspection on               introspection off
  SQL login dab_reader                   managed identity (connection string from env)
  no telemetry                           Application Insights

Run after any entity change:  python3 tools/make_azure_config.py
"""
import copy
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
base = json.loads((ROOT / "dab" / "dab-config.json").read_text())
cfg = copy.deepcopy(base)

cfg["runtime"]["host"] = {
    "mode": "production",
    # DAB is internal-ingress only; browsers reach it through APIM, which owns CORS
    "cors": {"origins": [], "allow-credentials": False},
    "authentication": {
        "provider": "EntraID",
        "jwt": {
            "audience": "@env('DAB_JWT_AUDIENCE')",
            "issuer": "@env('DAB_JWT_ISSUER')",
        },
    },
}
cfg["runtime"]["graphql"]["allow-introspection"] = False
cfg["runtime"]["telemetry"] = {
    "application-insights": {
        "enabled": True,
        "connection-string": "@env('APPLICATIONINSIGHTS_CONNECTION_STRING')",
    }
}

out = ROOT / "dab" / "dab-config.azure.json"
out.write_text(json.dumps(cfg, indent=2) + "\n")
print("wrote", out.relative_to(ROOT))
