package com.reelbridge.app.data

import android.content.Context
import android.net.Uri
import com.reelbridge.app.media.VideoInspector
import com.reelbridge.core.video.OutroRules
import com.reelbridge.core.video.VideoMetadata
import com.reelbridge.core.video.VideoValidation
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.io.File

/** The user's outro clip, copied into private storage once and reused for every Reel. */
data class Outro(val videoPath: String, val thumbnailPath: String?, val sha256: String, val metadata: VideoMetadata)

class InvalidOutroException(val validation: VideoValidation) :
    Exception(validation.errors.joinToString(" ") { it.message })

class OutroStore(context: Context) {
    private val resolver = context.contentResolver
    private val dir = File(context.filesDir, "outro").apply { mkdirs() }
    private val metaFile = File(dir, "outro.json")
    private val _outro = MutableStateFlow(load())
    val outro: StateFlow<Outro?> = _outro

    fun current(): Outro? = _outro.value

    /** Imports and validates a new outro. The previous one is kept if the new clip is rejected. */
    suspend fun set(uri: Uri): Pair<Outro, VideoValidation> = withContext(Dispatchers.IO) {
        val staging = File(dir, "staging").apply { deleteRecursively(); mkdirs() }
        try {
            val mime = resolver.getType(uri)
            val video = File(staging, if (mime == "video/quicktime") "outro.mov" else "outro.mp4")
            val sha = copyWithSha256(resolver, uri, video, 200L * 1024 * 1024)
            val meta = VideoInspector.inspect(video, mime)
            val validation = OutroRules.validateOutro(meta)
            if (!validation.isPublishable) throw InvalidOutroException(validation)

            dir.listFiles()?.filter { it.isFile }?.forEach { it.delete() }
            val finalVideo = File(dir, video.name).also { video.renameTo(it) }
            val thumb = File(dir, "outro_thumb.jpg").takeIf { VideoInspector.writeThumbnail(finalVideo, it) }
            val outro = Outro(finalVideo.absolutePath, thumb?.absolutePath, sha, meta)
            save(outro)
            _outro.value = outro
            outro to validation
        } finally {
            staging.deleteRecursively()
        }
    }

    fun remove() {
        dir.listFiles()?.forEach { it.deleteRecursively() }
        _outro.value = null
    }

    private fun save(o: Outro) {
        val m = o.metadata
        metaFile.writeText(
            JSONObject()
                .put("videoPath", o.videoPath).put("thumbnailPath", o.thumbnailPath ?: "").put("sha256", o.sha256)
                .put("mimeType", m.mimeType ?: "").put("sizeBytes", m.sizeBytes).put("durationMs", m.durationMs)
                .put("width", m.width).put("height", m.height).put("rotation", m.rotationDegrees).put("hasVideo", m.hasVideoTrack)
                .toString()
        )
    }

    private fun load(): Outro? = runCatching {
        val j = JSONObject(metaFile.readText())
        Outro(
            videoPath = j.getString("videoPath"),
            thumbnailPath = j.optString("thumbnailPath").ifBlank { null },
            sha256 = j.getString("sha256"),
            metadata = VideoMetadata(
                j.optString("mimeType").ifBlank { null }, j.getLong("sizeBytes"), j.getLong("durationMs"),
                j.getInt("width"), j.getInt("height"), j.getInt("rotation"), j.getBoolean("hasVideo"),
            ),
        ).takeIf { File(it.videoPath).exists() }
    }.getOrNull()
}
