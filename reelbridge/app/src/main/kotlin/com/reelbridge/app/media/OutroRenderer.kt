package com.reelbridge.app.media

import android.content.Context
import android.net.Uri
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.util.UnstableApi
import androidx.media3.effect.Presentation
import androidx.media3.transformer.Composition
import androidx.media3.transformer.DefaultEncoderFactory
import androidx.media3.transformer.EditedMediaItem
import androidx.media3.transformer.EditedMediaItemSequence
import androidx.media3.transformer.Effects
import androidx.media3.transformer.ExportException
import androidx.media3.transformer.ExportResult
import androidx.media3.transformer.ProgressHolder
import androidx.media3.transformer.Transformer
import androidx.media3.transformer.VideoEncoderSettings
import com.reelbridge.core.video.OutroRules
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlinx.coroutines.coroutineScope
import java.io.File
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

class OutroRenderException(message: String, cause: Throwable? = null) : Exception(message, cause)

/**
 * Appends the outro to the main video with Media3 Transformer (on-device, hardware encoders).
 *
 * - Output keeps the main video's displayed size and aspect ratio (scaled down only above 1920px);
 *   the outro is scaled to fit inside that frame (bars if its aspect differs).
 * - H.264 + AAC MP4 at a high bitrate ([OutroRules.bitrate]) so the re-encode stays visually lossless.
 * - A silent audio track is generated when one clip has sound and the other doesn't.
 */
@androidx.annotation.OptIn(markerClass = [UnstableApi::class])
object OutroRenderer {

    suspend fun render(
        context: Context,
        main: File,
        mainDisplayWidth: Int,
        mainDisplayHeight: Int,
        outro: File,
        output: File,
        onProgress: (Float) -> Unit = {},
    ) {
        val (w, h) = OutroRules.renderSize(mainDisplayWidth, mainDisplayHeight)
        val fit = Effects(emptyList(), listOf(Presentation.createForWidthAndHeight(w, h, Presentation.LAYOUT_SCALE_TO_FIT)))
        fun item(f: File) = EditedMediaItem.Builder(MediaItem.fromUri(Uri.fromFile(f))).setEffects(fit).build()

        val composition = Composition.Builder(listOf(EditedMediaItemSequence(listOf(item(main), item(outro)))))
            .experimentalSetForceAudioTrack(true)
            .build()

        output.delete()
        // Transformer must be created and driven from a thread with a Looper.
        withContext(Dispatchers.Main) {
            coroutineScope {
                val encoders = DefaultEncoderFactory.Builder(context.applicationContext)
                    .setRequestedVideoEncoderSettings(VideoEncoderSettings.Builder().setBitrate(OutroRules.bitrate(w, h)).build())
                    .build()
                var transformer: Transformer? = null
                val poller = launch {
                    val holder = ProgressHolder()
                    while (isActive) {
                        transformer?.let { t ->
                            if (t.getProgress(holder) == Transformer.PROGRESS_STATE_AVAILABLE) onProgress(holder.progress / 100f)
                        }
                        delay(250)
                    }
                }
                try {
                    suspendCancellableCoroutine { cont ->
                        val t = Transformer.Builder(context.applicationContext)
                            .setVideoMimeType(MimeTypes.VIDEO_H264)
                            .setAudioMimeType(MimeTypes.AUDIO_AAC)
                            .setEncoderFactory(encoders)
                            .addListener(object : Transformer.Listener {
                                override fun onCompleted(composition: Composition, exportResult: ExportResult) {
                                    if (cont.isActive) cont.resume(Unit)
                                }
                                override fun onError(composition: Composition, exportResult: ExportResult, exportException: ExportException) {
                                    if (cont.isActive) cont.resumeWithException(
                                        OutroRenderException("Couldn't add the outro (${exportException.errorCodeName}).", exportException)
                                    )
                                }
                            })
                            .build()
                        transformer = t
                        cont.invokeOnCancellation { t.cancel() }
                        t.start(composition, output.absolutePath)
                    }
                } finally {
                    poller.cancel()
                }
            }
        }
        if (!output.exists() || output.length() == 0L) throw OutroRenderException("Adding the outro produced no video.")
        onProgress(1f)
    }
}
