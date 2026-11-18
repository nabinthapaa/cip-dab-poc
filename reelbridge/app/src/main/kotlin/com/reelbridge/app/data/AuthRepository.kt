package com.reelbridge.app.data

import com.google.firebase.auth.FacebookAuthProvider
import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.auth.FirebaseUser
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow
import kotlinx.coroutines.tasks.await

/**
 * Firebase Authentication. ReelBridge signs users in with their Facebook account, so a single
 * "Continue with Facebook" both authenticates with Firebase and authorizes Page publishing.
 */
class AuthRepository(private val auth: FirebaseAuth) {
    val currentUser: FirebaseUser? get() = auth.currentUser

    val userFlow: Flow<FirebaseUser?> = callbackFlow {
        val l = FirebaseAuth.AuthStateListener { trySend(it.currentUser) }
        auth.addAuthStateListener(l)
        awaitClose { auth.removeAuthStateListener(l) }
    }

    suspend fun signInWithFacebook(accessToken: String): FirebaseUser {
        val credential = FacebookAuthProvider.getCredential(accessToken)
        val result = auth.signInWithCredential(credential).await()
        return result.user ?: error("Firebase sign-in returned no user")
    }

    fun signOut() = auth.signOut()
}
