package com.reelbridge.core

import com.reelbridge.core.publish.IdempotencyKey
import com.reelbridge.core.video.*
import org.junit.Assert.*
import org.junit.Test

class OutroTest {
    private val main = VideoMetadata("video/mp4", 20_000_000, 30_000, 1080, 1920)
    private val outro = VideoMetadata("video/mp4", 1_000_000, 3_000, 1080, 1920)

    @Test fun validOutro() {
        assertTrue(OutroRules.validateOutro(outro).issues.isEmpty())
    }

    @Test fun outroLimits() {
        assertEquals(listOf("outro_too_long"), OutroRules.validateOutro(outro.copy(durationMs = 20_000)).errors.map { it.code })
        assertEquals(listOf("outro_too_short"), OutroRules.validateOutro(outro.copy(durationMs = 100)).errors.map { it.code })
        assertEquals(listOf("format"), OutroRules.validateOutro(outro.copy(mimeType = "video/webm")).errors.map { it.code })
        assertEquals(listOf("outro_aspect"), OutroRules.validateOutro(outro.copy(width = 1920, height = 1080)).warnings.map { it.code })
    }

    @Test fun combinedLengthMustFitReels() {
        assertTrue(OutroRules.validateCombined(main, outro).isPublishable)
        val tooLong = OutroRules.validateCombined(main.copy(durationMs = 88_000), outro)
        assertEquals(listOf("too_long_with_outro"), tooLong.errors.map { it.code })
        assertTrue(tooLong.warnings.any { it.code == "reencode" })
        // An outro can make a too-short clip long enough.
        assertTrue(OutroRules.validateCombined(main.copy(durationMs = 2_000), outro).isPublishable)
    }

    @Test fun renderSizeKeepsAspectAndEvenDimensions() {
        assertEquals(1080 to 1920, OutroRules.renderSize(1080, 1920))
        assertEquals(1080 to 1920, OutroRules.renderSize(2160, 3840))
        assertEquals(540 to 960, OutroRules.renderSize(540, 960))
        assertEquals(1920 to 1080, OutroRules.renderSize(3840, 2160))
        assertEquals(1080 to 1920, OutroRules.renderSize(0, 0))
        val (w, h) = OutroRules.renderSize(1001, 1777)
        assertTrue(w % 2 == 0 && h % 2 == 0)
    }

    @Test fun bitrateIsBounded() {
        assertEquals(10_368_000, OutroRules.bitrate(1080, 1920))
        assertEquals(4_000_000, OutroRules.bitrate(320, 568))
        assertEquals(16_000_000, OutroRules.bitrate(2160, 3840))
    }

    @Test fun contentIdDistinguishesOutro() {
        val plain = IdempotencyKey.contentId("ABC", null)
        assertEquals("abc", plain)
        val withOutro = IdempotencyKey.contentId("abc", "def")
        assertNotEquals(plain, withOutro)
        assertEquals(withOutro, IdempotencyKey.contentId("ABC", "DEF"))
        assertNotEquals(withOutro, IdempotencyKey.contentId("abc", "xyz"))
        assertTrue(IdempotencyKey.isValid(withOutro))
    }
}
