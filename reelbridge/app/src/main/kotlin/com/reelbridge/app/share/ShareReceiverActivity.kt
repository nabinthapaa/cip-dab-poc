package com.reelbridge.app.share

import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.viewModels
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import com.reelbridge.app.MainActivity
import com.reelbridge.app.ReelBridgeApp
import com.reelbridge.app.ui.theme.ReelBridgeTheme

/**
 * Entry point for Android's share sheet (ACTION_SEND / ACTION_SEND_MULTIPLE with text/plain or any video MIME type).
 * Shared files are copied into private storage inside this activity, while the URI grant is valid.
 */
class ShareReceiverActivity : ComponentActivity() {
    private val vm: ShareViewModel by viewModels {
        viewModelFactory { initializer { ShareViewModel((application as ReelBridgeApp).container) } }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        vm.handle(ShareIntentParser.parse(intent, contentResolver))
        setContent {
            ReelBridgeTheme {
                ShareScreen(
                    vm = vm,
                    onClose = { finish() },
                    onOpenApp = {
                        startActivity(Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                        finish()
                    },
                )
            }
        }
    }
}
