package com.reelbridge.core

import com.reelbridge.core.video.*
import org.junit.Assert.*
import org.junit.Test

class VideoValidatorTest {
    private val good = VideoMetadata("video/mp4", 20_000_000, 30_000, 1080, 1920)

    @Test fun validVerticalVideo() {
        val v = VideoValidator.validate(good)
        assertTrue(v.isPublishable)
        assertTrue(v.issues.isEmpty())
    }

    @Test fun rotatedLandscapeContainerIsVertical() {
        val v = VideoValidator.validate(good.copy(width = 1920, height = 1080, rotationDegrees = 90))
        assertTrue(v.issues.isEmpty())
    }

    @Test fun rejectsBadFormatDurationAndSize() {
        val codes = VideoValidator.validate(good.copy(mimeType = "video/webm", durationMs = 120_000, sizeBytes = 2L shl 30)).errors.map { it.code }
        assertEquals(listOf("format", "too_large", "too_long"), codes)
    }

    @Test fun rejectsTooShortAndEmpty() {
        val codes = VideoValidator.validate(good.copy(durationMs = 1_000, sizeBytes = 0)).errors.map { it.code }
        assertTrue("too_short" in codes && "empty" in codes)
    }

    @Test fun warnsButAllowsLandscapeAndLowRes() {
        val v = VideoValidator.validate(good.copy(width = 640, height = 360))
        assertTrue(v.isPublishable)
        assertEquals(setOf("low_resolution", "aspect_ratio"), v.warnings.map { it.code }.toSet())
    }

    @Test fun quicktimeAccepted() {
        assertTrue(VideoValidator.validate(good.copy(mimeType = "video/quicktime")).isPublishable)
    }

    @Test fun noVideoTrack() {
        assertFalse(VideoValidator.validate(good.copy(hasVideoTrack = false)).isPublishable)
    }
}
