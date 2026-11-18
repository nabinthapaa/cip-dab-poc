package com.reelbridge.app.media

import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import com.reelbridge.core.video.VideoMetadata
import java.io.File
import java.io.FileOutputStream

/**
 * Reads container metadata and extracts a preview frame. The original file is never re-encoded,
 * so aspect ratio and quality are preserved exactly as the user shared them.
 */
object VideoInspector {

    fun inspect(file: File, mimeType: String?): VideoMetadata {
        val r = MediaMetadataRetriever()
        return try {
            r.setDataSource(file.absolutePath)
            fun int(key: Int) = r.extractMetadata(key)?.toIntOrNull() ?: 0
            VideoMetadata(
                mimeType = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_MIMETYPE)?.let(::normalizeMime) ?: mimeType,
                sizeBytes = file.length(),
                durationMs = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull() ?: 0L,
                width = int(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH),
                height = int(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT),
                rotationDegrees = int(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION),
                hasVideoTrack = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_HAS_VIDEO) == "yes",
            )
        } catch (e: RuntimeException) {
            // Corrupt or non-video data: report it as such so validation fails with a clear message.
            VideoMetadata(mimeType, file.length(), 0, 0, 0, 0, hasVideoTrack = false)
        } finally {
            runCatching { r.release() }
        }
    }

    /** Writes a JPEG preview frame (≈1s in, or the first frame) to [out]. */
    fun writeThumbnail(file: File, out: File, maxSize: Int = 720): Boolean {
        val r = MediaMetadataRetriever()
        return try {
            r.setDataSource(file.absolutePath)
            val frame = r.getFrameAtTime(1_000_000, MediaMetadataRetriever.OPTION_CLOSEST_SYNC)
                ?: r.frameAtTime ?: return false
            val scale = maxSize.toFloat() / maxOf(frame.width, frame.height)
            val bmp = if (scale < 1f) Bitmap.createScaledBitmap(frame, (frame.width * scale).toInt(), (frame.height * scale).toInt(), true) else frame
            FileOutputStream(out).use { bmp.compress(Bitmap.CompressFormat.JPEG, 85, it) }
            true
        } catch (e: RuntimeException) {
            false
        } finally {
            runCatching { r.release() }
        }
    }

    /** MediaMetadataRetriever reports e.g. "video/mp4" or "video/quicktime"; map aliases. */
    fun normalizeMime(raw: String): String = when (raw.lowercase()) {
        "video/mov", "video/x-quicktime" -> "video/quicktime"
        "video/x-m4v", "video/m4v" -> "video/mp4"
        else -> raw.lowercase()
    }
}
