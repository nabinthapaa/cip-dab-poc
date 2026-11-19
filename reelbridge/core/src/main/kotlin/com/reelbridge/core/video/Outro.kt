package com.reelbridge.core.video

/**
 * Optional outro appended to the end of a Reel (e.g. a logo sting or "Follow us" card).
 * Appending requires re-encoding, so the output size is chosen to stay within what phone
 * encoders support while keeping the main video's aspect ratio.
 */
object OutroRules {
    const val MIN_OUTRO_MS = 500L
    const val MAX_OUTRO_MS = 15_000L
    /** Longest side of the rendered Reel. 1920 keeps 1080x1920 Reels at full quality. */
    const val MAX_LONG_SIDE = 1920

    /** Checks the outro clip itself when the user picks it in Settings. */
    fun validateOutro(m: VideoMetadata): VideoValidation {
        val issues = mutableListOf<VideoIssue>()
        if (!m.hasVideoTrack) issues += VideoIssue("no_video_track", Severity.ERROR, "The outro file does not contain a video track.")
        val mime = m.mimeType?.lowercase()
        if (mime == null || mime !in ReelSpecs.ACCEPTED_MIME_TYPES) {
            issues += VideoIssue("format", Severity.ERROR, "The outro must be an MP4 or MOV video.")
        }
        if (m.durationMs < MIN_OUTRO_MS) issues += VideoIssue("outro_too_short", Severity.ERROR, "The outro is too short (minimum 0.5 seconds).")
        if (m.durationMs > MAX_OUTRO_MS) issues += VideoIssue("outro_too_long", Severity.ERROR, "The outro can be at most 15 seconds.")
        if (m.sizeBytes > 200L * 1024 * 1024) issues += VideoIssue("outro_too_large", Severity.ERROR, "The outro file is larger than 200 MB.")
        if (m.displayWidth > 0 && m.displayHeight > 0 &&
            kotlin.math.abs(m.aspectRatio - ReelSpecs.TARGET_ASPECT) > ReelSpecs.ASPECT_TOLERANCE
        ) {
            issues += VideoIssue("outro_aspect", Severity.WARNING, "The outro isn't vertical 9:16; it will be fitted with bars.")
        }
        return VideoValidation(issues)
    }

    /** Validates main video + outro as one Reel (the combined length must still fit Reels limits). */
    fun validateCombined(main: VideoMetadata, outro: VideoMetadata): VideoValidation {
        val combined = main.copy(durationMs = main.durationMs + outro.durationMs)
        val base = VideoValidator.validate(combined).issues.map { issue ->
            if (issue.code == "too_long") VideoIssue(
                "too_long_with_outro", Severity.ERROR,
                "With the outro this Reel is ${combined.durationMs / 1000} s; Facebook Page Reels can be at most 90 s. Turn off the outro or use a shorter video.",
            ) else issue
        }
        return VideoValidation(base + VideoIssue("reencode", Severity.WARNING, "Adding the outro re-encodes the video (high quality, same aspect ratio)."))
    }

    /** Output size: the main video's displayed size, scaled down to fit MAX_LONG_SIDE, even numbers. */
    fun renderSize(displayWidth: Int, displayHeight: Int): Pair<Int, Int> {
        if (displayWidth <= 0 || displayHeight <= 0) return 1080 to 1920
        val scale = minOf(1.0, MAX_LONG_SIDE.toDouble() / maxOf(displayWidth, displayHeight))
        fun even(v: Double) = maxOf(2, (v.toInt() / 2) * 2)
        return even(displayWidth * scale) to even(displayHeight * scale)
    }

    /** Encoder bitrate chosen to keep Reels visually lossless at their size (bits per second). */
    fun bitrate(width: Int, height: Int): Int = (width.toLong() * height * 5).coerceIn(4_000_000L, 16_000_000L).toInt()
}
