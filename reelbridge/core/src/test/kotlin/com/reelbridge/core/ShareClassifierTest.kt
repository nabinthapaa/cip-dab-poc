package com.reelbridge.core

import com.reelbridge.core.share.*
import org.junit.Assert.*
import org.junit.Test

class ShareClassifierTest {
    private fun input(
        action: String? = ShareClassifier.ACTION_SEND,
        mime: String? = "text/plain",
        text: String? = null,
        streams: List<SharedStream> = emptyList(),
    ) = ShareInput(action, mime, text, null, streams)

    @Test fun instagramReelLinkFromShareSheet() {
        val p = ShareClassifier.classify(input(text = "https://www.instagram.com/reel/C9xYz_1-AbC/?igsh=MWQ1ZGUxMzBkMA=="))
        assertTrue(p is SharedPayload.InstagramLink)
        p as SharedPayload.InstagramLink
        assertEquals("C9xYz_1-AbC", p.shortcode)
        assertEquals(InstagramLinkKind.REEL, p.kind)
        assertEquals("https://www.instagram.com/reel/C9xYz_1-AbC/", p.url)
    }

    @Test fun instagramLinkEmbeddedInText() {
        val p = ShareClassifier.classify(input(text = "Check this out! https://instagram.com/reels/AbC123/ so good"))
        assertEquals("AbC123", (p as SharedPayload.InstagramLink).shortcode)
    }

    @Test fun instagramPostAndUsernamePrefixedUrls() {
        assertEquals(InstagramLinkKind.POST, (InstagramUrls.parse("https://www.instagram.com/p/XyZ987/")!!).kind)
        assertEquals("Q1w2", InstagramUrls.parse("https://www.instagram.com/someuser/reel/Q1w2/")!!.shortcode)
        assertNull(InstagramUrls.parse("https://www.instagram.com/someuser/"))
        assertNull(InstagramUrls.parse("https://example.com/reel/abc"))
    }

    @Test fun storyIsRejected() {
        val p = ShareClassifier.classify(input(text = "https://www.instagram.com/stories/user/3333/"))
        assertEquals(UnsupportedReason.INSTAGRAM_STORY, (p as SharedPayload.Unsupported).reason)
    }

    @Test fun otherLink() {
        val p = ShareClassifier.classify(input(text = "https://youtube.com/watch?v=1"))
        assertTrue(p is SharedPayload.OtherLink)
    }

    @Test fun plainTextWithoutLink() {
        val p = ShareClassifier.classify(input(text = "hello"))
        assertEquals(UnsupportedReason.TEXT_WITHOUT_LINK, (p as SharedPayload.Unsupported).reason)
    }

    @Test fun emptyShare() {
        assertEquals(UnsupportedReason.EMPTY, (ShareClassifier.classify(input()) as SharedPayload.Unsupported).reason)
    }

    @Test fun videoStreamWithCaptionHintStripsUrl() {
        val p = ShareClassifier.classify(
            input(mime = "video/mp4", text = "My reel https://instagram.com/reel/abc/", streams = listOf(SharedStream("content://a", "video/mp4")))
        )
        p as SharedPayload.Videos
        assertEquals(1, p.streams.size)
        assertEquals("My reel", p.captionHint)
    }

    @Test fun multipleStreamsKeepsOnlyVideos() {
        val p = ShareClassifier.classify(
            input(
                action = ShareClassifier.ACTION_SEND_MULTIPLE, mime = "*/*",
                streams = listOf(SharedStream("content://a", "image/jpeg"), SharedStream("content://b", "video/quicktime")),
            )
        )
        assertEquals(listOf("content://b"), (p as SharedPayload.Videos).streams.map { it.uri })
    }

    @Test fun streamMimeFallsBackToIntentType() {
        val p = ShareClassifier.classify(input(mime = "video/*", streams = listOf(SharedStream("content://a", null))))
        assertTrue(p is SharedPayload.Videos)
    }

    @Test fun imageOnlyIsNotAVideo() {
        val p = ShareClassifier.classify(input(mime = "image/png", streams = listOf(SharedStream("content://a", "image/png"))))
        assertEquals(UnsupportedReason.NOT_A_VIDEO, (p as SharedPayload.Unsupported).reason)
    }

    @Test fun unknownAction() {
        val p = ShareClassifier.classify(input(action = "android.intent.action.VIEW", text = "https://instagram.com/reel/a/"))
        assertEquals(UnsupportedReason.UNKNOWN_ACTION, (p as SharedPayload.Unsupported).reason)
    }
}
