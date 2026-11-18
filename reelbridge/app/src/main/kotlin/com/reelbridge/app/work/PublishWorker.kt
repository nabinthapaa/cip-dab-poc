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

        val user = c.auth.currentUser ?: return fail("You are signed out. Open ReelBridge and connect Facebook again.")
        val draft = c.drafts.load(draftId) ?: return fail("The shared video is no longer available on this device.")
        val validation = VideoValidator.validate(draft.metadata)
        if (!validation.isPublishable) return fail(validation.errors.joinToString(" ") { it.message })

        runCatching { setForeground(foregroundInfo(null)) }

        return try {
            // Duplicate prevention #1: a job with this key already exists → nothing to do.
            val existing = c.jobs.fetch(key)
            if (existing != null) {
                Log.i(TAG, "Job already exists (${existing.status}); skipping duplicate")
                c.drafts.delete(draftId)
                Notifications.result(applicationContext, key, "Already shared", "This video was already sent to ${pageName ?: "your Page"}. Status: ${existing.status.label}.")
                return Result.success()
            }

            val mime = draft.metadata.mimeType ?: "video/mp4"
            val path = c.uploader.storagePath(user.uid, key, mime)
            var lastReported = -1
            c.uploader.upload(File(draft.videoPath), path, mime, draft.sha256) { p ->
                val pct = (p * 100).toInt()
                if (pct != lastReported) {
                    lastReported = pct
                    setProgressAsync(workDataOf(PROGRESS to p))
                    runCatching { setForegroundAsync(foregroundInfo(p)) }
                }
            }

            // Duplicate prevention #2: atomic create-if-absent of publishing_jobs/{key}.
            val created = c.jobs.createJobIfAbsent(
                key = key, uid = user.uid, pageId = pageId, pageName = pageName, caption = caption,
                storagePath = path, sha256 = draft.sha256, sizeBytes = draft.metadata.sizeBytes,
                durationMs = draft.metadata.durationMs, width = draft.metadata.displayWidth, height = draft.metadata.displayHeight,
            )
            if (created) c.queue.watch(key)
            c.drafts.keepThumbnail(draft, key)
            c.drafts.delete(draftId)
            Result.success(workDataOf(KEY_JOB to key))
        } catch (e: Exception) {
            Log.w(TAG, "Upload attempt $runAttemptCount failed: ${e.javaClass.simpleName}")
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

    override suspend fun getForegroundInfo(): ForegroundInfo = foregroundInfo(null)

    private fun foregroundInfo(progress: Float?): ForegroundInfo {
        val n = Notifications.progress(applicationContext, "Uploading Reel…", progress)
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
        const val KEY_ERROR = "error"
        const val PROGRESS = "progress"
    }
}
