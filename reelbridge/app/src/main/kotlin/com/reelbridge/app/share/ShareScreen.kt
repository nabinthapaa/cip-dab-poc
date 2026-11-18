package com.reelbridge.app.share

import androidx.compose.animation.AnimatedContent
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
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.reelbridge.app.data.model.InspectedDraft
import com.reelbridge.app.ui.components.*
import com.reelbridge.app.ui.formatBytes
import com.reelbridge.app.ui.formatDuration
import com.reelbridge.app.ui.theme.RB
import kotlinx.coroutines.delay

@Composable
fun ShareScreen(vm: ShareViewModel, onClose: () -> Unit, onOpenApp: () -> Unit) {
    val state by vm.state.collectAsStateWithLifecycle()
    GradientBackground {
        AnimatedContent(state, label = "share", contentKey = { it::class }) { s ->
            Column(
                Modifier.fillMaxSize().systemBarsPadding().imePadding().verticalScroll(rememberScrollState()).padding(20.dp),
                verticalArrangement = Arrangement.spacedBy(16.dp),
            ) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    BrandMark(36.dp); Spacer(Modifier.width(10.dp))
                    Text("ReelBridge", style = MaterialTheme.typography.titleLarge, modifier = Modifier.weight(1f))
                    IconButton(onClick = onClose) { Icon(Icons.Rounded.Close, "Close") }
                }
                when (s) {
                    is ShareUiState.Working -> Working(s.message)
                    is ShareUiState.Blocked -> Blocked(s, onClose, onOpenApp)
                    is ShareUiState.ReviewVideos -> ReviewVideos(s, vm::publishVideos)
                    is ShareUiState.ReviewInstagram -> ReviewInstagram(s, vm::publishInstagram)
                    is ShareUiState.Done -> Done(s, onClose, onOpenApp)
                }
            }
        }
    }
}

@Composable
private fun Working(message: String) {
    Column(Modifier.fillMaxWidth().padding(top = 80.dp), horizontalAlignment = Alignment.CenterHorizontally) {
        CircularProgressIndicator()
        Spacer(Modifier.height(18.dp))
        Text(message, style = MaterialTheme.typography.bodyLarge)
    }
}

@Composable
private fun Blocked(s: ShareUiState.Blocked, onClose: () -> Unit, onOpenApp: () -> Unit) {
    RBCard(Modifier.fillMaxWidth()) {
        Icon(Icons.Rounded.Info, null, tint = RB.Warning, modifier = Modifier.size(32.dp))
        Spacer(Modifier.height(10.dp))
        Text(s.title, style = MaterialTheme.typography.headlineSmall)
        Spacer(Modifier.height(8.dp))
        Text(s.message, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
    if (s.openApp) GradientButton("Open ReelBridge", onOpenApp, Modifier.fillMaxWidth())
    OutlinedButton(onClick = onClose, Modifier.fillMaxWidth()) { Text("Close") }
}

@Composable
private fun Done(s: ShareUiState.Done, onClose: () -> Unit, onOpenApp: () -> Unit) {
    if (s.autoClose) LaunchedEffect(Unit) { delay(3_000); onClose() }
    RBCard(Modifier.fillMaxWidth(), highlighted = true) {
        Icon(Icons.Rounded.RocketLaunch, null, tint = RB.Success, modifier = Modifier.size(36.dp))
        Spacer(Modifier.height(10.dp))
        Text(s.title, style = MaterialTheme.typography.headlineSmall)
        Spacer(Modifier.height(6.dp))
        Text(s.message, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
    GradientButton("Done", onClose, Modifier.fillMaxWidth())
    OutlinedButton(onClick = onOpenApp, Modifier.fillMaxWidth()) { Text("View progress") }
}

@Composable
private fun CaptionEditor(caption: String, onChange: (String) -> Unit) {
    OutlinedTextField(
        caption, onChange, Modifier.fillMaxWidth(), label = { Text("Caption") }, minLines = 3,
        supportingText = { Text("${caption.length} / 2200") },
    )
}

@Composable
private fun ReviewVideos(s: ShareUiState.ReviewVideos, onPublish: (String) -> Unit) {
    var caption by rememberSaveable { mutableStateOf(s.caption) }
    Text("Review your Reel", style = MaterialTheme.typography.headlineSmall)
    s.drafts.forEach { DraftCard(it) }
    CaptionEditor(caption) { caption = it }
    DestinationRow(s.pageName)
    val publishable = s.drafts.count { it.validation.isPublishable }
    GradientButton(
        if (publishable > 1) "Publish $publishable Reels" else "Publish Reel",
        { onPublish(caption) }, Modifier.fillMaxWidth(), enabled = publishable > 0, icon = Icons.Rounded.RocketLaunch,
    )
}

@Composable
private fun DraftCard(d: InspectedDraft) {
    val m = d.draft.metadata
    RBCard(Modifier.fillMaxWidth(), padding = 12.dp) {
        Row {
            Thumbnail(d.draft.thumbnailPath, Modifier.width(96.dp).aspectRatio(9f / 16f))
            Spacer(Modifier.width(12.dp))
            Column(Modifier.weight(1f)) {
                KeyValueRow("Duration", formatDuration(m.durationMs))
                KeyValueRow("Resolution", "${m.displayWidth}×${m.displayHeight}")
                KeyValueRow("Size", formatBytes(m.sizeBytes))
                KeyValueRow("Format", m.mimeType ?: "unknown")
                Spacer(Modifier.height(6.dp))
                if (d.validation.issues.isEmpty()) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Icon(Icons.Rounded.CheckCircle, null, tint = RB.Success, modifier = Modifier.size(16.dp))
                        Spacer(Modifier.width(6.dp))
                        Text("Ready for Facebook Reels", style = MaterialTheme.typography.bodySmall, color = RB.Success)
                    }
                }
            }
        }
        d.validation.issues.forEach { issue ->
            val error = issue.severity == com.reelbridge.core.video.Severity.ERROR
            InfoBanner(issue.message, Modifier.padding(top = 8.dp), color = if (error) RB.Error else RB.Warning,
                icon = if (error) Icons.Rounded.ErrorOutline else Icons.Rounded.Warning)
        }
    }
}

@Composable
private fun ReviewInstagram(s: ShareUiState.ReviewInstagram, onPublish: (String) -> Unit) {
    var caption by rememberSaveable { mutableStateOf(s.caption) }
    Text("Review your Reel", style = MaterialTheme.typography.headlineSmall)
    RBCard(Modifier.fillMaxWidth(), padding = 12.dp) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Thumbnail(s.resolution.thumbnailUrl, Modifier.width(96.dp).aspectRatio(9f / 16f))
            Spacer(Modifier.width(12.dp))
            Column {
                Text("Found in your Instagram account", style = MaterialTheme.typography.titleSmall)
                Text("ReelBridge will copy it through Meta's official API.", style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
    }
    CaptionEditor(caption) { caption = it }
    DestinationRow(s.pageName)
    GradientButton("Publish Reel", { onPublish(caption) }, Modifier.fillMaxWidth(), icon = Icons.Rounded.RocketLaunch)
}

@Composable
private fun DestinationRow(pageName: String) {
    RBCard(Modifier.fillMaxWidth(), padding = 14.dp) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Rounded.Flag, null, tint = RB.Blue)
            Spacer(Modifier.width(10.dp))
            Column {
                Text("Publishing to", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                Text(pageName, style = MaterialTheme.typography.titleSmall)
            }
        }
    }
}
