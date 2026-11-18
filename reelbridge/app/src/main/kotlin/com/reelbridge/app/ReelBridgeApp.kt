package com.reelbridge.app

import android.app.Application
import android.util.Log
import com.facebook.FacebookSdk
import com.reelbridge.app.firebase.AppCheckInstaller
import com.reelbridge.app.work.Notifications

class ReelBridgeApp : Application() {
    lateinit var container: AppContainer
        private set

    override fun onCreate() {
        super.onCreate()
        container = AppContainer(this)
        Notifications.createChannels(this)
        if (container.firebaseReady) {
            runCatching { AppCheckInstaller.install() }.onFailure { Log.w("ReelBridge", "App Check not installed", it) }
        } else {
            Log.w("ReelBridge", "google-services.json missing: Firebase features disabled (see README)")
        }
        if (container.facebookReady) {
            // Auto-init is disabled in the manifest so no app events are logged automatically.
            @Suppress("DEPRECATION")
            FacebookSdk.sdkInitialize(this)
        }
    }
}
