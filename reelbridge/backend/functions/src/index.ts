/**
 * ReelBridge Cloud Functions (2nd gen).
 * All Meta credentials live here: the app secret and encryption key in Secret Manager, user/Page
 * tokens encrypted in Firestore subcollections that security rules deny to every client.
 */
import { initializeApp } from "firebase-admin/app";
import { getFirestore, Timestamp } from "firebase-admin/firestore";
import { getStorage } from "firebase-admin/storage";
import { setGlobalOptions } from "firebase-functions/v2";
import { HttpsError, onCall, type CallableRequest } from "firebase-functions/v2/https";
import { onDocumentCreated } from "firebase-functions/v2/firestore";
import { onSchedule } from "firebase-functions/v2/scheduler";
import { onTaskDispatched } from "firebase-functions/v2/tasks";
import { getFunctions } from "firebase-admin/functions";
import { defineSecret } from "firebase-functions/params";
import * as logger from "firebase-functions/logger";

import * as connection from "./connection";
import * as ig from "./instagramImport";
import { parseKey } from "./crypto";
import { GraphClient } from "./graph";
import { keyForVideo, isValidKey } from "./idempotency";
import { ACCEPTED_VIDEO_TYPES, Collections, JobStatus, MAX_AUTOMATIC_ATTEMPTS, MAX_CAPTION_LENGTH, MAX_VIDEO_BYTES, pageDocId } from "./model";
import { runJob, type PipelineDeps } from "./pipeline";
import { redact } from "./redact";
import { FirestoreJobStore, FirestoreLogger, FirestoreTokenStore, StorageVideoStore } from "./store";

initializeApp();
setGlobalOptions({ region: process.env.FUNCTIONS_REGION || "us-central1", maxInstances: 20 });


const META_APP_SECRET = defineSecret("META_APP_SECRET");
const TOKEN_ENCRYPTION_KEY = defineSecret("TOKEN_ENCRYPTION_KEY");
const SECRETS = [META_APP_SECRET, TOKEN_ENCRYPTION_KEY];
const ENFORCE_APP_CHECK = process.env.ENFORCE_APP_CHECK !== "false";

const db = () => getFirestore();
const bucket = () => getStorage().bucket();

function graph(): GraphClient {
  const appId = process.env.META_APP_ID;
  if (!appId) throw new HttpsError("failed-precondition", "Server misconfigured: META_APP_ID is not set.");
  return new GraphClient({ appId, appSecret: META_APP_SECRET.value(), version: process.env.META_GRAPH_VERSION || "v26.0" });
}
const tokenStore = () => new FirestoreTokenStore(db(), () => parseKey(TOKEN_ENCRYPTION_KEY.value()));
const connDeps = (): connection.ConnectionDeps => ({ db: db(), graph: graph(), tokens: tokenStore(), appId: process.env.META_APP_ID ?? "" });
const igDeps = (): ig.InstagramDeps => ({ db: db(), graph: graph(), tokens: tokenStore(), bucket });

function pipelineDeps(): PipelineDeps {
  return {
    jobs: new FirestoreJobStore(db()),
    tokens: tokenStore(),
    videos: new StorageVideoStore(bucket),
    graph: graph(),
    logger: new FirestoreLogger(db()),
    now: () => Date.now(),
    sleep: (ms) => new Promise((r) => setTimeout(r, ms)),
    uploadMode: process.env.REELS_UPLOAD_MODE === "hosted" ? "hosted" : "binary",
    deleteVideoAfterPublish: process.env.DELETE_VIDEO_AFTER_PUBLISH !== "false",
    publishWaitMs: 4 * 60_000,
    pollIntervalMs: 5_000,
    leaseMs: 9 * 60_000,
  };
}

const callOpts = { secrets: SECRETS, enforceAppCheck: ENFORCE_APP_CHECK, timeoutSeconds: 120, memory: "256MiB" as const };

function requireUid(req: CallableRequest): string {
  if (!req.auth) throw new HttpsError("unauthenticated", "Sign in first.");
  return req.auth.uid;
}

/** Wraps a callable so unexpected errors are logged (redacted) and returned as friendly messages. */
function guarded<T>(name: string, fn: (req: CallableRequest) => Promise<T>) {
  return onCall(callOpts, async (req) => {
    try {
      return await fn(req);
    } catch (err) {
      if (!(err instanceof HttpsError)) logger.error(`${name} failed`, { error: redact(err), uid: req.auth?.uid });
      throw connection.toHttpsError(err);
    }
  });
}

// ---- Facebook connection --------------------------------------------------------------------

export const connectFacebook = guarded("connectFacebook", async (req) => {
  const uid = requireUid(req);
  const token = req.data?.userAccessToken;
  if (typeof token !== "string" || token.length < 20 || token.length > 1024) throw new HttpsError("invalid-argument", "Missing Facebook access token.");
  const identities = (req.auth?.token.firebase as { identities?: Record<string, string[]> } | undefined)?.identities;
  return connection.connect(connDeps(), uid, identities?.["facebook.com"]?.[0], token);
});

export const refreshFacebookPages = guarded("refreshFacebookPages", async (req) => {
  const uid = requireUid(req);
  const deps = connDeps();
  const userToken = await deps.tokens.userToken(uid);
  if (!userToken) throw new HttpsError("failed-precondition", "Facebook isn't connected. Connect it first.");
  return connection.syncPages(deps, uid, userToken);
});

export const selectFacebookPage = guarded("selectFacebookPage", async (req) => {
  const uid = requireUid(req);
  const pageId = req.data?.pageId;
  if (typeof pageId !== "string" || !/^\d{1,30}$/.test(pageId)) throw new HttpsError("invalid-argument", "Invalid Page id.");
  await connection.selectPage(connDeps(), uid, pageId);
  return { ok: true };
});

export const checkFacebookConnection = guarded("checkFacebookConnection", async (req) => connection.check(connDeps(), requireUid(req)));

export const disconnectFacebook = guarded("disconnectFacebook", async (req) => {
  await connection.disconnect(connDeps(), requireUid(req), req.data?.revoke === true);
  return { ok: true };
});

// ---- Instagram (own account) -----------------------------------------------------------------

export const resolveInstagramReel = guarded("resolveInstagramReel", async (req) => {
  const r = await ig.resolve(igDeps(), requireUid(req), req.data?.url);
  return r.found
    ? { found: true, mediaId: r.media.id, caption: r.media.caption ?? "", thumbnailUrl: r.media.thumbnail_url ?? null }
    : { found: false, reason: r.reason, message: r.message };
});

export const importInstagramReel = guarded("importInstagramReel", async (req) =>
  ig.createImportJob(igDeps(), requireUid(req), req.data?.url, req.data?.caption));

// ---- Publishing --------------------------------------------------------------------------------

/**
 * Server-side validation of a client-created job before anything is sent to Meta. Security rules
 * already constrain the shape; this re-checks ownership, the Page, the idempotency key and the file.
 */
async function validateDeviceJob(jobId: string, d: FirebaseFirestore.DocumentData): Promise<string | null> {
  if (!isValidKey(jobId)) return "Invalid job id.";
  const expectedPrefix = `users/${d.uid}/videos/${jobId}.`;
  if (typeof d.storagePath !== "string" || !d.storagePath.startsWith(expectedPrefix)) return "Invalid video location.";
  if (typeof d.caption !== "string" || d.caption.length > MAX_CAPTION_LENGTH) return "Caption is too long.";
  const page = await db().collection(Collections.PAGES).doc(pageDocId(d.uid, d.pageId)).get();
  if (!page.exists || page.get("canPublish") !== true) return "You can't publish to the selected Page. Choose a Page again.";
  const file = bucket().file(d.storagePath);
  const [exists] = await file.exists();
  if (!exists) return "The uploaded video is missing. Share the video again.";
  const [meta] = await file.getMetadata();
  const size = Number(meta.size ?? 0);
  if (size <= 0 || size > MAX_VIDEO_BYTES) return "The video must be between 1 byte and 1 GB.";
  if (!ACCEPTED_VIDEO_TYPES.includes(String(meta.contentType))) return "Only MP4 or MOV videos can be published.";
  const sha = meta.metadata?.sha256;
  if (typeof sha !== "string" || keyForVideo(d.uid, sha, d.pageId) !== jobId) return "The job id doesn't match the uploaded video.";
  return null;
}

export const onPublishingJobCreated = onDocumentCreated(
  { document: `${Collections.JOBS}/{jobId}`, secrets: SECRETS, timeoutSeconds: 540, memory: "1GiB", retry: false },
  async (event) => {
    const jobId = event.params.jobId;
    const d = event.data?.data();
    if (!d) return;
    const ref = db().collection(Collections.JOBS).doc(jobId);
    try {
      if (d.source === "instagram" && d.status === JobStatus.PREPARING) {
        const path = await ig.copyMediaToStorage(igDeps(), d.uid, jobId, d.igMediaId, d.pageId);
        await ref.update({ storagePath: path, status: JobStatus.QUEUED, updatedAt: Timestamp.now() });
        await db().collection(Collections.REELS).doc(jobId).set({ storagePath: path }, { merge: true });
      } else if (d.status === JobStatus.QUEUED) {
        const problem = await validateDeviceJob(jobId, d);
        if (problem) {
          await ref.update({ status: JobStatus.FAILED, errorMessage: problem, errorCode: "validation", retryable: false, updatedAt: Timestamp.now() });
          return;
        }
      } else {
        return;
      }
      const result = await runJob(pipelineDeps(), jobId);
      logger.info("job finished", { jobId, result });
    } catch (err) {
      logger.error("job crashed", { jobId, error: redact(err) });
      await ref.update({
        status: JobStatus.FAILED, retryable: true, errorCode: "internal",
        errorMessage: "ReelBridge couldn't prepare this Reel. Tap Retry to try again.", leaseUntil: null, updatedAt: Timestamp.now(),
      }).catch(() => undefined);
    }
  });

export const retryPublishingJob = guarded("retryPublishingJob", async (req) => {
  const uid = requireUid(req);
  const jobId = req.data?.jobId;
  if (!isValidKey(jobId)) throw new HttpsError("invalid-argument", "Invalid job id.");
  const ref = db().collection(Collections.JOBS).doc(jobId);
  const snap = await ref.get();
  if (!snap.exists || snap.get("uid") !== uid) throw new HttpsError("not-found", "Job not found.");
  const status = snap.get("status");
  if (status === JobStatus.PUBLISHED) throw new HttpsError("failed-precondition", "This Reel is already published.");
  if (status !== JobStatus.FAILED && status !== JobStatus.NEEDS_RECONNECT) throw new HttpsError("failed-precondition", "This Reel is still being processed.");
  if (snap.get("retryable") === false) throw new HttpsError("failed-precondition", "This Reel can't be retried. Share the video again.");
  if (!snap.get("storagePath") && snap.get("source") !== "instagram") throw new HttpsError("failed-precondition", "The video file is missing. Share the video again.");

  await ref.update({ status: JobStatus.QUEUED, errorMessage: null, errorCode: null, nextRetryAt: null, leaseUntil: null, updatedAt: Timestamp.now() });
  await enqueueJob(jobId);
  return { queued: true };
});

const REGION = process.env.FUNCTIONS_REGION || "us-central1";

/** Hands a job to the Cloud Tasks queue so long uploads never run inside a client request. */
async function enqueueJob(jobId: string) {
  await getFunctions().taskQueue(`locations/${REGION}/functions/publishJobTask`).enqueue({ jobId });
}

export const publishJobTask = onTaskDispatched(
  { secrets: SECRETS, timeoutSeconds: 540, memory: "1GiB", retryConfig: { maxAttempts: 1 }, rateLimits: { maxConcurrentDispatches: 10 } },
  async (req) => {
    const jobId = req.data?.jobId;
    if (!isValidKey(jobId)) return;
    const ref = db().collection(Collections.JOBS).doc(jobId);
    const snap = await ref.get();
    if (!snap.exists) return;
    try {
      if (snap.get("source") === "instagram" && !snap.get("storagePath")) {
        const path = await ig.copyMediaToStorage(igDeps(), snap.get("uid"), jobId, snap.get("igMediaId"), snap.get("pageId"));
        await ref.update({ storagePath: path, updatedAt: Timestamp.now() });
      }
      logger.info("task job finished", { jobId, result: await runJob(pipelineDeps(), jobId) });
    } catch (err) {
      logger.error("task job crashed", { jobId, error: redact(err) });
      await ref.update({ status: JobStatus.FAILED, retryable: true, errorCode: "internal",
        errorMessage: "ReelBridge couldn't prepare this Reel. Tap Retry to try again.", leaseUntil: null, updatedAt: Timestamp.now() }).catch(() => undefined);
    }
  });

/** Every 5 minutes: follow up on jobs Meta is still processing, recover stale leases, auto-retry. */
export const publishingMaintenance = onSchedule(
  { schedule: "every 5 minutes", secrets: SECRETS, timeoutSeconds: 540, memory: "1GiB" },
  async () => {
    const now = Date.now();
    const jobs = db().collection(Collections.JOBS);
    const deps = { ...pipelineDeps(), publishWaitMs: 20_000 };
    const started = Date.now();
    const budget = () => Date.now() - started < 420_000;

    const processing = await jobs.where("status", "==", JobStatus.PROCESSING).limit(50).get();
    for (const doc of processing.docs) {
      if (!budget()) break;
      await runJob(deps, doc.id, "poll").catch((e) => logger.error("poll failed", { jobId: doc.id, error: redact(e) }));
    }

    const stale = await jobs.where("status", "==", JobStatus.PUBLISHING).where("leaseUntil", "<", Timestamp.fromMillis(now)).limit(20).get();
    for (const doc of stale.docs) {
      if (!budget()) break;
      await runJob(deps, doc.id).catch((e) => logger.error("recover failed", { jobId: doc.id, error: redact(e) }));
    }

    const due = await jobs.where("status", "==", JobStatus.FAILED).where("nextRetryAt", "<=", Timestamp.fromMillis(now)).limit(20).get();
    for (const doc of due.docs) {
      if (!budget()) break;
      if ((doc.get("attempts") ?? 0) >= MAX_AUTOMATIC_ATTEMPTS || doc.get("retryable") !== true) continue;
      await doc.ref.update({ status: JobStatus.QUEUED, nextRetryAt: null, updatedAt: Timestamp.now() });
      await runJob(deps, doc.id).catch((e) => logger.error("auto-retry failed", { jobId: doc.id, error: redact(e) }));
    }
  });
