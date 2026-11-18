package com.reelbridge.core

import com.reelbridge.core.caption.CaptionBuilder
import com.reelbridge.core.publish.*
import org.junit.Assert.*
import org.junit.Test

class CaptionAndKeysTest {
    @Test fun captionRemovesLinksAndAddsHashtags() {
        val c = CaptionBuilder.build("Sunset vibes  https://www.instagram.com/reel/abc/", null, "travel, #sunset")
        assertEquals("Sunset vibes\n\n#travel #sunset", c)
    }

    @Test fun captionTemplateAndDedupedTags() {
        val c = CaptionBuilder.build("Hello #travel", "{caption}\nFollow for more!", "#travel #new")
        assertEquals("Hello #travel\nFollow for more!\n\n#new", c)
    }

    @Test fun captionWithoutPlaceholderAppendsTemplate() {
        assertEquals("Hi\n\nSigned", CaptionBuilder.build("Hi", "Signed", null))
    }

    @Test fun emptyCaption() {
        assertEquals("", CaptionBuilder.build(null, null, null))
    }

    @Test fun captionIsTruncated() {
        val c = CaptionBuilder.build("a".repeat(5000), null, null)
        assertEquals(CaptionBuilder.MAX_LENGTH, c.length)
        assertTrue(c.endsWith("…"))
    }

    @Test fun hashtagsIgnoreGarbage() {
        assertEquals(listOf("#ok", "#fine_1"), CaptionBuilder.normalizeHashtags("ok bad-tag #fine_1 OK"))
    }

    @Test fun idempotencyKeyIsStableAndScoped() {
        val a = IdempotencyKey.forVideo("u1", "ABCDEF", "p1")
        assertEquals(a, IdempotencyKey.forVideo("u1", "abcdef", "p1"))
        assertNotEquals(a, IdempotencyKey.forVideo("u1", "abcdef", "p2"))
        assertNotEquals(a, IdempotencyKey.forVideo("u2", "abcdef", "p1"))
        assertNotEquals(a, IdempotencyKey.forInstagramMedia("u1", "abcdef", "p1"))
        assertTrue(IdempotencyKey.isValid(a))
        assertFalse(IdempotencyKey.isValid("xyz"))
    }

    @Test fun idempotencyKeyMatchesBackendVector() {
        // The same vector is asserted in backend/functions/test/idempotency.test.ts
        assertEquals(
            "bb18eae0c883cca44cc253d8b69ea8b5a18177315651eaef1e16a02d9d1bf96c",
            IdempotencyKey.forVideo("uid", "00", "page"),
        )
    }

    @Test fun statusWireRoundTripAndFilters() {
        PublishStatus.entries.forEach { assertEquals(it, PublishStatus.fromWire(it.wire)) }
        assertEquals(PublishStatus.FAILED, PublishStatus.fromWire("garbage"))
        assertTrue(HistoryFilter.PENDING.matches(PublishStatus.PROCESSING))
        assertTrue(HistoryFilter.FAILED.matches(PublishStatus.NEEDS_RECONNECT))
        assertFalse(HistoryFilter.PUBLISHED.matches(PublishStatus.QUEUED))
    }

    @Test fun retryBackoff() {
        assertEquals(60_000L, RetryPolicy.delayMs(1))
        assertEquals(120_000L, RetryPolicy.delayMs(2))
        assertEquals(30 * 60_000L, RetryPolicy.delayMs(20))
        assertTrue(RetryPolicy.shouldAutoRetry(1, true))
        assertFalse(RetryPolicy.shouldAutoRetry(3, true))
        assertFalse(RetryPolicy.shouldAutoRetry(1, false))
    }
}
