import { FieldValue, Timestamp, type Firestore } from "firebase-admin/firestore";
import type { Bucket } from "@google-cloud/storage";
import { decrypt, encrypt } from "./crypto";
import type { JobStore, Logger, TokenStore, VideoStore } from "./pipeline";
import { Collections, JobStatus, pageDocId, type PublishingJob } from "./model";

const TIME_FIELDS = ["leaseUntil", "nextRetryAt", "publishedAt", "updatedAt", "finishRequestedAt"];

function toMillis(v: unknown): number | null {
  if (v instanceof Timestamp) return v.toMillis();
  if (typeof v === "number") return v;
  return null;
}

/** Converts epoch-millis time fields from the pipeline into Firestore Timestamps. */
function toFirestore(patch: Record<string, unknown>): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(patch)) {
    out[k] = TIME_FIELDS.includes(k) && typeof v === "number" ? Timestamp.fromMillis(v) : v;
  }
  if (!("updatedAt" in out)) out.updatedAt = FieldValue.serverTimestamp();
  return out;
}

export function jobFromData(id: string, d: FirebaseFirestore.DocumentData): PublishingJob {
  return {
    id,
    uid: d.uid,
    reelId: d.reelId ?? id,
    pageId: d.pageId,
    pageName: d.pageName ?? null,
    caption: d.caption ?? "",
    storagePath: d.storagePath ?? null,
    source: d.source === "instagram" ? "instagram" : "device",
    igMediaId: d.igMediaId ?? null,
    status: d.status,
    attempts: d.attempts ?? 0,
    fbVideoId: d.fbVideoId ?? null,
    uploadComplete: d.uploadComplete === true,
    finishRequestedAt: toMillis(d.finishRequestedAt),
    leaseUntil: toMillis(d.leaseUntil),
    retryable: d.retryable === true,
    nextRetryAt: toMillis(d.nextRetryAt),
    errorMessage: d.errorMessage ?? null,
    errorCode: d.errorCode ?? null,
  };
}

export class FirestoreJobStore implements JobStore {
  constructor(private readonly db: Firestore) {}

  async claim(jobId: string, allowed: readonly string[], now: number, leaseMs: number): Promise<PublishingJob | null> {
    const ref = this.db.collection(Collections.JOBS).doc(jobId);
    return this.db.runTransaction(async (tx) => {
      const snap = await tx.get(ref);
      if (!snap.exists) return null;
      const d = snap.data()!;
      if (!allowed.includes(d.status)) return null;
      const lease = toMillis(d.leaseUntil);
      if (lease !== null && lease > now) return null; // another invocation holds it
      const polling = d.status === JobStatus.PROCESSING;
      const attempts = polling ? d.attempts ?? 0 : (d.attempts ?? 0) + 1;
      tx.update(ref, {
        leaseUntil: Timestamp.fromMillis(now + leaseMs),
        updatedAt: FieldValue.serverTimestamp(),
        ...(polling ? {} : { status: JobStatus.PUBLISHING, attempts, errorMessage: null, errorCode: null, nextRetryAt: null }),
      });
      return { ...jobFromData(jobId, d), attempts };
    });
  }

  async update(jobId: string, patch: Record<string, unknown>): Promise<void> {
    await this.db.collection(Collections.JOBS).doc(jobId).update(toFirestore(patch));
  }
}

export class FirestoreTokenStore implements TokenStore {
  constructor(private readonly db: Firestore, private readonly key: () => Buffer) {}

  async pageToken(uid: string, pageId: string): Promise<string | null> {
    const snap = await this.db.collection(Collections.PAGES).doc(pageDocId(uid, pageId)).collection(Collections.SECRETS).doc("token").get();
    const enc = snap.get("enc") as string | undefined;
    return enc ? decrypt(enc, this.key(), `page:${uid}:${pageId}`) : null;
  }

  async userToken(uid: string): Promise<string | null> {
    const snap = await this.db.collection(Collections.CONNECTIONS).doc(uid).collection(Collections.SECRETS).doc("user").get();
    const enc = snap.get("enc") as string | undefined;
    return enc ? decrypt(enc, this.key(), `user:${uid}`) : null;
  }

  sealPage(uid: string, pageId: string, token: string) {
    return { enc: encrypt(token, this.key(), `page:${uid}:${pageId}`), updatedAt: FieldValue.serverTimestamp() };
  }

  sealUser(uid: string, token: string) {
    return { enc: encrypt(token, this.key(), `user:${uid}`), updatedAt: FieldValue.serverTimestamp() };
  }
}

export class StorageVideoStore implements VideoStore {
  constructor(private readonly bucket: () => Bucket) {}

  async stat(path: string) {
    const file = this.bucket().file(path);
    const [exists] = await file.exists();
    if (!exists) return null;
    const [meta] = await file.getMetadata();
    return { size: Number(meta.size ?? 0), contentType: String(meta.contentType ?? ""), open: () => file.createReadStream() };
  }

  async signedUrl(path: string, ttlMs: number) {
    const [url] = await this.bucket().file(path).getSignedUrl({ action: "read", expires: Date.now() + ttlMs });
    return url;
  }

  async remove(path: string) {
    await this.bucket().file(path).delete({ ignoreNotFound: true });
  }
}

export class FirestoreLogger implements Logger {
  constructor(private readonly db: Firestore) {}

  async log(uid: string, jobId: string, level: "info" | "warn" | "error", event: string, message: string) {
    await this.db.collection(Collections.LOGS).add({ uid, jobId, level, event, message, at: FieldValue.serverTimestamp() })
      .catch(() => undefined); // logging must never break publishing
  }
}
