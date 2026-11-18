import { Readable } from "node:stream";
import { appSecretProof } from "../src/crypto";
import { GraphClient, type BinaryUploader, type FetchLike } from "../src/graph";
import type { JobStore, Logger, PipelineDeps, TokenStore, VideoStore } from "../src/pipeline";
import { JobStatus, type PublishingJob } from "../src/model";

export const APP_ID = "1234567890";
export const APP_SECRET = "test-app-secret";
export const PAGE_ID = "111222333";
export const PAGE_TOKEN = "EAAPAGETOKEN0123456789abcdefghijklmnop";
export const VIDEO_BYTES = Buffer.alloc(4096, 7);

type Phase = "not_started" | "in_progress" | "complete" | "error";
interface FakeVideo { id: string; uploaded: boolean; finishCount: number; pollsUntilPublished: number; uploadError?: boolean; processingError?: string }

/** In-memory stand-in for graph.facebook.com + rupload.facebook.com, enforcing the documented flow. */
export class FakeMeta {
  videos = new Map<string, FakeVideo>();
  calls: string[] = [];
  urls: string[] = [];
  nextId = 900;
  failStartWith?: { code: number; subcode?: number; status?: number };
  failUploadOnce = false;
  pollsUntilPublished = 2;
  processingError?: string;

  private err(status: number, code: number, message: string, subcode?: number) {
    return { status, body: JSON.stringify({ error: { message, code, error_subcode: subcode, type: "OAuthException", fbtrace_id: "trace" } }) };
  }

  private checkAuth(params: URLSearchParams): { status: number; body: string } | null {
    const token = params.get("access_token");
    if (token !== PAGE_TOKEN) return this.err(400, 190, "Invalid OAuth access token.");
    if (params.get("appsecret_proof") !== appSecretProof(token, APP_SECRET)) return this.err(400, 100, "Invalid appsecret_proof");
    return null;
  }

  handle(method: string, url: string, body?: string): { status: number; body: string } {
    this.urls.push(url);
    const u = new URL(url);
    const params = method === "POST" && body ? new URLSearchParams(body) : u.searchParams;
    const auth = this.checkAuth(params);
    if (auth) return auth;
    const path = u.pathname.replace(/^\/v\d+\.\d+\//, "");

    if (method === "POST" && path === `${PAGE_ID}/video_reels`) {
      const phase = params.get("upload_phase");
      if (phase === "start") {
        this.calls.push("start");
        if (this.failStartWith) return this.err(this.failStartWith.status ?? 400, this.failStartWith.code, "start failed", this.failStartWith.subcode);
        const id = String(this.nextId++);
        this.videos.set(id, { id, uploaded: false, finishCount: 0, pollsUntilPublished: this.pollsUntilPublished, processingError: this.processingError });
        return { status: 200, body: JSON.stringify({ video_id: id, upload_url: `https://rupload.facebook.com/video-upload/v26.0/${id}` }) };
      }
      if (phase === "finish") {
        this.calls.push("finish");
        const v = this.videos.get(params.get("video_id") ?? "");
        if (!v || !v.uploaded) return this.err(400, 6000, "Video not uploaded");
        if (params.get("video_state") !== "PUBLISHED") return this.err(400, 100, "bad video_state");
        v.finishCount++;
        return { status: 200, body: JSON.stringify({ success: true }) };
      }
    }
    if (method === "GET" && this.videos.has(path)) {
      const v = this.videos.get(path)!;
      if (u.searchParams.get("fields") === "permalink_url") return { status: 200, body: JSON.stringify({ permalink_url: `/reel/${v.id}` }) };
      this.calls.push("status");
      let up: Phase = v.uploaded ? "complete" : "not_started";
      if (v.uploadError) up = "error";
      let proc: Phase = "not_started";
      let pub: Phase = "not_started";
      let publishStatus = "not_published";
      if (v.finishCount > 0) {
        if (v.processingError) proc = "error";
        else if (v.pollsUntilPublished > 0) { v.pollsUntilPublished--; proc = "in_progress"; pub = "in_progress"; }
        else { proc = "complete"; pub = "complete"; publishStatus = "published"; }
      }
      return { status: 200, body: JSON.stringify({ status: {
        video_status: pub === "complete" ? "ready" : proc === "error" ? "error" : "processing",
        uploading_phase: { status: up },
        processing_phase: { status: proc, ...(proc === "error" ? { error: { message: v.processingError } } : {}) },
        publishing_phase: { status: pub, publish_status: publishStatus },
      }, id: v.id }) };
    }
    return this.err(404, 100, `Unknown path ${method} ${path}`, 33);
  }

  fetch: FetchLike = async (url, init) => {
    const r = this.handle(init?.method ?? "GET", url, init?.body);
    return { status: r.status, json: async () => JSON.parse(r.body), text: async () => r.body };
  };

  upload: BinaryUploader = async (url, headers, body) => {
    this.calls.push("upload");
    const chunks: Buffer[] = [];
    for await (const c of body) chunks.push(c as Buffer);
    const id = url.split("/").pop()!;
    const v = this.videos.get(id);
    if (headers.Authorization !== `OAuth ${PAGE_TOKEN}`) return this.err(401, 190, "bad token");
    if (!v) return this.err(400, 100, "no session");
    if (this.failUploadOnce) { this.failUploadOnce = false; return this.err(503, 1, "Service temporarily unavailable"); }
    if (Number(headers.file_size) !== Buffer.concat(chunks).length || headers.offset !== "0") return this.err(400, 100, "size mismatch");
    v.uploaded = true;
    return { status: 200, body: JSON.stringify({ success: true }) };
  };
}

export class MemoryJobs implements JobStore {
  jobs = new Map<string, PublishingJob & Record<string, unknown>>();
  async claim(jobId: string, allowed: readonly string[], now: number, leaseMs: number) {
    const j = this.jobs.get(jobId);
    if (!j || !allowed.includes(j.status)) return null;
    if (j.leaseUntil && j.leaseUntil > now) return null;
    const polling = j.status === JobStatus.PROCESSING;
    j.leaseUntil = now + leaseMs;
    if (!polling) { j.status = JobStatus.PUBLISHING; j.attempts += 1; }
    return { ...j };
  }
  async update(jobId: string, patch: Record<string, unknown>) {
    Object.assign(this.jobs.get(jobId)!, patch);
  }
}

export class MemoryLogger implements Logger {
  lines: string[] = [];
  async log(_uid: string, _job: string, level: string, event: string, message: string) { this.lines.push(`${level} ${event} ${message}`); }
}

export function makeDeps(meta: FakeMeta, opts: Partial<PipelineDeps> & { token?: string | null } = {}) {
  let clock = 1_000_000;
  const jobs = new MemoryJobs();
  const logger = new MemoryLogger();
  const removed: string[] = [];
  const tokens: TokenStore = { pageToken: async () => (opts.token === undefined ? PAGE_TOKEN : opts.token) };
  const videos: VideoStore = {
    stat: async (p) => (p.startsWith("users/") ? { size: VIDEO_BYTES.length, contentType: "video/mp4", open: () => Readable.from([VIDEO_BYTES]) } : null),
    signedUrl: async () => "https://storage.example/signed",
    remove: async (p) => { removed.push(p); },
  };
  const deps: PipelineDeps = {
    jobs, tokens, videos, logger,
    graph: new GraphClient({ appId: APP_ID, appSecret: APP_SECRET, version: "v26.0", fetch: meta.fetch, uploadBinary: meta.upload }),
    now: () => clock,
    sleep: async (ms) => { clock += ms; },
    uploadMode: "binary",
    deleteVideoAfterPublish: true,
    publishWaitMs: 60_000,
    pollIntervalMs: 5_000,
    leaseMs: 540_000,
    ...opts,
  };
  return { deps, jobs, logger, removed, advance: (ms: number) => { clock += ms; } };
}

export function newJob(id = "a".repeat(64), extra: Partial<PublishingJob> = {}): PublishingJob {
  return {
    id, uid: "user1", reelId: id, pageId: PAGE_ID, pageName: "My Page", caption: "Hello #reels",
    storagePath: `users/user1/videos/${id}.mp4`, source: "device", status: JobStatus.QUEUED, attempts: 0, ...extra,
  };
}
