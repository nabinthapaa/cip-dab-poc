package com.reelbridge.app

import android.content.Context
import android.net.Uri
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.reelbridge.app.data.DraftStore
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

/**
 * Runs on a real Android device/emulator: copies a shared video into private storage, hashes it,
 * reads its metadata with MediaMetadataRetriever, extracts a thumbnail and validates it.
 */
@RunWith(AndroidJUnit4::class)
class DraftStoreInstrumentedTest {
    private val testContext = InstrumentationRegistry.getInstrumentation().context
    private val appContext: Context = InstrumentationRegistry.getInstrumentation().targetContext

    private fun assetUri(name: String): Uri {
        val out = File(appContext.cacheDir, name)
        testContext.assets.open(name).use { input -> out.outputStream().use { input.copyTo(it) } }
        return Uri.fromFile(out)
    }

    @Test fun validVerticalReelIsImportedHashedInspectedAndThumbnailed() = runBlocking {
        val store = DraftStore(appContext)
        val result = store.import(assetUri("reel_4s_540x960.mp4"), "video/mp4", "My reel https://www.instagram.com/reel/abc/")
        val d = result.draft
        try {
            // sha256sum of the committed asset
            assertEquals("89f602fe83adacd439b79f9b901951643fdde7fda14f7bb40546998638ce3117", d.sha256)
            assertEquals(107_231L, d.metadata.sizeBytes)
            assertEquals("video/mp4", d.metadata.mimeType)
            assertTrue("duration ${d.metadata.durationMs}", d.metadata.durationMs in 3_900L..4_100L)
            assertEquals(540, d.metadata.displayWidth)
            assertEquals(960, d.metadata.displayHeight)
            assertTrue(d.metadata.hasVideoTrack)
            assertTrue("issues: ${result.validation.issues}", result.validation.issues.isEmpty())
            assertTrue(result.validation.isPublishable)
            assertNotNull(d.thumbnailPath)
            assertTrue(File(d.thumbnailPath!!).length() > 0)
            assertTrue(File(d.videoPath).exists())
            // Draft metadata survives a reload (used by the background worker).
            assertEquals(d, store.load(d.id))
        } finally {
            store.delete(d.id)
        }
        assertNull(store.load(d.id))
    }

    @Test fun shortLandscapeVideoIsRejectedWithClearReasons() = runBlocking {
        val store = DraftStore(appContext)
        val result = store.import(assetUri("landscape_2s.mp4"), "video/mp4", null)
        try {
            assertFalse(result.validation.isPublishable)
            assertEquals(listOf("too_short"), result.validation.errors.map { it.code })
            assertEquals(setOf("low_resolution", "aspect_ratio"), result.validation.warnings.map { it.code }.toSet())
        } finally {
            store.delete(result.draft.id)
        }
    }

    @Test fun nonVideoDataIsNotPublishable() = runBlocking {
        val fake = File(appContext.cacheDir, "not_a_video.mp4").apply { writeText("this is not a video") }
        val store = DraftStore(appContext)
        val result = store.import(Uri.fromFile(fake), "video/mp4", null)
        try {
            assertFalse(result.validation.isPublishable)
            assertTrue(result.validation.errors.any { it.code == "no_video_track" })
        } finally {
            store.delete(result.draft.id)
        }
    }
}
