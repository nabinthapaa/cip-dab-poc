package com.reelbridge.app.ui.connect

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material.icons.rounded.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.unit.dp
import com.reelbridge.app.BuildConfig
import com.reelbridge.app.data.model.FacebookConnection
import com.reelbridge.app.data.model.FacebookPage
import com.reelbridge.app.facebook.FacebookPermissions
import com.reelbridge.app.facebook.rememberFacebookLogin
import com.reelbridge.app.ui.AppViewModel
import com.reelbridge.app.ui.absoluteTime
import com.reelbridge.app.ui.collect
import com.reelbridge.app.ui.components.*
import com.reelbridge.app.ui.theme.RB

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ConnectScreen(vm: AppViewModel, onBack: () -> Unit) {
    val user by vm.user.collect()
    val connection by vm.connection.collect()
    val pages by vm.pages.collect()
    val busy by vm.busy.collect()
    val login = if (BuildConfig.FACEBOOK_CONFIGURED) rememberFacebookLogin(vm::onFacebookLogin) else null
    var confirmDisconnect by remember { mutableStateOf(false) }

    Column(Modifier.fillMaxSize()) {
        TopAppBar(
            title = { Text("Facebook connection") },
            navigationIcon = { IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Rounded.ArrowBack, "Back") } },
            colors = TopAppBarDefaults.topAppBarColors(containerColor = androidx.compose.ui.graphics.Color.Transparent),
        )
        LazyColumn(contentPadding = PaddingValues(20.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            if (!BuildConfig.FACEBOOK_CONFIGURED) {
                item {
                    InfoBanner(
                        "This build has no Facebook App ID. Set reelbridge.facebookAppId and reelbridge.facebookClientToken and rebuild (see README).",
                        color = RB.Warning, icon = Icons.Rounded.Warning,
                    )
                }
            }
            if (user == null || !connection.connected) {
                item { ConnectHero(connection, busy, enabled = login != null) { login?.invoke() } }
            } else {
                item { AccountCard(connection, busy, onCheck = vm::checkConnection, onReconnect = { login?.invoke() }, onDisconnect = { confirmDisconnect = true }) }
                item {
                    SectionTitle("Destination Page") {
                        TextButton(onClick = vm::refreshPages, enabled = !busy) { Text("Refresh") }
                    }
                }
                if (pages.isEmpty()) {
                    item {
                        InfoBanner("No Pages found. In Facebook Login, make sure you selected your Page and allowed all permissions, then tap Reconnect.")
                    }
                }
                items(pages, key = { it.pageId }) { page ->
                    PageRow(page, selected = page.pageId == connection.selectedPageId, enabled = !busy) { vm.selectPage(page.pageId) }
                }
            }
        }
    }

    if (confirmDisconnect) {
        var revoke by remember { mutableStateOf(true) }
        AlertDialog(
            onDismissRequest = { confirmDisconnect = false },
            title = { Text("Disconnect Facebook?") },
            text = {
                Column {
                    Text("ReelBridge will delete its stored Facebook access and stop publishing. Your existing Reels stay on Facebook.")
                    Row(Modifier.padding(top = 12.dp).clickable { revoke = !revoke }, verticalAlignment = Alignment.CenterVertically) {
                        Checkbox(revoke, { revoke = it })
                        Text("Also remove ReelBridge's permissions from my Facebook account")
                    }
                }
            },
            confirmButton = { TextButton(onClick = { confirmDisconnect = false; vm.disconnect(revoke) }) { Text("Disconnect", color = RB.Error) } },
            dismissButton = { TextButton(onClick = { confirmDisconnect = false }) { Text("Cancel") } },
        )
    }
}

@Composable
private fun ConnectHero(connection: FacebookConnection, busy: Boolean, enabled: Boolean, onLogin: () -> Unit) {
    RBCard(Modifier.fillMaxWidth(), highlighted = true) {
        BrandMark(56.dp)
        Spacer(Modifier.height(16.dp))
        Text("Connect your Facebook Page", style = MaterialTheme.typography.headlineSmall)
        Spacer(Modifier.height(8.dp))
        Text(
            "Sign in with Facebook and allow ReelBridge to publish to a Page you manage. You only do this once.",
            style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Spacer(Modifier.height(14.dp))
        listOf(
            "pages_show_list" to "See the Pages you manage",
            "pages_read_engagement" to "Read Page details",
            "pages_manage_posts" to "Publish Reels to your Page",
            "instagram_basic" to "Optional: find your own Instagram Reels by link",
        ).forEach { (_, label) ->
            Row(Modifier.padding(vertical = 3.dp), verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Rounded.Check, null, tint = RB.Success, modifier = Modifier.size(18.dp))
                Spacer(Modifier.width(8.dp))
                Text(label, style = MaterialTheme.typography.bodyMedium)
            }
        }
        connection.lastError?.let { InfoBanner(it, Modifier.padding(top = 12.dp), color = RB.Error, icon = Icons.Rounded.ErrorOutline) }
        Spacer(Modifier.height(18.dp))
        GradientButton("Continue with Facebook", onLogin, Modifier.fillMaxWidth(), enabled = enabled, loading = busy, icon = Icons.Rounded.Facebook)
        Spacer(Modifier.height(10.dp))
        Text(
            "ReelBridge never sees your password. Access tokens are stored encrypted on the ReelBridge server, never on this phone.",
            style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

@Composable
private fun AccountCard(c: FacebookConnection, busy: Boolean, onCheck: () -> Unit, onReconnect: () -> Unit, onDisconnect: () -> Unit) {
    RBCard(Modifier.fillMaxWidth()) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Rounded.AccountCircle, null, tint = RB.Blue, modifier = Modifier.size(40.dp))
            Spacer(Modifier.width(12.dp))
            Column(Modifier.weight(1f)) {
                Text(c.fbUserName ?: "Facebook account", style = MaterialTheme.typography.titleMedium)
                Text(
                    if (c.connected) "Connected" else c.status.replaceFirstChar { it.uppercase() },
                    color = if (c.connected) RB.Success else RB.Warning, style = MaterialTheme.typography.bodySmall,
                )
            }
        }
        Spacer(Modifier.height(12.dp))
        KeyValueRow("Page access", if (c.missingPermissions.isEmpty()) "All required permissions" else "Missing ${c.missingPermissions.size}",
            if (c.missingPermissions.isEmpty()) RB.Success else RB.Warning)
        KeyValueRow("Token expires", c.userTokenExpiresAtMs?.let(::absoluteTime) ?: "Never (Page token)")
        KeyValueRow("Data access until", absoluteTime(c.dataAccessExpiresAtMs))
        KeyValueRow("Last checked", absoluteTime(c.checkedAtMs))
        if (c.missingPermissions.isNotEmpty()) {
            InfoBanner("Missing: ${c.missingPermissions.joinToString()}", Modifier.padding(top = 8.dp), color = RB.Warning, icon = Icons.Rounded.Warning)
        }
        val optionalMissing = FacebookPermissions.OPTIONAL.filter { it !in c.grantedPermissions }
        if ("instagram_basic" in optionalMissing) {
            Text(
                "Tip: allow instagram_basic to publish your own Instagram Reels straight from a shared link.",
                style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(top = 8.dp),
            )
        }
        Spacer(Modifier.height(12.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            OutlinedButton(onClick = onCheck, enabled = !busy) { Text("Check") }
            OutlinedButton(onClick = onReconnect, enabled = !busy) { Text("Reconnect") }
            Spacer(Modifier.weight(1f))
            TextButton(onClick = onDisconnect, enabled = !busy) { Text("Disconnect", color = RB.Error) }
        }
    }
}

@Composable
private fun PageRow(page: FacebookPage, selected: Boolean, enabled: Boolean, onSelect: () -> Unit) {
    RBCard(
        Modifier.fillMaxWidth().clickable(enabled = enabled && page.canPublish && !selected, onClick = onSelect),
        padding = 14.dp, highlighted = selected,
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Thumbnail(page.pictureUrl, Modifier.size(44.dp).clip(CircleShape))
            Spacer(Modifier.width(12.dp))
            Column(Modifier.weight(1f)) {
                Text(page.name, style = MaterialTheme.typography.titleSmall)
                Text(
                    when {
                        !page.canPublish -> "You can't publish to this Page (needs Create Content access)"
                        page.instagramUsername != null -> "Linked Instagram: @${page.instagramUsername}"
                        else -> "No linked Instagram account"
                    },
                    style = MaterialTheme.typography.bodySmall,
                    color = if (page.canPublish) MaterialTheme.colorScheme.onSurfaceVariant else RB.Warning,
                )
            }
            RadioButton(selected = selected, onClick = onSelect, enabled = enabled && page.canPublish)
        }
    }
}
