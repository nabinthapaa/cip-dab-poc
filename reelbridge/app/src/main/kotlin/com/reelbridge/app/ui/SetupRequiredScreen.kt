package com.reelbridge.app.ui

import androidx.compose.foundation.layout.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Build
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.reelbridge.app.ui.components.*
import com.reelbridge.app.ui.theme.RB

/** Shown when the APK was built without google-services.json (no Firebase project). */
@Composable
fun SetupRequiredScreen() {
    GradientBackground {
        Column(Modifier.fillMaxSize().systemBarsPadding().padding(24.dp), verticalArrangement = Arrangement.Center) {
            BrandMark(60.dp)
            Spacer(Modifier.height(20.dp))
            Text("Setup required", style = MaterialTheme.typography.headlineMedium)
            Spacer(Modifier.height(10.dp))
            Text(
                "This ReelBridge build is not connected to a Firebase project, so it cannot sign in or publish. " +
                    "Add app/google-services.json from your Firebase project and rebuild. See README → Firebase setup.",
                style = MaterialTheme.typography.bodyLarge, color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Spacer(Modifier.height(16.dp))
            InfoBanner("Nothing is published from this build.", color = RB.Warning, icon = Icons.Rounded.Build)
        }
    }
}
