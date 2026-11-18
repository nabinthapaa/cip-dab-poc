package com.reelbridge.app.data

import android.net.Uri
import com.google.firebase.storage.FirebaseStorage
import com.google.firebase.storage.StorageMetadata
import kotlinx.coroutines.suspendCancellableCoroutine
import java.io.File
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/** Uploads an authorized video to Firebase Storage at users/{uid}/videos/{key}.{ext}. */
class VideoUploader(private val storage: FirebaseStorage) {

    fun storagePath(uid: String, key: String, mimeType: String?): String =
        "users/$uid/videos/$key.${if (mimeType == "video/quicktime") "mov" else "mp4"}"

    suspend fun upload(file: File, path: String, mimeType: String, sha256: String, onProgress: (Float) -> Unit) {
        val ref = storage.reference.child(path)
        val meta = StorageMetadata.Builder()
            .setContentType(mimeType)
            .setCustomMetadata("sha256", sha256)
            .build()
        suspendCancellableCoroutine { cont ->
            val task = ref.putFile(Uri.fromFile(file), meta)
            task.addOnProgressListener { s ->
                if (s.totalByteCount > 0) onProgress(s.bytesTransferred.toFloat() / s.totalByteCount)
            }
            task.addOnSuccessListener { if (cont.isActive) cont.resume(Unit) }
            task.addOnFailureListener { if (cont.isActive) cont.resumeWithException(it) }
            cont.invokeOnCancellation { task.cancel() }
        }
    }
}
