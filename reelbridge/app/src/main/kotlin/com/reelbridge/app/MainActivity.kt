package com.reelbridge.app

import android.Manifest
import android.content.Intent
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.viewModels
import androidx.compose.runtime.mutableStateOf
import com.reelbridge.app.ui.AppNav
import com.reelbridge.app.ui.AppViewModel
import com.reelbridge.app.ui.SetupRequiredScreen
import com.reelbridge.app.ui.theme.ReelBridgeTheme

class MainActivity : ComponentActivity() {
    private val destination = mutableStateOf<String?>(null)
    private val vm: AppViewModel by viewModels { AppViewModel.Factory }

    private val notificationPermission = registerForActivityResult(ActivityResultContracts.RequestPermission()) { }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        destination.value = intent?.getStringExtra(EXTRA_DESTINATION)
        if (Build.VERSION.SDK_INT >= 33) notificationPermission.launch(Manifest.permission.POST_NOTIFICATIONS)

        val ready = (application as ReelBridgeApp).container.firebaseReady
        setContent {
            ReelBridgeTheme {
                if (!ready) SetupRequiredScreen()
                else AppNav(vm, destination.value)
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        destination.value = intent.getStringExtra(EXTRA_DESTINATION)
    }

    companion object { const val EXTRA_DESTINATION = "destination" }
}
