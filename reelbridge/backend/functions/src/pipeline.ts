import type { Readable } from "node:stream";
import { classify, PermanentError, ReconnectRequiredError } from "./errors";
import type { GraphClient } from "./graph";
import { JobStatus, MAX_AUTOMATIC_ATTEMPTS, type PublishingJob } from "./model";
import { canSendFinish, interpretStatus } from "./reelStatus";
import { redact } from "./redact";
import { retryDelayMs } from "./retry";

// ---- Ports (implemented with Firestore/Storage in store.ts, with fakes in tests) ------------

export interface JobStore {
  /**
   * Atomically claims a job for processing. Returns null when it is not claimable (already
   * running under a live lease, already published, or not in an allowed status).
   */
  claim(jobId: string, allowed: readonly string[], now: number, leaseMs: number): Promise<PublishingJob | null>;
  update(jobId: string, patch: Partial<PublishingJob> & Record<string, unknown>): Promise<void>;
}
export interface TokenStore {
  pageToken(uid: string, pageId: string): Promise<string | null>;
}
export interface VideoObject {
  size: number;
  contentType: string;
  open(): Readable;
}
export interface VideoStore {
  stat(path: string): Promise<VideoObject | null>;
  signedUrl(path: string, ttlMs: number): Promise<string>;
  remove(path: string): Promise<void>;
}
export interface Logger {
  log(uid: string, jobId: string, level: "info" | "warn" | "error", event: string, message: string): Promise<void>;
}

export interface PipelineDeps {
  jobs: JobStore;
  tokens: TokenStore;
  videos: VideoStore;
  graph: GraphClient;
  logger: Logger;
  now: () => number;
  sleep: (ms: number) => Promise<void>;
  uploadMode: "binary" | "hosted";
  deleteVideoAfterPublish: boolean;
  /** How long to poll Meta inside one invocation before handing over to the scheduled poller. */
  publishWaitMs: number;
  pollIntervalMs: number;
  leaseMs: number;
}

export type RunResult = "skipped" | "published" | "processing" | "failed" | "needs_reconnect";

const CLAIMABLE_RUN = [JobStatus.QUEUED, JobStatus.PUBLISHING];
const CLAIMABLE_POLL = [JobStatus.PROCESSING];

/**
 * Runs (or resumes) one publishing job through Meta's START → UPLOAD → FINISH flow.
 *
 * Duplicate-publication safety:
 *  - one job per idempotency key (publishing_jobs/{key} is created at most once);
 *  - the job is claimed under a lease, so concurrent triggers/retries can't run it twice;
 *  - the Meta video id is checkpointed; a resumed job re-uses it and asks Meta for its status
 *    before doing anything, and FINISH is sent only while publishing has not started.
 */
export async function runJob(deps: PipelineDeps, jobId: string, mode: "run" | "poll" = "run"): Promise<RunResult> {
  const job = await deps.jobs.claim(jobId, mode === "run" ? CLAIMABLE_RUN : CLAIMABLE_POLL, deps.now(), deps.leaseMs);
  if (!job) return "skipped";
  const log = (level: "info" | "warn" | "error", event: string, msg: string) => deps.logger.log(job.uid, jobId, level, event, redact(msg));

  try {
    const token = await deps.tokens.pageToken(job.uid, job.pageId);
    if (!token) throw new ReconnectRequiredError("Facebook access for this Page is missing. Open ReelBridge and reconnect Facebook.");

    let videoId = job.fbVideoId ?? null;
    let uploadComplete = job.uploadComplete === true;

    // Resume: ask Meta where an existing session stands before doing anything else.
    if (videoId) {
      const st = await deps.graph.reelStatus(videoId, token);
      const state = interpretStatus(st);
      if (state.state === "published") return await markPublished(deps, job, videoId, token, log);
      if (state.state === "publishing") return await waitForPublish(deps, job, videoId, token, log);
      if (state.state === "error" || state.state === "uploading") {
        // An unfinished session can never become a post, so starting a new one cannot duplicate.
        await log("warn", "session_reset", `Previous upload session ${state.state}; starting a new one`);
        videoId = null;
        uploadComplete = false;
      } else {
        uploadComplete = true;
      }
    }

    if (!videoId) {
      const started = await deps.graph.startReel(job.pageId, token);
      if (!started.video_id) throw new PermanentError("Facebook did not create an upload session.");
      videoId = started.video_id;
      await deps.jobs.update(jobId, { fbVideoId: videoId, uploadComplete: false });
      await log("info", "start", `Upload session created (video ${videoId})`);
    }

    if (!uploadComplete) {
      if (!job.storagePath) throw new PermanentError("The video file for this job is missing.");
      const obj = await deps.videos.stat(job.storagePath);
      if (!obj) throw new PermanentError("The uploaded video file no longer exists. Share the video again.");
      if (deps.uploadMode === "hosted") {
        await deps.graph.uploadReelHosted(videoId, token, await deps.videos.signedUrl(job.storagePath, 30 * 60_000));
      } else {
        await deps.graph.uploadReelBinary(videoId, token, obj.open(), obj.size);
      }
      await deps.jobs.update(jobId, { uploadComplete: true });
      await log("info", "upload", `Uploaded ${obj.size} bytes to Facebook`);
    }

    // Wait until Meta confirms the bytes, then FINISH (only if publishing hasn't started).
    let st = await deps.graph.reelStatus(videoId, token);
    const uploadDeadline = deps.now() + 60_000;
    while (interpretStatus(st).state === "uploading" && deps.now() < uploadDeadline) {
      await deps.sleep(deps.pollIntervalMs);
      st = await deps.graph.reelStatus(videoId, token);
    }
    const s = interpretStatus(st);
    if (s.state === "error") throw new PermanentError(`Facebook couldn't process the video: ${s.message}`, "video_error");
    if (s.state === "published") return await markPublished(deps, job, videoId, token, log);

    if (canSendFinish(st)) {
      await deps.jobs.update(jobId, { finishRequestedAt: deps.now() });
      await deps.graph.finishReel(job.pageId, token, videoId, job.caption);
      await log("info", "finish", "Publish request accepted by Facebook");
    } else if (s.state === "uploading") {
      throw Object.assign(new Error("Facebook has not confirmed the upload yet"), { name: "TimeoutError" });
    }
    return await waitForPublish(deps, job, videoId, token, log);
  } catch (err) {
    return await markFailed(deps, job, err, log);
  }
}

async function waitForPublish(deps: PipelineDeps, job: PublishingJob, videoId: string, token: string, log: LogFn): Promise<RunResult> {
  const deadline = deps.now() + deps.publishWaitMs;
  for (;;) {
    const s = interpretStatus(await deps.graph.reelStatus(videoId, token));
    if (s.state === "published") return markPublished(deps, job, videoId, token, log);
    if (s.state === "error") throw new PermanentError(`Facebook couldn't publish the Reel: ${s.message}`, "publish_error");
    if (deps.now() >= deadline) {
      await deps.jobs.update(job.id, { status: JobStatus.PROCESSING, leaseUntil: null, updatedAt: deps.now() });
      await log("info", "processing", "Facebook is still processing; the scheduled checker will follow up");
      return "processing";
    }
    await deps.sleep(deps.pollIntervalMs);
  }
}

type LogFn = (level: "info" | "warn" | "error", event: string, msg: string) => Promise<void>;

async function markPublished(deps: PipelineDeps, job: PublishingJob, videoId: string, token: string, log: LogFn): Promise<RunResult> {
  const permalinkUrl = await deps.graph.permalink(videoId, token).catch(() => null);
  await deps.jobs.update(job.id, {
    status: JobStatus.PUBLISHED, publishedAt: deps.now(), permalinkUrl, leaseUntil: null,
    errorMessage: null, errorCode: null, retryable: false, nextRetryAt: null, updatedAt: deps.now(),
  });
  await log("info", "published", `Reel is live (video ${videoId})`);
  if (deps.deleteVideoAfterPublish && job.storagePath) await deps.videos.remove(job.storagePath).catch(() => undefined);
  return "published";
}

async function markFailed(deps: PipelineDeps, job: PublishingJob, err: unknown, log: LogFn): Promise<RunResult> {
  const c = classify(err);
  const attempts = job.attempts;
  const auto = c.kind === "retryable" && attempts < MAX_AUTOMATIC_ATTEMPTS;
  const status = c.kind === "reconnect" ? JobStatus.NEEDS_RECONNECT : JobStatus.FAILED;
  await deps.jobs.update(job.id, {
    status,
    errorMessage: c.userMessage + (c.kind === "retryable" && !auto ? " Tap Retry to try again." : ""),
    errorCode: c.code,
    // Reconnect failures become retryable once the user reconnects (manual Retry); permanent ones never are.
    retryable: c.kind !== "permanent",
    nextRetryAt: auto ? deps.now() + retryDelayMs(attempts) : null,
    leaseUntil: null,
    updatedAt: deps.now(),
  });
  await log(c.kind === "retryable" ? "warn" : "error", "failed", `${c.code}: ${redact(err)}`);
  return status === JobStatus.NEEDS_RECONNECT ? "needs_reconnect" : "failed";
}
