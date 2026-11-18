/** Removes anything that looks like a credential before a message is logged or stored. */
const PATTERNS: Array<[RegExp, string]> = [
  [/(access_token|input_token|fb_exchange_token|client_secret|appsecret_proof)=([^&\s"']+)/gi, "$1=[REDACTED]"],
  [/("(?:access_token|input_token|client_secret|appsecret_proof|token)"\s*:\s*")([^"]+)(")/gi, "$1[REDACTED]$3"],
  [/(Authorization:\s*(?:OAuth|Bearer)\s+)\S+/gi, "$1[REDACTED]"],
  [/\bOAuth\s+[A-Za-z0-9|_\-.]{20,}/g, "OAuth [REDACTED]"],
  [/\bEAA[A-Za-z0-9]{20,}/g, "[REDACTED_TOKEN]"],
  [/(X-Goog-Signature=)[0-9a-f]+/gi, "$1[REDACTED]"],
];

export function redact(input: unknown): string {
  let s = typeof input === "string" ? input : input instanceof Error ? `${input.name}: ${input.message}` : JSON.stringify(input);
  for (const [re, rep] of PATTERNS) s = s.replace(re, rep);
  return s.length > 2000 ? s.slice(0, 2000) + "…" : s;
}
