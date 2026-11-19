package com.reelbridge.app

import android.content.Context
import android.media.MediaMetadataRetriever
import android.net.Uri
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.reelbridge.app.data.InvalidOutroException
import com.reelbridge.app.data.OutroStore
import com.reelbridge.app.media.OutroRenderer
import com.reelbridge.app.media.VideoInspector
import com.reelbridge.core.video.VideoValidator
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

/** Real on-device rendering with Media3 Transformer: main video + outro → one publishable MP4. */
@RunWith(AndroidJUnit4::class)
class OutroInstrumentedTest {
    private val testContext = InstrumentationRegistry.getInstrumentation().context
    private val appContext: Context = InstrumentationRegistry.getInstrumentation().targetContext

    private fun asset(name: String): File = File(appContext.cacheDir, name).also { out ->
        testContext.assets.open(name).use { input -> out.outputStream().use { input.copyTo(it) } }
    }

    @After fun cleanup() = OutroStore(appContext).remove()

    private fun hasAudio(f: File): Boolean = MediaMetadataRetriever().run {
        try { setDataSource(f.absolutePath); extractMetadata(MediaMetadataRetriever.METADATA_KEY_HAS_AUDIO) == "yes" } finally { release() }
    }

    @Test fun appendsSquareOutroToVerticalReelKeepingSize() = runBlocking {
        val out = File(appContext.cacheDir, "rendered_silent.mp4")
        var lastProgress = 0f
        OutroRenderer.render(appContext, asset("reel_4s_540x960.mp4"), 540, 960, asset("outro_2s_square.mp4"), out) { lastProgress = it }
        val m = VideoInspector.inspect(out, "video/mp4")
        assertEquals("video/mp4", m.mimeType)
        assertEquals(540, m.displayWidth)
        assertEquals(960, m.displayHeight)
        assertTrue("duration ${m.durationMs}", m.durationMs in 5_700L..6_400L)
        assertEquals(1f, lastProgress)
        assertTrue(VideoValidator.validate(m).isPublishable)
    }

    @Test fun silentOutroAfterVideoWithSoundKeepsAnAudioTrack() = runBlocking {
        val out = File(appContext.cacheDir, "rendered_audio.mp4")
        OutroRenderer.render(appContext, asset("reel_3s_audio.mp4"), 540, 960, asset("outro_2s_square.mp4"), out)
        val m = VideoInspector.inspect(out, "video/mp4")
        assertTrue("duration ${m.durationMs}", m.durationMs in 4_700L..5_400L)
        assertTrue(hasAudio(out))
        assertEquals(540 to 960, m.displayWidth to m.displayHeight)
    }

    @Test fun outroStoreSavesValidClipAndRejectsBadOnes() = runBlocking {
        val store = OutroStore(appContext)
        val (saved, validation) = store.set(Uri.fromFile(asset("outro_2s_square.mp4")))
        assertEquals("9bd103ad199f88c1f67454e1fb8b37a93260c85781e6ed3f83bc01440d8fef64", saved.sha256)
        assertTrue(validation.isPublishable)
        assertEquals(setOf("outro_aspect"), validation.warnings.map { it.code }.toSet())
        assertTrue(File(saved.videoPath).exists())
        assertNotNull(saved.thumbnailPath)
        // Survives a restart (new instance reads the saved metadata).
        assertEquals(saved, OutroStore(appContext).current())

        val junk = File(appContext.cacheDir, "junk.mp4").apply { writeText("not a video") }
        try {
            store.set(Uri.fromFile(junk)); fail("junk accepted")
        } catch (e: InvalidOutroException) { /* expected */ }
        assertEquals(saved, store.current()) // previous outro kept

        store.remove()
        assertNull(store.current())
        assertNull(OutroStore(appContext).current())
    }
}
