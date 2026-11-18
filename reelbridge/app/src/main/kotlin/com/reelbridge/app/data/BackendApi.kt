package com.reelbridge.app.data

import com.google.firebase.functions.FirebaseFunctions
import com.google.firebase.functions.FirebaseFunctionsException
import com.reelbridge.app.data.model.InstagramResolution
import kotlinx.coroutines.tasks.await

class BackendException(message: String, val code: String, cause: Throwable? = null) : Exception(message, cause)

/**
 * Typed wrapper around the ReelBridge Cloud Functions (backend/functions/src/index.ts).
 * All privileged Meta operations happen server-side; this class only ever sends the short-lived
 * user token from Facebook Login (once, at connect time) and receives non-secret data back.
 */
class BackendApi(private val functions: FirebaseFunctions) {

    private suspend fun call(name: String, data: Map<String, Any?> = emptyMap()): Map<*, *> = try {
        functions.getHttpsCallable(name).call(data).await().data as? Map<*, *> ?: emptyMap<String, Any>()
    } catch (e: FirebaseFunctionsException) {
        throw BackendException(e.message ?: "Server error", e.code.name, e)
    } catch (e: Exception) {
        throw BackendException(e.message ?: "Network error", "UNAVAILABLE", e)
    }

    suspend fun connectFacebook(userAccessToken: String): Int =
        (call("connectFacebook", mapOf("userAccessToken" to userAccessToken))["pageCount"] as? Number)?.toInt() ?: 0

    suspend fun refreshPages(): Int = (call("refreshFacebookPages")["pageCount"] as? Number)?.toInt() ?: 0

    suspend fun selectPage(pageId: String) { call("selectFacebookPage", mapOf("pageId" to pageId)) }

    suspend fun checkConnection() { call("checkFacebookConnection") }

    suspend fun disconnect(revokePermissions: Boolean) { call("disconnectFacebook", mapOf("revoke" to revokePermissions)) }

    suspend fun retryJob(jobId: String) { call("retryPublishingJob", mapOf("jobId" to jobId)) }

    suspend fun resolveInstagramReel(url: String): InstagramResolution {
        val r = call("resolveInstagramReel", mapOf("url" to url))
        return InstagramResolution(
            found = r["found"] == true,
            mediaId = r["mediaId"] as? String,
            caption = r["caption"] as? String,
            thumbnailUrl = r["thumbnailUrl"] as? String,
            reason = r["reason"] as? String,
            message = r["message"] as? String,
        )
    }

    /** Server copies the user's own Instagram media into Storage and creates the publishing job. */
    suspend fun importInstagramReel(url: String, caption: String): ImportResult {
        val r = call("importInstagramReel", mapOf("url" to url, "caption" to caption))
        return ImportResult(r["jobId"] as? String ?: "", r["duplicate"] == true, r["status"] as? String)
    }

    data class ImportResult(val jobId: String, val duplicate: Boolean, val status: String?)
}
