package com.reelbridge.app.work

import android.content.Context
import androidx.work.CoroutineWorker
import androidx.work.WorkerParameters
import com.reelbridge.app.ReelBridgeApp
import com.reelbridge.core.publish.PublishStatus

/**
 * Follows a server-side publishing job until it finishes and notifies the user of the outcome.
 * The authoritative state lives in Firestore; this only reads it.
 */
class JobWatchWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {
    override suspend fun doWork(): Result {
        val c = (applicationContext as ReelBridgeApp).container
        if (!c.firebaseReady || c.auth.currentUser == null) return Result.success()
        val jobId = inputData.getString(KEY_JOB) ?: return Result.failure()
        val job = runCatching { c.jobs.fetch(jobId) }.getOrElse { return Result.retry() } ?: return Result.success()

        if (!job.status.isTerminal) {
            // Meta processing can take several minutes; give up watching after ~1 hour (history still updates).
            return if (runAttemptCount < 40) Result.retry() else Result.success()
        }
        if (c.settings.current().notifications) {
            val page = job.pageName ?: "your Facebook Page"
            when (job.status) {
                PublishStatus.PUBLISHED -> Notifications.result(applicationContext, jobId, "Reel published 🎉", "Your Reel is live on $page.")
                PublishStatus.NEEDS_RECONNECT -> Notifications.result(applicationContext, jobId, "Reconnect Facebook", job.errorMessage ?: "Facebook access expired. Open ReelBridge to reconnect.")
                else -> Notifications.result(applicationContext, jobId, "Reel failed to publish", job.errorMessage ?: "Open ReelBridge to retry.")
            }
        }
        return Result.success()
    }

    companion object { const val KEY_JOB = "job" }
}
