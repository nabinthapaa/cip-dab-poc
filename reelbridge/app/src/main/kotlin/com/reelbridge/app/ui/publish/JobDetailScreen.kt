package com.reelbridge.app.ui.publish

import android.content.Intent
import android.net.Uri
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material.icons.automirrored.rounded.OpenInNew
import androidx.compose.material.icons.rounded.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import com.reelbridge.app.data.model.PublishJob
import com.reelbridge.app.ui.AppViewModel
import com.reelbridge.app.ui.absoluteTime
import com.reelbridge.app.ui.collect
import com.reelbridge.app.ui.components.*
import com.reelbridge.app.ui.theme.RB
import com.reelbridge.core.publish.PublishStatus

/** Publishing screen for one Reel: preview, caption, destination, live status, retry. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun JobDetailScreen(vm: AppViewModel, jobId: String, onBack: () -> Unit) {
    val jobs by vm.jobs.collect()
    val busy by vm.busy.collect()
    val progress by vm.uploadProgress.collect()
    val settings by vm.settings.collect()
    val job = jobs.firstOrNull { it.id == jobId }
    val context = LocalContext.current

    Column(Modifier.fillMaxSize()) {
        TopAppBar(
            title = { Text("Reel") },
            navigationIcon = { IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Rounded.ArrowBack, "Back") } },
            colors = TopAppBarDefaults.topAppBarColors(containerColor = Color.Transparent),
        )
        if (job == null) {
            Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
            return@Column
        }
        Column(Modifier.verticalScroll(rememberScrollState()).padding(20.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
            Row(horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                Thumbnail(vm.thumbnailFor(job.id) ?: job.thumbnailUrl, Modifier.width(120.dp).aspectRatio(9f / 16f))
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    StatusChip(job.status)
                    KeyValueRow("Page", job.pageName ?: job.pageId)
                    KeyValueRow("Source", if (job.source == "instagram") "Your Instagram" else "This device")
                    KeyValueRow("Created", absoluteTime(job.createdAtMs))
                    if (job.publishedAtMs != null) KeyValueRow("Published", absoluteTime(job.publishedAtMs))
                    KeyValueRow("Attempts", job.attempts.toString())
                }
            }

            RBCard(Modifier.fillMaxWidth()) {
                Text("Progress", style = MaterialTheme.typography.titleMedium)
                Spacer(Modifier.height(10.dp))
                StatusTimeline(job, progress[job.id])
            }

            RBCard(Modifier.fillMaxWidth()) {
                Text("Caption", style = MaterialTheme.typography.titleMedium)
                Spacer(Modifier.height(6.dp))
                Text(job.caption.ifBlank { "(no caption)" }, style = MaterialTheme.typography.bodyMedium)
            }

            job.errorMessage?.takeIf { job.status != PublishStatus.PUBLISHED }?.let {
                InfoBanner(it, color = if (job.status == PublishStatus.NEEDS_RECONNECT) RB.Warning else RB.Error, icon = Icons.Rounded.ErrorOutline)
            }

            if (job.status == PublishStatus.FAILED || job.status == PublishStatus.NEEDS_RECONNECT) {
                GradientButton("Retry publishing", { vm.retry(job.id) }, Modifier.fillMaxWidth(), loading = busy, icon = Icons.Rounded.Refresh)
            }
            job.permalinkUrl?.let { url ->
                OutlinedButton(onClick = { context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url))) }, Modifier.fillMaxWidth()) {
                    Icon(Icons.AutoMirrored.Rounded.OpenInNew, null); Spacer(Modifier.width(8.dp)); Text("View on Facebook")
                }
            }

            RBCard(Modifier.fillMaxWidth(), padding = 14.dp) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) {
                        Text("Automatic publishing", style = MaterialTheme.typography.titleSmall)
                        Text("Publish immediately when you share a video to ReelBridge.", style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    Switch(settings.autoPublish, { on -> vm.updateSettings { it.copy(autoPublish = on) } })
                }
            }
        }
    }
}

@Composable
private fun StatusTimeline(job: PublishJob, uploadProgress: Float?) {
    val order = listOf(PublishStatus.QUEUED, PublishStatus.PUBLISHING, PublishStatus.PROCESSING, PublishStatus.PUBLISHED)
    val reached = when (job.status) {
        PublishStatus.PREPARING, PublishStatus.UPLOADING -> -1
        PublishStatus.FAILED, PublishStatus.NEEDS_RECONNECT -> -2
        else -> order.indexOf(job.status)
    }
    val labels = listOf("Uploaded to ReelBridge", "Sending to Facebook", "Facebook is processing", "Live on your Page")
    labels.forEachIndexed { i, label ->
        val done = reached >= i
        val active = reached == i && job.status != PublishStatus.PUBLISHED
        Row(Modifier.padding(vertical = 5.dp), verticalAlignment = Alignment.CenterVertically) {
            when {
                active -> CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp)
                done -> Icon(Icons.Rounded.CheckCircle, null, tint = RB.Success, modifier = Modifier.size(18.dp))
                else -> Icon(Icons.Rounded.RadioButtonUnchecked, null, tint = MaterialTheme.colorScheme.outline, modifier = Modifier.size(18.dp))
            }
            Spacer(Modifier.width(10.dp))
            Text(label, style = MaterialTheme.typography.bodyMedium,
                color = if (done || active) MaterialTheme.colorScheme.onSurface else MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
    if (reached == -2) {
        Text("Stopped: ${job.status.label}", color = RB.Error, style = MaterialTheme.typography.bodySmall, modifier = Modifier.padding(top = 4.dp))
    }
    if (uploadProgress != null) LinearProgressIndicator(progress = { uploadProgress }, Modifier.fillMaxWidth().padding(top = 8.dp))
}
