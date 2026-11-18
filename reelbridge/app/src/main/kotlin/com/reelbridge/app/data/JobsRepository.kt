package com.reelbridge.app.data

import com.google.firebase.firestore.DocumentSnapshot
import com.google.firebase.firestore.FieldValue
import com.google.firebase.firestore.FirebaseFirestore
import com.google.firebase.firestore.FirebaseFirestoreException
import com.google.firebase.firestore.Query
import com.google.firebase.firestore.Source
import com.reelbridge.app.data.model.PublishJob
import com.reelbridge.core.publish.PublishStatus
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow
import kotlinx.coroutines.tasks.await

/** reels/ and publishing_jobs/ access. Status fields are written only by the backend. */
class JobsRepository(private val db: FirebaseFirestore) {

    fun jobs(uid: String, limit: Long = 200): Flow<List<PublishJob>> = callbackFlow {
        val reg = db.collection("publishing_jobs")
            .whereEqualTo("uid", uid)
            .orderBy("createdAt", Query.Direction.DESCENDING)
            .limit(limit)
            .addSnapshotListener { snap, _ -> trySend(snap?.documents.orEmpty().map { it.toJob() }) }
        awaitClose { reg.remove() }
    }

    suspend fun fetch(jobId: String): PublishJob? =
        db.collection("publishing_jobs").document(jobId).get(Source.SERVER).await().takeIf { it.exists() }?.toJob()

    /**
     * Creates reels/{key} and publishing_jobs/{key} atomically. Returns false when a job with this
     * idempotency key already exists (duplicate share) – in that case nothing is written.
     */
    suspend fun createJobIfAbsent(
        key: String, uid: String, pageId: String, pageName: String?, caption: String,
        storagePath: String, sha256: String, sizeBytes: Long, durationMs: Long, width: Int, height: Int,
    ): Boolean {
        val jobRef = db.collection("publishing_jobs").document(key)
        val reelRef = db.collection("reels").document(key)
        return try {
            db.runTransaction { tx ->
                if (tx.get(jobRef).exists()) return@runTransaction false
                tx.set(reelRef, mapOf(
                    "uid" to uid, "source" to "device", "storagePath" to storagePath, "sha256" to sha256,
                    "sizeBytes" to sizeBytes, "durationMs" to durationMs, "width" to width, "height" to height,
                    "caption" to caption, "createdAt" to FieldValue.serverTimestamp(),
                ))
                tx.set(jobRef, mapOf(
                    "uid" to uid, "reelId" to key, "pageId" to pageId, "pageName" to pageName,
                    "caption" to caption, "storagePath" to storagePath, "source" to "device",
                    "status" to PublishStatus.QUEUED.wire, "attempts" to 0,
                    "createdAt" to FieldValue.serverTimestamp(), "updatedAt" to FieldValue.serverTimestamp(),
                ))
                true
            }.await()
        } catch (e: FirebaseFirestoreException) {
            // A concurrent create of the same key loses the race with PERMISSION_DENIED/ALREADY_EXISTS.
            if (e.code == FirebaseFirestoreException.Code.ALREADY_EXISTS) false else throw e
        }
    }

    suspend fun deleteJob(jobId: String) {
        db.collection("publishing_jobs").document(jobId).delete().await()
    }
}

internal fun DocumentSnapshot.toJob() = PublishJob(
    id = id,
    status = PublishStatus.fromWire(getString("status")),
    caption = getString("caption").orEmpty(),
    pageId = getString("pageId").orEmpty(),
    pageName = getString("pageName"),
    source = getString("source") ?: "device",
    thumbnailUrl = getString("thumbnailUrl"),
    errorMessage = getString("errorMessage"),
    retryable = getBoolean("retryable") ?: false,
    attempts = getLong("attempts")?.toInt() ?: 0,
    createdAtMs = ms("createdAt"),
    updatedAtMs = ms("updatedAt"),
    publishedAtMs = ms("publishedAt"),
    permalinkUrl = getString("permalinkUrl"),
)
