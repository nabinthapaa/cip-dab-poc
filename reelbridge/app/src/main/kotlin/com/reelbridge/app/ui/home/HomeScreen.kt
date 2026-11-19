package com.reelbridge.app.ui.home

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.reelbridge.app.data.model.PublishJob
import com.reelbridge.app.ui.AppViewModel
import com.reelbridge.app.ui.collect
import com.reelbridge.app.ui.components.*
import com.reelbridge.app.ui.relativeTime
import com.reelbridge.app.ui.theme.RB

@Composable
fun HomeScreen(vm: AppViewModel, onConnect: () -> Unit, onOpenJob: (String) -> Unit, onHistory: () -> Unit, onSettings: () -> Unit) {
    val user by vm.user.collect()
    val connection by vm.connection.collect()
    val stats by vm.stats.collect()
    val jobs by vm.jobs.collect()
    val settings by vm.settings.collect()
    val progress by vm.uploadProgress.collect()
    val stages by vm.uploadStages.collect()

    LazyColumn(
        Modifier.fillMaxSize().statusBarsPadding(),
        contentPadding = PaddingValues(20.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        item {
            Row(verticalAlignment = Alignment.CenterVertically) {
                BrandMark()
                Spacer(Modifier.width(12.dp))
                Column(Modifier.weight(1f)) {
                    Text("ReelBridge", style = MaterialTheme.typography.headlineMedium)
                    Text("Instagram → Facebook Reels", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                IconButton(onClick = onSettings) { Icon(Icons.Rounded.Settings, "Settings") }
            }
        }

        item {
            val ready = user != null && connection.connected && connection.selectedPageId != null
            RBCard(Modifier.fillMaxWidth().clickable(onClick = onConnect), highlighted = !ready) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(
                        if (ready) Icons.Rounded.Verified else Icons.Rounded.LinkOff, null,
                        tint = if (ready) RB.Success else RB.Warning,
                    )
                    Spacer(Modifier.width(10.dp))
                    Column(Modifier.weight(1f)) {
                        Text(
                            when {
                                user == null || !connection.connected -> "Connect your Facebook Page"
                                connection.selectedPageId == null -> "Choose a destination Page"
                                else -> connection.selectedPageName ?: "Facebook Page"
                            },
                            style = MaterialTheme.typography.titleMedium,
                        )
                        Text(
                            when {
                                user == null || !connection.connected -> "One-time setup. Takes about a minute."
                                connection.selectedPageId == null -> "Connected as ${connection.fbUserName ?: "Facebook user"}"
                                else -> "Publishing destination • ${if (settings.autoPublish) "Auto-publish ON" else "Review before posting"}"
                            },
                            style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                    Icon(Icons.Rounded.ChevronRight, null)
                }
                AnimatedVisibility(connection.missingPermissions.isNotEmpty()) {
                    InfoBanner(
                        "Missing permissions: ${connection.missingPermissions.joinToString()}. Reconnect and allow them.",
                        Modifier.padding(top = 12.dp), color = RB.Warning, icon = Icons.Rounded.Warning,
                    )
                }
            }
        }

        item {
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                StatTile("Published", stats.published.toString(), Icons.Rounded.CheckCircle, RB.Success, Modifier.weight(1f))
                StatTile("Pending", stats.pending.toString(), Icons.Rounded.Schedule, RB.Blue, Modifier.weight(1f))
                StatTile("Failed", stats.failed.toString(), Icons.Rounded.ErrorOutline, RB.Error, Modifier.weight(1f))
            }
        }

        item {
            SectionTitle("Recent activity") { TextButton(onClick = onHistory) { Text("See all") } }
        }

        // Uploads still on the device (the server-side job is created once the upload finishes).
        val localUploads = progress.filterKeys { id -> jobs.none { it.id == id } }
        items(localUploads.entries.toList(), key = { "upload-${it.key}" }) { (id, p) ->
            RBCard(Modifier.fillMaxWidth(), padding = 14.dp) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Thumbnail(null, Modifier.size(width = 40.dp, height = 54.dp))
                    Spacer(Modifier.width(12.dp))
                    Column(Modifier.weight(1f)) {
                        Text("${stages[id] ?: "Uploading Reel…"} ${(p * 100).toInt()}%", style = MaterialTheme.typography.titleSmall)
                        Spacer(Modifier.height(8.dp))
                        LinearProgressIndicator(progress = { p }, Modifier.fillMaxWidth())
                    }
                }
            }
        }

        if (jobs.isEmpty() && localUploads.isEmpty()) {
            item { HowItWorksCard() }
        } else {
            items(jobs.take(5), key = { it.id }) { job ->
                JobRow(job, progress[job.id], vm.thumbnailFor(job.id), onClick = { onOpenJob(job.id) })
            }
        }
    }
}

@Composable
private fun HowItWorksCard() {
    RBCard(Modifier.fillMaxWidth()) {
        Text("How it works", style = MaterialTheme.typography.titleMedium)
        Spacer(Modifier.height(10.dp))
        listOf(
            Icons.Rounded.Link to "Connect your Facebook Page once.",
            Icons.Rounded.Share to "In Instagram (or your gallery), tap Share on a Reel you own.",
            Icons.Rounded.TouchApp to "Pick “Post to Facebook Reels” (ReelBridge).",
            Icons.Rounded.RocketLaunch to "ReelBridge uploads and publishes it to your Page.",
        ).forEachIndexed { i, (icon, text) ->
            Row(Modifier.padding(vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
                Icon(icon, null, tint = if (i % 2 == 0) RB.Blue else RB.Purple)
                Spacer(Modifier.width(12.dp))
                Text(text, style = MaterialTheme.typography.bodyMedium)
            }
        }
        Spacer(Modifier.height(8.dp))
        Text(
            "Only share videos you own or have permission to repost.",
            style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

@Composable
fun JobRow(job: PublishJob, uploadProgress: Float?, localThumb: String?, onClick: () -> Unit, trailing: (@Composable () -> Unit)? = null) {
    RBCard(Modifier.fillMaxWidth().clickable(onClick = onClick), padding = 12.dp) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Thumbnail(localThumb ?: job.thumbnailUrl, Modifier.size(width = 54.dp, height = 72.dp))
            Spacer(Modifier.width(12.dp))
            Column(Modifier.weight(1f)) {
                Text(
                    job.caption.ifBlank { "(no caption)" }, style = MaterialTheme.typography.titleSmall,
                    maxLines = 2, overflow = TextOverflow.Ellipsis,
                )
                Spacer(Modifier.height(4.dp))
                Text(
                    "${job.pageName ?: "Facebook Page"} • ${relativeTime(job.publishedAtMs ?: job.updatedAtMs ?: job.createdAtMs)}",
                    style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                Spacer(Modifier.height(6.dp))
                StatusChip(job.status)
                job.errorMessage?.takeIf { job.status.isTerminal && job.status != com.reelbridge.core.publish.PublishStatus.PUBLISHED }?.let {
                    Text(it, style = MaterialTheme.typography.bodySmall, color = RB.Error, maxLines = 2, overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.padding(top = 4.dp))
                }
            }
            trailing?.invoke()
        }
        if (uploadProgress != null) {
            Spacer(Modifier.height(10.dp))
            LinearProgressIndicator(progress = { uploadProgress }, Modifier.fillMaxWidth())
        }
    }
}
