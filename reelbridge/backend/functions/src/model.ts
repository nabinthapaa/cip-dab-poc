/**
 * Shared vocabulary. Status wire values MUST match
 * reelbridge/core/src/main/kotlin/com/reelbridge/core/publish/PublishStatus.kt
 */
export const JobStatus = {
  PREPARING: "preparing",
  UPLOADING: "uploading",
  QUEUED: "queued",
  PUBLISHING: "publishing",
  PROCESSING: "processing",
  PUBLISHED: "published",
  FAILED: "failed",
  NEEDS_RECONNECT: "needs_reconnect",
} as const;
export type JobStatus = (typeof JobStatus)[keyof typeof JobStatus];

export const TERMINAL: ReadonlySet<string> = new Set([JobStatus.PUBLISHED, JobStatus.FAILED, JobStatus.NEEDS_RECONNECT]);

export const Collections = {
  USERS: "users",
  CONNECTIONS: "facebook_connections",
  PAGES: "facebook_pages",
  REELS: "reels",
  JOBS: "publishing_jobs",
  LOGS: "publishing_logs",
  /** Subcollection under connections/pages holding encrypted tokens. Denied to all clients. */
  SECRETS: "secrets",
} as const;

export const REQUIRED_PERMISSIONS = ["pages_show_list", "pages_read_engagement", "pages_manage_posts"];
export const OPTIONAL_PERMISSIONS = ["instagram_basic", "business_management"];

export const MAX_VIDEO_BYTES = 1024 * 1024 * 1024;
export const ACCEPTED_VIDEO_TYPES = ["video/mp4", "video/quicktime"];
export const MAX_AUTOMATIC_ATTEMPTS = 3;
export const MAX_CAPTION_LENGTH = 2200;

export interface PublishingJob {
  id: string;
  uid: string;
  reelId: string;
  pageId: string;
  pageName?: string | null;
  caption: string;
  storagePath?: string | null;
  source: "device" | "instagram";
  igMediaId?: string | null;
  status: JobStatus;
  attempts: number;
  fbVideoId?: string | null;
  uploadComplete?: boolean;
  finishRequestedAt?: number | null;
  leaseUntil?: number | null;
  retryable?: boolean;
  nextRetryAt?: number | null;
  errorMessage?: string | null;
  errorCode?: string | null;
}

export function pageDocId(uid: string, pageId: string): string {
  return `${uid}_${pageId}`;
}
