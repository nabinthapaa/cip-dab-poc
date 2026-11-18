package com.reelbridge.core.video

/** Metadata read from a local video file (no re-encoding is ever performed). */
data class VideoMetadata(
    val mimeType: String?,
    val sizeBytes: Long,
    val durationMs: Long,
    val width: Int,
    val height: Int,
    /** Rotation in degrees from the container (0, 90, 180, 270). */
    val rotationDegrees: Int = 0,
    val hasVideoTrack: Boolean = true,
) {
    /** Width as displayed, after applying rotation. */
    val displayWidth: Int get() = if (rotationDegrees % 180 != 0) height else width
    val displayHeight: Int get() = if (rotationDegrees % 180 != 0) width else height
    val aspectRatio: Double get() = if (displayHeight == 0) 0.0 else displayWidth.toDouble() / displayHeight
}

enum class Severity { ERROR, WARNING }

data class VideoIssue(val code: String, val severity: Severity, val message: String)

data class VideoValidation(val issues: List<VideoIssue>) {
    val errors get() = issues.filter { it.severity == Severity.ERROR }
    val warnings get() = issues.filter { it.severity == Severity.WARNING }
    val isPublishable get() = errors.isEmpty()
}

/**
 * Facebook Page Reels requirements (Meta "Reels Publishing API" video specs):
 * MP4/MOV container, 3–90 seconds, 9:16 recommended, at least 540x960 recommended.
 * Keep these in one place so they can be updated if Meta changes the specs.
 */
object ReelSpecs {
    val ACCEPTED_MIME_TYPES = setOf("video/mp4", "video/quicktime")
    const val MIN_DURATION_MS = 3_000L
    const val MAX_DURATION_MS = 90_000L
    const val MAX_SIZE_BYTES = 1L * 1024 * 1024 * 1024 // 1 GiB, enforced by Storage rules too
    const val MIN_WIDTH = 540
    const val MIN_HEIGHT = 960
    const val TARGET_ASPECT = 9.0 / 16.0
    const val ASPECT_TOLERANCE = 0.02
}

object VideoValidator {
    fun validate(m: VideoMetadata): VideoValidation {
        val issues = mutableListOf<VideoIssue>()
        val mime = m.mimeType?.lowercase()

        if (!m.hasVideoTrack) {
            issues += VideoIssue("no_video_track", Severity.ERROR, "This file does not contain a video track.")
        }
        if (mime == null || mime !in ReelSpecs.ACCEPTED_MIME_TYPES) {
            issues += VideoIssue(
                "format", Severity.ERROR,
                "Unsupported format (${m.mimeType ?: "unknown"}). Facebook Reels need an MP4 or MOV video.",
            )
        }
        if (m.sizeBytes <= 0) {
            issues += VideoIssue("empty", Severity.ERROR, "The video file is empty.")
        } else if (m.sizeBytes > ReelSpecs.MAX_SIZE_BYTES) {
            issues += VideoIssue("too_large", Severity.ERROR, "The video is larger than 1 GB.")
        }
        if (m.durationMs < ReelSpecs.MIN_DURATION_MS) {
            issues += VideoIssue("too_short", Severity.ERROR, "Reels must be at least 3 seconds long.")
        } else if (m.durationMs > ReelSpecs.MAX_DURATION_MS) {
            issues += VideoIssue(
                "too_long", Severity.ERROR,
                "Facebook Page Reels can be at most 90 seconds (this video is ${m.durationMs / 1000} s).",
            )
        }
        if (m.displayWidth > 0 && m.displayHeight > 0) {
            if (m.displayWidth < ReelSpecs.MIN_WIDTH || m.displayHeight < ReelSpecs.MIN_HEIGHT) {
                issues += VideoIssue(
                    "low_resolution", Severity.WARNING,
                    "Resolution ${m.displayWidth}x${m.displayHeight} is below the recommended 540x960.",
                )
            }
            if (kotlin.math.abs(m.aspectRatio - ReelSpecs.TARGET_ASPECT) > ReelSpecs.ASPECT_TOLERANCE) {
                issues += VideoIssue(
                    "aspect_ratio", Severity.WARNING,
                    "The video is not vertical 9:16. Facebook may show it with bars.",
                )
            }
        } else {
            issues += VideoIssue("unknown_dimensions", Severity.WARNING, "Could not read the video resolution.")
        }
        return VideoValidation(issues)
    }
}
