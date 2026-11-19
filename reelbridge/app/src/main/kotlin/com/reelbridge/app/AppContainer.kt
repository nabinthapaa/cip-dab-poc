package com.reelbridge.app

import android.content.Context
import com.google.firebase.FirebaseApp
import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.firestore.FirebaseFirestore
import com.google.firebase.firestore.SetOptions
import com.google.firebase.functions.FirebaseFunctions
import com.google.firebase.storage.FirebaseStorage
import com.reelbridge.app.data.*
import com.reelbridge.app.data.model.UserSettings
import com.reelbridge.app.work.PublishQueue
import kotlinx.coroutines.tasks.await

/** Manual dependency injection. Firebase-backed members are only touched when [firebaseReady]. */
class AppContainer(private val context: Context) {
    val firebaseReady: Boolean = BuildConfig.FIREBASE_CONFIGURED && FirebaseApp.getApps(context).isNotEmpty()
    val facebookReady: Boolean = BuildConfig.FACEBOOK_CONFIGURED

    private val firestore by lazy { FirebaseFirestore.getInstance() }
    private val firebaseAuth by lazy { FirebaseAuth.getInstance() }

    val auth by lazy { AuthRepository(firebaseAuth) }
    val backend by lazy { BackendApi(FirebaseFunctions.getInstance(BuildConfig.FUNCTIONS_REGION)) }
    val facebook by lazy { FacebookRepository(firestore) }
    val jobs by lazy { JobsRepository(firestore) }
    val uploader by lazy { VideoUploader(FirebaseStorage.getInstance()) }
    val drafts by lazy { DraftStore(context) }
    val outros by lazy { OutroStore(context) }
    val queue by lazy { PublishQueue(context) }

    val settings by lazy {
        SettingsRepository(context) { s: UserSettings ->
            val uid = if (firebaseReady) firebaseAuth.currentUser?.uid else null
            if (uid != null) {
                firestore.collection("users").document(uid).set(
                    mapOf(
                        "autoPublish" to s.autoPublish,
                        "captionTemplate" to s.captionTemplate,
                        "defaultHashtags" to s.defaultHashtags,
                        "updatedAt" to com.google.firebase.firestore.FieldValue.serverTimestamp(),
                    ),
                    SetOptions.merge(),
                ).await()
            }
        }
    }
}
