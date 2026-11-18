import type { ReelStatus } from "./graph";

export type ReelState =
  | { state: "uploading" }
  | { state: "uploaded" } // bytes received, not yet finished/published
  | { state: "publishing" } // FINISH accepted, Meta is processing/publishing
  | { state: "published" }
  | { state: "error"; message: string };

/** Interprets GET /{video-id}?fields=status. Conservative: only "published" when Meta says so. */
export function interpretStatus(s: ReelStatus): ReelState {
  const phases = [s.uploading_phase, s.processing_phase, s.publishing_phase];
  const failed = phases.find((p) => p?.status === "error");
  if (failed || s.video_status === "error") {
    return { state: "error", message: failed?.error?.message || "Facebook could not process this video." };
  }
  if (s.video_status === "expired") return { state: "error", message: "The Facebook upload session expired." };

  const pub = s.publishing_phase;
  if (pub?.status === "complete" && (pub.publish_status === "published" || s.video_status === "ready")) return { state: "published" };
  if (pub?.status === "in_progress" || pub?.status === "complete") return { state: "publishing" };
  if (s.uploading_phase?.status === "complete") return { state: "uploaded" };
  return { state: "uploading" };
}

/** FINISH may be (re)sent only while the publishing phase has not started. */
export function canSendFinish(s: ReelStatus): boolean {
  const pub = s.publishing_phase?.status;
  return s.uploading_phase?.status === "complete" && (pub === undefined || pub === "not_started");
}
