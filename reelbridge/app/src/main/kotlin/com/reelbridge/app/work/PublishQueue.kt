package com.reelbridge.app.work

import android.content.Context
import androidx.work.*
import com.reelbridge.core.publish.IdempotencyKey
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.map
import java.util.concurrent.TimeUnit

/**
 * Persistent on-device queue. WorkManager survives process death and reboots; unique work names
 * derived from the idempotency key make enqueueing the same video twice a no-op.
 */
class PublishQueue(context: Context) {
    private val wm = WorkManager.getInstance(context)

    fun enqueue(uid: String, draftId: String, sha256: String, caption: String, pageId: String, pageName: String?, outroSha256: String? = null): String {
        val key = IdempotencyKey.forVideo(uid, IdempotencyKey.contentId(sha256, outroSha256), pageId)
        val request = OneTimeWorkRequestBuilder<PublishWorker>()
            .setInputData(workDataOf(
                PublishWorker.KEY_JOB to key, PublishWorker.KEY_DRAFT to draftId, PublishWorker.KEY_CAPTION to caption,
                PublishWorker.KEY_PAGE to pageId, PublishWorker.KEY_PAGE_NAME to pageName,
                PublishWorker.KEY_OUTRO_SHA to outroSha256,
            ))
            .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build())
            .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 30, TimeUnit.SECONDS)
            .addTag(TAG_PUBLISH)
            .addTag("job:$key")
            .build()
        wm.enqueueUniqueWork("publish-$key", ExistingWorkPolicy.KEEP, request)
        return key
    }

    fun watch(jobId: String) {
        val request = OneTimeWorkRequestBuilder<JobWatchWorker>()
            .setInputData(workDataOf(JobWatchWorker.KEY_JOB to jobId))
            .setInitialDelay(15, TimeUnit.SECONDS)
            .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build())
            .setBackoffCriteria(BackoffPolicy.LINEAR, 30, TimeUnit.SECONDS)
            .addTag(TAG_WATCH)
            .build()
        wm.enqueueUniqueWork("watch-$jobId", ExistingWorkPolicy.REPLACE, request)
    }

    /** Number of uploads still on the device (not yet handed to the backend). */
    val pendingLocalUploads: Flow<Int> = wm.getWorkInfosByTagFlow(TAG_PUBLISH)
        .map { list -> list.count { !it.state.isFinished } }

    /** Upload progress per job id, for in-app progress bars. */
    val uploadProgress: Flow<Map<String, Float>> = wm.getWorkInfosByTagFlow(TAG_PUBLISH).map { list ->
        list.filter { it.state == WorkInfo.State.RUNNING }.mapNotNull { info ->
            val job = info.tags.firstOrNull { it.startsWith("job:") }?.removePrefix("job:") ?: return@mapNotNull null
            job to info.progress.getFloat(PublishWorker.PROGRESS, 0f)
        }.toMap()
    }

    /** What each running upload is doing ("Adding outro…" / "Uploading Reel…"). */
    val uploadStages: Flow<Map<String, String>> = wm.getWorkInfosByTagFlow(TAG_PUBLISH).map { list ->
        list.filter { it.state == WorkInfo.State.RUNNING }.mapNotNull { info ->
            val job = info.tags.firstOrNull { it.startsWith("job:") }?.removePrefix("job:") ?: return@mapNotNull null
            job to (info.progress.getString(PublishWorker.STAGE) ?: PublishWorker.UPLOADING)
        }.toMap()
    }

    companion object {
        const val TAG_PUBLISH = "publish"
        const val TAG_WATCH = "watch"
    }
}
