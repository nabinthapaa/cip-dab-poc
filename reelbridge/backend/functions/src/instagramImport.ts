import { pipeline } from "node:stream/promises";
import { Readable, Transform } from "node:stream";
import type { ReadableStream as WebReadableStream } from "node:stream/web";
import { FieldValue, type Firestore } from "firebase-admin/firestore";
import type { Bucket } from "@google-cloud/storage";
import { HttpsError } from "firebase-functions/v2/https";
import type { GraphClient } from "./graph";
import { keyForInstagramMedia } from "./idempotency";
import { findByShortcode, instagramShortcode, isVideo, type IgMedia } from "./instagram";
import { Collections, JobStatus, MAX_CAPTION_LENGTH, MAX_VIDEO_BYTES, pageDocId } from "./model";
import type { FirestoreTokenStore } from "./store";

export interface InstagramDeps {
  db: Firestore;
  graph: GraphClient;
  tokens: FirestoreTokenStore;
  bucket: () => Bucket;
  fetch?: typeof globalThis.fetch;
}

export type Resolution =
  | { found: true; media: IgMedia; pageId: string; pageName: string }
  | { found: false; reason: "invalid_link" | "no_page" | "no_instagram_account" | "missing_permission" | "not_found" | "not_video"; message: string };

/**
 * Looks the shared link up in the media of the Instagram professional account that is linked to
 * the user's selected Facebook Page, using the official Instagram Graph API. Nothing is fetched
 * from instagram.com, and media owned by anyone else is never accessible this way.
 */
export async function resolve(deps: InstagramDeps, uid: string, url: unknown): Promise<Resolution> {
  const shortcode = instagramShortcode(url);
  if (!shortcode) return { found: false, reason: "invalid_link", message: "That isn't an Instagram Reel link." };

  const conn = await deps.db.collection(Collections.CONNECTIONS).doc(uid).get();
  const pageId = conn.get("selectedPageId") as string | undefined;
  if (!pageId) return { found: false, reason: "no_page", message: "Choose a Facebook Page in ReelBridge first." };
  const granted = (conn.get("grantedPermissions") as string[] | undefined) ?? [];
  if (!granted.includes("instagram_basic")) {
    return { found: false, reason: "missing_permission", message: "ReelBridge doesn't have permission to read your Instagram account (instagram_basic). Reconnect Facebook and allow it." };
  }
  const page = await deps.db.collection(Collections.PAGES).doc(pageDocId(uid, pageId)).get();
  const igUserId = page.get("igUserId") as string | undefined;
  if (!igUserId) {
    return { found: false, reason: "no_instagram_account", message: "Your Facebook Page has no linked Instagram professional account." };
  }
  const token = await deps.tokens.pageToken(uid, pageId);
  if (!token) throw new HttpsError("failed-precondition", "Facebook access for this Page is missing. Reconnect Facebook.");

  const media = findByShortcode(await deps.graph.instagramMedia(igUserId, token), shortcode);
  if (!media) {
    const handle = page.get("igUsername") ? `@${page.get("igUsername")}` : "your linked account";
    return { found: false, reason: "not_found", message: `This Reel wasn't found among the recent posts of ${handle}.` };
  }
  if (!isVideo(media)) return { found: false, reason: "not_video", message: "That Instagram post is not a video." };
  return { found: true, media, pageId, pageName: page.get("name") ?? "your Page" };
}

/** Creates the job (status "preparing"); the Firestore trigger copies the media and publishes. */
export async function createImportJob(deps: InstagramDeps, uid: string, url: unknown, caption: unknown) {
  const r = await resolve(deps, uid, url);
  if (!r.found) throw new HttpsError("failed-precondition", r.message);
  const text = typeof caption === "string" ? caption.slice(0, MAX_CAPTION_LENGTH) : (r.media.caption ?? "").slice(0, MAX_CAPTION_LENGTH);
  const key = keyForInstagramMedia(uid, r.media.id, r.pageId);
  const jobRef = deps.db.collection(Collections.JOBS).doc(key);

  return deps.db.runTransaction(async (tx) => {
    const existing = await tx.get(jobRef);
    if (existing.exists) return { jobId: key, duplicate: true, status: existing.get("status") as string };
    tx.create(deps.db.collection(Collections.REELS).doc(key), {
      uid, source: "instagram", igMediaId: r.media.id, igPermalink: r.media.permalink ?? null,
      caption: text, createdAt: FieldValue.serverTimestamp(),
    });
    tx.create(jobRef, {
      uid, reelId: key, pageId: r.pageId, pageName: r.pageName, caption: text, source: "instagram",
      igMediaId: r.media.id, thumbnailUrl: r.media.thumbnail_url ?? null, storagePath: null,
      status: JobStatus.PREPARING, attempts: 0,
      createdAt: FieldValue.serverTimestamp(), updatedAt: FieldValue.serverTimestamp(),
    });
    return { jobId: key, duplicate: false, status: JobStatus.PREPARING as string };
  });
}

const ALLOWED_MEDIA_HOSTS = [/\.cdninstagram\.com$/i, /\.fbcdn\.net$/i];

/** Only Meta's own CDNs are ever fetched (defends against SSRF via unexpected media_url values). */
export function isAllowedMediaUrl(raw: string): boolean {
  try {
    const u = new URL(raw);
    return u.protocol === "https:" && ALLOWED_MEDIA_HOSTS.some((re) => re.test(u.hostname));
  } catch {
    return false;
  }
}

/** Copies the Instagram media into Storage (size-capped) and returns its path. */
export async function copyMediaToStorage(deps: InstagramDeps, uid: string, jobId: string, igMediaId: string, pageId: string): Promise<string> {
  const token = await deps.tokens.pageToken(uid, pageId);
  if (!token) throw new HttpsError("failed-precondition", "Facebook access for this Page is missing.");
  const media = await deps.graph.call<IgMedia>("GET", encodeURIComponent(igMediaId), token, { fields: "id,media_type,media_url,media_product_type" });
  if (!media.media_url || !isVideo(media)) throw new Error("Instagram did not return a video URL for this post.");
  if (!isAllowedMediaUrl(media.media_url)) throw new Error("Instagram returned an unexpected media location.");

  const f = deps.fetch ?? globalThis.fetch;
  const res = await f(media.media_url, { redirect: "error" });
  if (!res.ok || !res.body) throw new Error(`Could not download the Instagram video (HTTP ${res.status}).`);
  const type = (res.headers.get("content-type") ?? "video/mp4").split(";")[0].trim().toLowerCase();
  if (!type.startsWith("video/")) throw new Error("Instagram media is not a video.");
  const declared = Number(res.headers.get("content-length") ?? "0");
  if (declared > MAX_VIDEO_BYTES) throw new Error("The Instagram video is larger than 1 GB.");

  const path = `users/${uid}/videos/${jobId}.mp4`;
  let total = 0;
  const limiter = new Transform({
    transform(chunk: Buffer, _enc, cb) {
      total += chunk.length;
      cb(total > MAX_VIDEO_BYTES ? new Error("The Instagram video is larger than 1 GB.") : null, chunk);
    },
  });
  await pipeline(
    Readable.fromWeb(res.body as unknown as WebReadableStream<Uint8Array>),
    limiter,
    deps.bucket().file(path).createWriteStream({ resumable: true, contentType: "video/mp4", metadata: { metadata: { source: "instagram", igMediaId } } }),
  );
  return path;
}
