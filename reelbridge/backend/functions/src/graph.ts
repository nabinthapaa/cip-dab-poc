import { request as httpsRequest } from "node:https";
import type { Readable } from "node:stream";
import { appSecretProof } from "./crypto";
import { GraphApiError } from "./errors";
import { redact } from "./redact";

export type FetchLike = (url: string, init?: { method?: string; headers?: Record<string, string>; body?: string; signal?: AbortSignal }) => Promise<{
  status: number;
  json(): Promise<unknown>;
  text(): Promise<string>;
}>;

/** Streams a body to rupload.facebook.com with an exact Content-Length (fetch can't set it). */
export type BinaryUploader = (url: string, headers: Record<string, string>, body: Readable, timeoutMs: number) => Promise<{ status: number; body: string }>;

export interface GraphConfig {
  appId: string;
  appSecret: string;
  version: string; // e.g. "v26.0"
  fetch?: FetchLike;
  uploadBinary?: BinaryUploader;
  timeoutMs?: number;
}

export interface ReelStatus {
  video_status?: string;
  uploading_phase?: { status?: string; bytes_transferred?: number; error?: { message?: string } };
  processing_phase?: { status?: string; error?: { message?: string } };
  publishing_phase?: { status?: string; publish_status?: string; publish_time?: number; error?: { message?: string } };
}

export interface FbPage {
  id: string;
  name: string;
  access_token?: string;
  tasks?: string[];
  picture?: { data?: { url?: string } };
  instagram_business_account?: { id: string; username?: string };
}

/** Minimal, testable Graph API client. Every token-bearing call carries appsecret_proof. */
export class GraphClient {
  readonly base: string;
  private readonly fetchImpl: FetchLike;
  private readonly uploadImpl: BinaryUploader;
  private readonly timeoutMs: number;

  constructor(private readonly cfg: GraphConfig) {
    if (!/^v\d+\.\d+$/.test(cfg.version)) throw new Error(`Invalid META_GRAPH_VERSION: ${cfg.version}`);
    this.base = `https://graph.facebook.com/${cfg.version}`;
    this.fetchImpl = cfg.fetch ?? (globalThis.fetch as unknown as FetchLike);
    this.uploadImpl = cfg.uploadBinary ?? defaultBinaryUploader;
    this.timeoutMs = cfg.timeoutMs ?? 30_000;
  }

  get appToken(): string {
    return `${this.cfg.appId}|${this.cfg.appSecret}`;
  }

  private withAuth(params: Record<string, string | undefined>, token: string): URLSearchParams {
    const p = new URLSearchParams();
    for (const [k, v] of Object.entries(params)) if (v !== undefined) p.set(k, v);
    p.set("access_token", token);
    if (token !== this.appToken) p.set("appsecret_proof", appSecretProof(token, this.cfg.appSecret));
    return p;
  }

  async call<T>(method: "GET" | "POST" | "DELETE", path: string, token: string, params: Record<string, string | undefined> = {}): Promise<T> {
    const qs = this.withAuth(params, token);
    const url = path.startsWith("https://") ? path : `${this.base}/${path.replace(/^\//, "")}`;
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), this.timeoutMs);
    try {
      const res = method === "POST"
        ? await this.fetchImpl(url, { method, headers: { "Content-Type": "application/x-www-form-urlencoded" }, body: qs.toString(), signal: controller.signal })
        : await this.fetchImpl(`${url}?${qs.toString()}`, { method, signal: controller.signal });
      return parseGraphResponse<T>(res.status, await res.text());
    } finally {
      clearTimeout(timer);
    }
  }

  // ---- Auth / tokens -------------------------------------------------------------------------

  debugToken(inputToken: string) {
    return this.call<{ data: { app_id?: string; is_valid?: boolean; user_id?: string; expires_at?: number; data_access_expires_at?: number; scopes?: string[]; type?: string; profile_id?: string } }>(
      "GET", "debug_token", this.appToken, { input_token: inputToken });
  }

  exchangeForLongLived(shortLivedUserToken: string) {
    return this.call<{ access_token: string; expires_in?: number }>("GET", "oauth/access_token", this.appToken, {
      grant_type: "fb_exchange_token",
      client_id: this.cfg.appId,
      client_secret: this.cfg.appSecret,
      fb_exchange_token: shortLivedUserToken,
    });
  }

  me(userToken: string) {
    return this.call<{ id: string; name?: string }>("GET", "me", userToken, { fields: "id,name" });
  }

  async permissions(userToken: string): Promise<{ granted: string[]; declined: string[] }> {
    const r = await this.call<{ data: Array<{ permission: string; status: string }> }>("GET", "me/permissions", userToken);
    return {
      granted: r.data.filter((p) => p.status === "granted").map((p) => p.permission),
      declined: r.data.filter((p) => p.status !== "granted").map((p) => p.permission),
    };
  }

  async pages(userToken: string, maxPages = 10): Promise<FbPage[]> {
    const out: FbPage[] = [];
    let next: string | undefined = "me/accounts";
    let params: Record<string, string> = { fields: "id,name,tasks,access_token,picture{url},instagram_business_account{id,username}", limit: "100" };
    for (let i = 0; next && i < maxPages; i++) {
      const r: { data: FbPage[]; paging?: { cursors?: { after?: string }; next?: string } } = await this.call("GET", next, userToken, params);
      out.push(...r.data);
      next = r.paging?.next && r.paging.cursors?.after ? "me/accounts" : undefined;
      params = { ...params, after: r.paging?.cursors?.after ?? "" };
    }
    return out;
  }

  revokeAll(userToken: string) {
    return this.call<{ success: boolean }>("DELETE", "me/permissions", userToken);
  }

  // ---- Reels publishing (Page "video_reels" edge; three phases) ---------------------------

  /** Phase 1 – START: creates an upload session and returns the video id. */
  startReel(pageId: string, pageToken: string) {
    return this.call<{ video_id: string; upload_url?: string }>("POST", `${encodeURIComponent(pageId)}/video_reels`, pageToken, { upload_phase: "start" });
  }

  /** Phase 2 – UPLOAD (binary): streams the file to rupload.facebook.com. */
  async uploadReelBinary(videoId: string, pageToken: string, body: Readable, size: number, timeoutMs = 480_000): Promise<void> {
    const url = `https://rupload.facebook.com/video-upload/${this.cfg.version}/${encodeURIComponent(videoId)}`;
    const res = await this.uploadImpl(url, {
      Authorization: `OAuth ${pageToken}`,
      offset: "0",
      file_size: String(size),
      "Content-Type": "application/octet-stream",
      "Content-Length": String(size),
    }, body, timeoutMs);
    const parsed = parseGraphResponse<{ success?: boolean }>(res.status, res.body);
    if (parsed.success !== true) throw new GraphApiError("Video upload was not acknowledged by Facebook", res.status, undefined, undefined, undefined, true);
  }

  /** Phase 2 – UPLOAD (hosted): Meta fetches the file from a (signed) HTTPS URL. */
  async uploadReelHosted(videoId: string, pageToken: string, fileUrl: string): Promise<void> {
    const url = `https://rupload.facebook.com/video-upload/${this.cfg.version}/${encodeURIComponent(videoId)}`;
    const res = await this.fetchImpl(url, { method: "POST", headers: { Authorization: `OAuth ${pageToken}`, file_url: fileUrl } });
    const parsed = parseGraphResponse<{ success?: boolean }>(res.status, await res.text());
    if (parsed.success !== true) throw new GraphApiError("Video upload was not acknowledged by Facebook", res.status, undefined, undefined, undefined, true);
  }

  reelStatus(videoId: string, pageToken: string) {
    return this.call<{ status?: ReelStatus }>("GET", encodeURIComponent(videoId), pageToken, { fields: "status" }).then((r) => r.status ?? {});
  }

  /** Phase 3 – FINISH: publishes the uploaded video as a Reel with its description. */
  finishReel(pageId: string, pageToken: string, videoId: string, description: string) {
    return this.call<{ success?: boolean; post_id?: string }>("POST", `${encodeURIComponent(pageId)}/video_reels`, pageToken, {
      upload_phase: "finish",
      video_id: videoId,
      video_state: "PUBLISHED",
      description,
    });
  }

  async permalink(videoId: string, pageToken: string): Promise<string | null> {
    const r = await this.call<{ permalink_url?: string }>("GET", encodeURIComponent(videoId), pageToken, { fields: "permalink_url" });
    if (!r.permalink_url) return null;
    return r.permalink_url.startsWith("http") ? r.permalink_url : `https://www.facebook.com${r.permalink_url}`;
  }

  // ---- Instagram (the user's OWN professional account, via the official Instagram Graph API) ---

  async instagramMedia(igUserId: string, token: string, maxPages = 10) {
    const items: import("./instagram").IgMedia[] = [];
    let after: string | undefined;
    for (let i = 0; i < maxPages; i++) {
      const r: { data: import("./instagram").IgMedia[]; paging?: { cursors?: { after?: string }; next?: string } } = await this.call("GET", `${encodeURIComponent(igUserId)}/media`, token, {
        fields: "id,caption,media_type,media_product_type,permalink,media_url,thumbnail_url,timestamp",
        limit: "50",
        after,
      });
      items.push(...r.data);
      if (!r.paging?.next || !r.paging.cursors?.after) break;
      after = r.paging.cursors.after;
    }
    return items;
  }
}

export function parseGraphResponse<T>(status: number, text: string): T {
  let body: unknown;
  try {
    body = text ? JSON.parse(text) : {};
  } catch {
    throw new GraphApiError(`Unexpected response from Facebook (HTTP ${status})`, status, undefined, undefined, undefined, status >= 500);
  }
  const err = (body as { error?: { message?: string; code?: number; error_subcode?: number; type?: string; is_transient?: boolean; fbtrace_id?: string; error_user_msg?: string } }).error;
  if (err || status >= 400) {
    throw new GraphApiError(
      redact(err?.error_user_msg || err?.message || `HTTP ${status}`),
      status,
      err?.code,
      err?.error_subcode,
      err?.type,
      err?.is_transient,
      err?.fbtrace_id,
    );
  }
  return body as T;
}

const defaultBinaryUploader: BinaryUploader = (url, headers, body, timeoutMs) =>
  new Promise((resolve, reject) => {
    const req = httpsRequest(url, { method: "POST", headers, timeout: timeoutMs }, (res) => {
      const chunks: Buffer[] = [];
      res.on("data", (c: Buffer) => chunks.push(c));
      res.on("end", () => resolve({ status: res.statusCode ?? 0, body: Buffer.concat(chunks).toString("utf8") }));
      res.on("error", reject);
    });
    req.on("timeout", () => req.destroy(Object.assign(new Error("Upload timed out"), { name: "TimeoutError" })));
    req.on("error", reject);
    body.on("error", (e) => req.destroy(e));
    body.pipe(req);
  });
