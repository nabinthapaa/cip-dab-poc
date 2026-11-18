import { createHash } from "node:crypto";

/** Mirrors com.reelbridge.core.publish.IdempotencyKey. */
export function sha256Hex(value: string): string {
  return createHash("sha256").update(value, "utf8").digest("hex");
}
export function keyForVideo(uid: string, contentSha256: string, pageId: string): string {
  return sha256Hex(`v1|${uid}|video:${contentSha256.toLowerCase()}|${pageId}`);
}
export function keyForInstagramMedia(uid: string, igMediaId: string, pageId: string): string {
  return sha256Hex(`v1|${uid}|ig:${igMediaId}|${pageId}`);
}
export function isValidKey(key: unknown): key is string {
  return typeof key === "string" && /^[0-9a-f]{64}$/.test(key);
}
