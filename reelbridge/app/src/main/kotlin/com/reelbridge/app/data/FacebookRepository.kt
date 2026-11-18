package com.reelbridge.app.data

import com.google.firebase.Timestamp
import com.google.firebase.firestore.DocumentSnapshot
import com.google.firebase.firestore.FirebaseFirestore
import com.reelbridge.app.data.model.FacebookConnection
import com.reelbridge.app.data.model.FacebookPage
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow

/** Read-only, real-time view of the server-maintained Facebook connection state. */
class FacebookRepository(private val db: FirebaseFirestore) {

    fun connection(uid: String): Flow<FacebookConnection> = callbackFlow {
        val reg = db.collection("facebook_connections").document(uid).addSnapshotListener { snap, err ->
            if (err != null) { trySend(FacebookConnection.NONE.copy(lastError = err.message)); return@addSnapshotListener }
            trySend(snap?.takeIf { it.exists() }?.toConnection() ?: FacebookConnection.NONE)
        }
        awaitClose { reg.remove() }
    }

    fun pages(uid: String): Flow<List<FacebookPage>> = callbackFlow {
        val reg = db.collection("facebook_pages").whereEqualTo("uid", uid).addSnapshotListener { snap, _ ->
            trySend(snap?.documents.orEmpty().map { d ->
                FacebookPage(
                    pageId = d.getString("pageId").orEmpty(),
                    name = d.getString("name").orEmpty(),
                    pictureUrl = d.getString("pictureUrl"),
                    canPublish = d.getBoolean("canPublish") ?: false,
                    instagramUsername = d.getString("igUsername"),
                )
            }.sortedBy { it.name.lowercase() })
        }
        awaitClose { reg.remove() }
    }

    @Suppress("UNCHECKED_CAST")
    private fun DocumentSnapshot.toConnection() = FacebookConnection(
        connected = getString("status") == "connected",
        status = getString("status") ?: "disconnected",
        fbUserName = getString("fbUserName"),
        selectedPageId = getString("selectedPageId"),
        selectedPageName = getString("selectedPageName"),
        grantedPermissions = (get("grantedPermissions") as? List<String>).orEmpty(),
        missingPermissions = (get("missingPermissions") as? List<String>).orEmpty(),
        userTokenExpiresAtMs = ms("userTokenExpiresAt"),
        dataAccessExpiresAtMs = ms("dataAccessExpiresAt"),
        checkedAtMs = ms("checkedAt"),
        lastError = getString("lastError"),
    )
}

internal fun DocumentSnapshot.ms(field: String): Long? = (get(field) as? Timestamp)?.toDate()?.time
