package com.reelbridge.app.data

import android.content.ContentResolver
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.OpenableColumns
import com.reelbridge.app.data.model.Draft
import com.reelbridge.app.data.model.InspectedDraft
import com.reelbridge.app.media.VideoInspector
import com.reelbridge.core.publish.IdempotencyKey
import com.reelbridge.core.video.ReelSpecs
import com.reelbridge.core.video.VideoMetadata
import com.reelbridge.core.video.VideoValidator
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.io.File
import java.io.IOException
import java.security.MessageDigest
import java.util.UUID

class DraftTooLargeException : IOException("The video is larger than 1 GB.")

/**
 * Copies shared videos into app-private storage immediately. Share-sheet URI grants are temporary,
 * so copying guarantees the background upload can still read the file later (even after reboot).
 */
class DraftStore(private val context: Context) {
    private val root = File(context.filesDir, "drafts").apply { mkdirs() }

    suspend fun import(uri: Uri, mimeHint: String?, captionHint: String?): InspectedDraft = withContext(Dispatchers.IO) {
        val resolver = context.contentResolver
        tryPersistPermission(resolver, uri)

        val declaredSize = querySize(resolver, uri)
        if (declaredSize != null && declaredSize > ReelSpecs.MAX_SIZE_BYTES) throw DraftTooLargeException()

        val id = UUID.randomUUID().toString()
        val dir = File(root, id).apply { mkdirs() }
        val mime = resolver.getType(uri) ?: mimeHint
        val video = File(dir, if (mime == "video/quicktime") "video.mov" else "video.mp4")

        val digest = MessageDigest.getInstance("SHA-256")
        try {
            val input = resolver.openInputStream(uri) ?: throw IOException("Cannot open the shared file")
            input.use { inp ->
                video.outputStream().use { out ->
                    val buf = ByteArray(256 * 1024)
                    var total = 0L
                    while (true) {
                        val n = inp.read(buf)
                        if (n < 0) break
                        total += n
                        if (total > ReelSpecs.MAX_SIZE_BYTES) throw DraftTooLargeException()
                        digest.update(buf, 0, n)
                        out.write(buf, 0, n)
                    }
                }
            }
        } catch (e: Exception) {
            dir.deleteRecursively()
            throw e
        }

        val metadata = VideoInspector.inspect(video, mime)
        val thumb = File(dir, "thumb.jpg").takeIf { VideoInspector.writeThumbnail(video, it) }
        val draft = Draft(
            id = id, videoPath = video.absolutePath, thumbnailPath = thumb?.absolutePath,
            sha256 = IdempotencyKey.hex(digest.digest()), metadata = metadata,
            captionHint = captionHint, createdAtMs = System.currentTimeMillis(),
        )
        save(draft)
        InspectedDraft(draft, VideoValidator.validate(metadata))
    }

    fun load(id: String): Draft? = runCatching {
        val j = JSONObject(File(File(root, id), "draft.json").readText())
        val m = j.getJSONObject("metadata")
        Draft(
            id = j.getString("id"),
            videoPath = j.getString("videoPath"),
            thumbnailPath = j.optString("thumbnailPath").ifBlank { null },
            sha256 = j.getString("sha256"),
            metadata = VideoMetadata(
                mimeType = m.optString("mimeType").ifBlank { null }, sizeBytes = m.getLong("sizeBytes"),
                durationMs = m.getLong("durationMs"), width = m.getInt("width"), height = m.getInt("height"),
                rotationDegrees = m.getInt("rotation"), hasVideoTrack = m.getBoolean("hasVideo"),
            ),
            captionHint = j.optString("captionHint").ifBlank { null },
            createdAtMs = j.getLong("createdAt"),
        )
    }.getOrNull()

    fun delete(id: String) { File(root, id).deleteRecursively() }

    private val thumbs = File(context.filesDir, "thumbs").apply { mkdirs() }

    /** Keeps the preview frame for the History/Publishing screens after the draft is deleted. */
    fun keepThumbnail(draft: Draft, jobId: String) {
        draft.thumbnailPath?.let { runCatching { File(it).copyTo(File(thumbs, "$jobId.jpg"), overwrite = true) } }
    }

    fun thumbnailFor(jobId: String): String? = File(thumbs, "$jobId.jpg").takeIf { it.exists() }?.absolutePath

    /** Removes drafts older than [maxAgeMs] that are not referenced by pending work. */
    fun prune(keep: Set<String>, maxAgeMs: Long = 7L * 24 * 3600 * 1000) {
        val cutoff = System.currentTimeMillis() - maxAgeMs
        root.listFiles()?.filter { it.name !in keep && it.lastModified() < cutoff }?.forEach { it.deleteRecursively() }
    }

    fun totalBytes(): Long = root.walkTopDown().filter { it.isFile }.sumOf { it.length() }

    private fun save(d: Draft) {
        val m = d.metadata
        val json = JSONObject()
            .put("id", d.id).put("videoPath", d.videoPath).put("thumbnailPath", d.thumbnailPath ?: "")
            .put("sha256", d.sha256).put("captionHint", d.captionHint ?: "").put("createdAt", d.createdAtMs)
            .put("metadata", JSONObject()
                .put("mimeType", m.mimeType ?: "").put("sizeBytes", m.sizeBytes).put("durationMs", m.durationMs)
                .put("width", m.width).put("height", m.height).put("rotation", m.rotationDegrees).put("hasVideo", m.hasVideoTrack))
        File(File(root, d.id), "draft.json").writeText(json.toString())
    }

    private fun querySize(resolver: ContentResolver, uri: Uri): Long? = runCatching {
        resolver.query(uri, arrayOf(OpenableColumns.SIZE), null, null, null)?.use { c ->
            if (c.moveToFirst() && !c.isNull(0)) c.getLong(0) else null
        }
    }.getOrNull()

    /** Persistable grants exist only for document-provider URIs; share-sheet grants throw, which is fine. */
    private fun tryPersistPermission(resolver: ContentResolver, uri: Uri) {
        runCatching { resolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION) }
    }
}
