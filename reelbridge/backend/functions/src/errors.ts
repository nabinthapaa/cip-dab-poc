/** A Graph API error response ({"error": {...}}) or HTTP failure. */
export class GraphApiError extends Error {
  constructor(
    message: string,
    readonly httpStatus: number,
    readonly code?: number,
    readonly subcode?: number,
    readonly type?: string,
    readonly isTransient?: boolean,
    readonly fbtraceId?: string,
  ) {
    super(message);
    this.name = "GraphApiError";
  }
}

/** Thrown when the user must reconnect Facebook (missing/expired token or permission). */
export class ReconnectRequiredError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "ReconnectRequiredError";
  }
}

/** Thrown for problems that retrying will not fix (bad input, policy block, invalid Page). */
export class PermanentError extends Error {
  constructor(message: string, readonly code = "permanent") {
    super(message);
    this.name = "PermanentError";
  }
}

export type FailureKind = "retryable" | "reconnect" | "permanent";
export interface Classified {
  kind: FailureKind;
  userMessage: string;
  code: string;
}

const RATE_LIMIT_CODES = new Set([4, 17, 32, 341, 613, 80001]);
const TRANSIENT_CODES = new Set([1, 2]);
const TOKEN_SUBCODE_MESSAGES: Record<number, string> = {
  458: "ReelBridge was removed from your Facebook account. Reconnect to keep publishing.",
  459: "Your Facebook account needs attention (checkpoint). Log in to Facebook, then reconnect.",
  460: "Your Facebook password changed. Reconnect to keep publishing.",
  463: "Your Facebook access expired. Reconnect to keep publishing.",
  464: "Your Facebook account isn't confirmed. Log in to Facebook, then reconnect.",
  467: "Your Facebook access is no longer valid. Reconnect to keep publishing.",
  492: "You no longer have a role on this Page. Ask a Page admin for access, then reconnect.",
};

/** Maps any error to retry behaviour and a message that is safe and useful to show the user. */
export function classify(err: unknown): Classified {
  if (err instanceof ReconnectRequiredError) return { kind: "reconnect", userMessage: err.message, code: "reconnect" };
  if (err instanceof PermanentError) return { kind: "permanent", userMessage: err.message, code: err.code };

  if (err instanceof GraphApiError) {
    const code = err.code ?? 0;
    const tag = `graph_${code}${err.subcode ? "_" + err.subcode : ""}`;
    if (code === 190 || code === 102) {
      return {
        kind: "reconnect",
        userMessage: (err.subcode && TOKEN_SUBCODE_MESSAGES[err.subcode]) || "Your Facebook access expired. Reconnect to keep publishing.",
        code: tag,
      };
    }
    if (code === 10 || (code >= 200 && code <= 299)) {
      return { kind: "reconnect", userMessage: "ReelBridge is missing permission to publish to this Page. Reconnect and allow all requested permissions.", code: tag };
    }
    if (code === 368) return { kind: "permanent", userMessage: "Facebook blocked this post for a policy reason. Check your Page's notifications.", code: tag };
    if (code === 100 && err.subcode === 33) {
      return { kind: "permanent", userMessage: "The selected Facebook Page wasn't found or you no longer manage it. Choose a Page again.", code: tag };
    }
    if (RATE_LIMIT_CODES.has(code)) return { kind: "retryable", userMessage: "Facebook is rate-limiting requests. ReelBridge will retry automatically.", code: tag };
    if (TRANSIENT_CODES.has(code) || err.isTransient || err.httpStatus >= 500 || err.httpStatus === 0) {
      return { kind: "retryable", userMessage: "Facebook had a temporary problem. ReelBridge will retry automatically.", code: tag };
    }
    if (code >= 6000 && code < 7000) {
      return { kind: code === 6000 ? "retryable" : "permanent", userMessage: `Facebook couldn't process the video: ${err.message}`, code: tag };
    }
    return { kind: "permanent", userMessage: `Facebook rejected the request: ${err.message}`, code: tag };
  }

  const e = err as { name?: string; code?: string; message?: string };
  if (e?.name === "AbortError" || e?.name === "TimeoutError" || ["ECONNRESET", "ETIMEDOUT", "ENOTFOUND", "EAI_AGAIN", "ECONNREFUSED", "EPIPE"].includes(e?.code ?? "") ||
      (e?.name === "TypeError" && /fetch failed/i.test(e?.message ?? ""))) {
    return { kind: "retryable", userMessage: "Network problem while talking to Facebook. ReelBridge will retry automatically.", code: "network" };
  }
  return { kind: "retryable", userMessage: "Unexpected error. ReelBridge will retry automatically.", code: "internal" };
}
