package com.reelbridge.app.ui.history

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Refresh
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.reelbridge.app.ui.AppViewModel
import com.reelbridge.app.ui.collect
import com.reelbridge.app.ui.components.InfoBanner
import com.reelbridge.app.ui.home.JobRow
import com.reelbridge.core.publish.HistoryFilter
import com.reelbridge.core.publish.PublishStatus

@Composable
fun HistoryScreen(vm: AppViewModel, onOpenJob: (String) -> Unit) {
    val jobs by vm.jobs.collect()
    val progress by vm.uploadProgress.collect()
    val busy by vm.busy.collect()
    var selected by rememberSaveable { mutableStateOf(HistoryFilter.ALL) }
    val visible = jobs.filter { selected.matches(it.status) }

    Column(Modifier.fillMaxSize().statusBarsPadding()) {
        Text("History", style = MaterialTheme.typography.headlineMedium, modifier = Modifier.padding(start = 20.dp, top = 20.dp, end = 20.dp))
        LazyRow(contentPadding = PaddingValues(horizontal = 20.dp, vertical = 12.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            items(HistoryFilter.entries) { f ->
                val count = jobs.count { f.matches(it.status) }
                FilterChip(
                    selected = selected == f, onClick = { selected = f },
                    label = { Text("${f.name.lowercase().replaceFirstChar { it.uppercase() }} ($count)") },
                )
            }
        }
        LazyColumn(contentPadding = PaddingValues(start = 20.dp, end = 20.dp, bottom = 20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            if (visible.isEmpty()) item { InfoBanner("Nothing here yet. Share a Reel to ReelBridge to get started.") }
            items(visible, key = { it.id }) { job ->
                JobRow(job, progress[job.id], vm.thumbnailFor(job.id), onClick = { onOpenJob(job.id) }) {
                    val canRetry = job.status == PublishStatus.FAILED || job.status == PublishStatus.NEEDS_RECONNECT
                    if (canRetry) IconButton(onClick = { vm.retry(job.id) }, enabled = !busy) { Icon(Icons.Rounded.Refresh, "Retry") }
                }
            }
        }
    }
}
