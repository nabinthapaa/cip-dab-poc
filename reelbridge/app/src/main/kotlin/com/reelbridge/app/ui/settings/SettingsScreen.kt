package com.reelbridge.app.ui.settings

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.reelbridge.app.BuildConfig
import com.reelbridge.app.ui.AppViewModel
import com.reelbridge.app.ui.collect
import com.reelbridge.app.ui.components.*
import com.reelbridge.app.ui.formatBytes
import com.reelbridge.app.ui.theme.RB
import com.reelbridge.core.caption.CaptionBuilder

@Composable
fun SettingsScreen(vm: AppViewModel, onConnect: () -> Unit) {
    val settings by vm.settings.collect()
    val connection by vm.connection.collect()
    var template by remember(settings.captionTemplate) { mutableStateOf(settings.captionTemplate) }
    var hashtags by remember(settings.defaultHashtags) { mutableStateOf(settings.defaultHashtags) }
    var storage by remember { mutableLongStateOf(vm.draftStorageBytes()) }

    Column(
        Modifier.fillMaxSize().statusBarsPadding().verticalScroll(rememberScrollState()).padding(20.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Text("Settings", style = MaterialTheme.typography.headlineMedium)

        RBCard(Modifier.fillMaxWidth()) {
            ToggleRow("Automatic publishing", "Publish as soon as you share a video. Turn off to review each Reel first.", settings.autoPublish) { on ->
                vm.updateSettings { it.copy(autoPublish = on) }
            }
            HorizontalDivider(Modifier.padding(vertical = 10.dp), color = MaterialTheme.colorScheme.outlineVariant)
            ToggleRow("Notifications", "Tell me when a Reel is published or fails.", settings.notifications) { on ->
                vm.updateSettings { it.copy(notifications = on) }
            }
        }

        RBCard(Modifier.fillMaxWidth()) {
            Text("Caption", style = MaterialTheme.typography.titleMedium)
            Spacer(Modifier.height(8.dp))
            OutlinedTextField(
                template, { template = it }, Modifier.fillMaxWidth(), label = { Text("Template") },
                supportingText = { Text("{caption} is replaced with the shared text") }, minLines = 2,
            )
            OutlinedTextField(
                hashtags, { hashtags = it }, Modifier.fillMaxWidth(), label = { Text("Default hashtags") },
                supportingText = { Text("Example: reels, travel, #food") }, singleLine = true,
            )
            Spacer(Modifier.height(8.dp))
            Text("Preview", style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
            Text(CaptionBuilder.build("My new Reel", template, hashtags), style = MaterialTheme.typography.bodyMedium)
            Spacer(Modifier.height(10.dp))
            Button(
                onClick = { vm.updateSettings { it.copy(captionTemplate = template.ifBlank { "{caption}" }, defaultHashtags = hashtags) } },
                enabled = template != settings.captionTemplate || hashtags != settings.defaultHashtags,
            ) { Text("Save caption settings") }
        }

        RBCard(Modifier.fillMaxWidth()) {
            Text("Account", style = MaterialTheme.typography.titleMedium)
            Spacer(Modifier.height(6.dp))
            KeyValueRow("Facebook", if (connection.connected) connection.fbUserName ?: "Connected" else "Not connected",
                if (connection.connected) RB.Success else RB.Warning)
            KeyValueRow("Page", connection.selectedPageName ?: "—")
            Spacer(Modifier.height(8.dp))
            OutlinedButton(onClick = onConnect) { Text("Manage Facebook connection") }
        }

        RBCard(Modifier.fillMaxWidth()) {
            Text("Storage", style = MaterialTheme.typography.titleMedium)
            KeyValueRow("Local video copies", formatBytes(storage))
            TextButton(onClick = { vm.clearOldDrafts(); storage = vm.draftStorageBytes() }) { Text("Clear copies older than a day") }
        }

        InfoBanner(
            "Only publish videos you created or have permission to repost. ReelBridge never downloads from Instagram pages; it uses the files you share or your own Instagram account's media through Meta's official API.",
            icon = Icons.Rounded.Gavel,
        )
        Text("ReelBridge ${BuildConfig.VERSION_NAME}", style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.align(Alignment.CenterHorizontally))
    }
}

@Composable
private fun ToggleRow(title: String, subtitle: String, checked: Boolean, onChange: (Boolean) -> Unit) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f)) {
            Text(title, style = MaterialTheme.typography.titleSmall)
            Text(subtitle, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        Spacer(Modifier.width(12.dp))
        Switch(checked, onChange)
    }
}
