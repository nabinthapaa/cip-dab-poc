package com.reelbridge.app.work

import android.content.Context
import android.content.pm.ServiceInfo
import android.os.Build
import android.util.Log
import androidx.work.CoroutineWorker
import androidx.work.ForegroundInfo
import androidx.work.WorkerParameters
import androidx.work.workDataOf
import com.google.firebase.FirebaseNetworkException
import com.google.firebase.firestore.FirebaseFirestoreException
import com.google.firebase.storage.StorageException
import com.reelbridge.app.ReelBridgeApp
import com.reelbridge.core.video.VideoValidator
import java.io.File
import com.reelbridge.app.media.OutroRenderException
import com.reelbridge.app.media.OutroRenderer
import com.reelbridge.app.media.VideoInspector
import com.reelbridge.core.publish.IdempotencyKey
import com.reelbridge.core.video.OutroRules
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch

/**
 * Step 1 of publishing, on the device: upload the authorized video to Firebase Storage and create
 * the publishing job. The backend (Cloud Functions) takes over from there and talks to Meta.
 */
class PublishWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {

    override suspend fun doWork(): Result {
        val c = (applicationContext as ReelBridgeApp).container
        if (!c.firebaseReady) return fail("Firebase is not configured in this build.")
        val key = inputData.getString(KEY_JOB) ?: return Result.failure()
        val draftId = inputData.getString(KEY_DRAFT) ?: return Result.failure()
        val caption = inputData.getString(KEY_CAPTION).orEmpty()
        val pageId = inputData.getString(KEY_PAGE) ?: return Result.failure()
        val pageName = inputData.getString(KEY_PAGE_NAME)
        val outroSha = inputData.getString(KEY_OUTRO_SHA)

        val user = c.auth.currentUser ?: return fail("You are signed out. Open ReelBridge and connect Facebook again.")
        val draft = c.drafts.load(draftId) ?: return fail("The shared video is no longer available on this device.")
        val outro = if (outroSha == null) null else c.outros.current()?.takeIf { it.sha256 == outroSha }
            ?: return fail("Your outro was changed or removed after you shared this video. Share the video again.")
        val validation = if (outro == null) VideoValidator.validate(draft.metadata) else OutroRules.validateCombined(draft.metadata, outro.metadata)
        if (!validation.isPublishable) return fail(validation.errors.joinToString(" ") { it.message })
        val contentId = IdempotencyKey.contentId(draft.sha256, outro?.sha256)

        runCatching { setForeground(foregroundInfo(null, UPLOADING)) }

        return try {
            // Duplicate prevention #1: a job with this key already exists → nothing to do.
            val existing = c.jobs.fetch(key)
            if (existing != null) {
                Log.i(TAG, "Job already exists (${existing.status}); skipping duplicate")
                c.drafts.delete(draftId)
                Notifications.result(applicationContext, key, "Already shared", "This video was already sent to ${pageName ?: "your Page"}. Status: ${existing.status.label}.")
                return Result.success()
            }

            // Optional outro: render main + outro into one MP4 (kept across upload retries).
            var file = File(draft.videoPath)
            var meta = draft.metadata
            var mime = draft.metadata.mimeType ?: "video/mp4"
            if (outro != null) {
                val rendered = File(file.parentFile, "with_outro.mp4")
                val done = File(file.parentFile, "with_outro.done")
                if (!done.exists()) {
                    withProgress(RENDERING) { report ->
                        OutroRenderer.render(applicationContext, file, meta.displayWidth, meta.displayHeight, File(outro.videoPath), rendered, report)
                    }
                    done.createNewFile()
                }
                file = rendered
                meta = VideoInspector.inspect(rendered, "video/mp4")
                mime = "video/mp4"
                val check = VideoValidator.validate(meta)
                if (!check.isPublishable) return fail("The video with outro can't be published: " + check.errors.joinToString(" ") { it.message })
            }

            val path = c.uploader.storagePath(user.uid, key, mime)
            withProgress(UPLOADING) { report -> c.uploader.upload(file, path, mime, contentId, report) }

            // Duplicate prevention #2: atomic create-if-absent of publishing_jobs/{key}.
            val created = c.jobs.createJobIfAbsent(
                key = key, uid = user.uid, pageId = pageId, pageName = pageName, caption = caption,
                storagePath = path, sha256 = contentId, sizeBytes = meta.sizeBytes,
                durationMs = meta.durationMs, width = meta.displayWidth, height = meta.displayHeight,
            )
            if (created) c.queue.watch(key)
            c.drafts.keepThumbnail(draft, key)
            c.drafts.delete(draftId)
            Result.success(workDataOf(KEY_JOB to key))
        } catch (e: Exception) {
            Log.w(TAG, "Upload attempt $runAttemptCount failed: ${e.javaClass.simpleName}")
            if (e is OutroRenderException) return fail(e.message ?: "Couldn't add the outro.")
            if (isTransient(e) && runAttemptCount < MAX_ATTEMPTS) Result.retry()
            else fail("Upload failed: ${e.message ?: e.javaClass.simpleName}")
        }
    }

    private fun isTransient(e: Exception): Boolean = when (e) {
        is FirebaseNetworkException -> true
        is java.io.IOException -> true
        is StorageException -> e.isRecoverableException || e.errorCode == StorageException.ERROR_RETRY_LIMIT_EXCEEDED
        is FirebaseFirestoreException -> e.code == FirebaseFirestoreException.Code.UNAVAILABLE ||
            e.code == FirebaseFirestoreException.Code.DEADLINE_EXCEEDED
        else -> false
    }

    private fun fail(message: String): Result {
        Notifications.result(applicationContext, id.toString(), "Couldn't publish Reel", message)
        return Result.failure(workDataOf(KEY_ERROR to message))
    }

    /** Runs [block], reporting its 0..1 progress to WorkManager and the notification (percent steps, conflated). */
    private suspend fun withProgress(title: String, block: suspend (report: (Float) -> Unit) -> Unit) {
        val progress = MutableStateFlow(0)
        coroutineScope {
            val reporter = launch {
                progress.collect { pct ->
                    setProgress(workDataOf(PROGRESS to pct / 100f, STAGE to title))
                    runCatching { setForeground(foregroundInfo(pct / 100f, title)) }
                }
            }
            try {
                block { p -> progress.value = (p * 100).toInt().coerceIn(0, 100) }
            } finally {
                reporter.cancel()
            }
        }
    }

    override suspend fun getForegroundInfo(): ForegroundInfo = foregroundInfo(null, UPLOADING)

    private fun foregroundInfo(progress: Float?, title: String): ForegroundInfo {
        val n = Notifications.progress(applicationContext, title, progress)
        return if (Build.VERSION.SDK_INT >= 29) ForegroundInfo(NOTIFICATION_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        else ForegroundInfo(NOTIFICATION_ID, n)
    }

    companion object {
        private const val TAG = "PublishWorker"
        private const val NOTIFICATION_ID = 4201
        private const val MAX_ATTEMPTS = 8
        const val KEY_JOB = "job"
        const val KEY_DRAFT = "draft"
        const val KEY_CAPTION = "caption"
        const val KEY_PAGE = "page"
        const val KEY_PAGE_NAME = "pageName"
        const val KEY_OUTRO_SHA = "outroSha"
        const val STAGE = "stage"
        const val RENDERING = "Adding outro…"
        const val UPLOADING = "Uploading Reel…"
        const val KEY_ERROR = "error"
        const val PROGRESS = "progress"
    }
}
