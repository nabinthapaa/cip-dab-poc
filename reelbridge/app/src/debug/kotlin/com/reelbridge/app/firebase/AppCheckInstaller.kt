package com.reelbridge.app.firebase

import com.google.firebase.appcheck.FirebaseAppCheck
import com.google.firebase.appcheck.debug.DebugAppCheckProviderFactory

/**
 * Debug builds use the App Check debug provider. On first run, Logcat prints a debug token
 * ("DebugAppCheckProvider: Enter this debug secret into the allow list…"); register it in
 * Firebase Console → App Check → Apps → Manage debug tokens.
 */
object AppCheckInstaller {
    fun install() = FirebaseAppCheck.getInstance().installAppCheckProviderFactory(DebugAppCheckProviderFactory.getInstance())
}
