package com.reelbridge.app.ui.components

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.reelbridge.app.ui.theme.RB
import com.reelbridge.core.publish.PublishStatus
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File
import java.net.HttpURLConnection
import java.net.URL

/** Full-screen gradient background used by every screen. */
@Composable
fun GradientBackground(content: @Composable BoxScope.() -> Unit) {
    Box(Modifier.fillMaxSize().background(RB.BackgroundGradient), content = content)
}

@Composable
fun RBCard(
    modifier: Modifier = Modifier,
    padding: Dp = 18.dp,
    highlighted: Boolean = false,
    content: @Composable ColumnScope.() -> Unit,
) {
    val shape = MaterialTheme.shapes.large
    Column(
        modifier
            .clip(shape)
            .background(MaterialTheme.colorScheme.surface)
            .then(
                if (highlighted) Modifier.border(1.5.dp, RB.AccentGradient, shape)
                else Modifier.border(1.dp, MaterialTheme.colorScheme.outlineVariant, shape)
            )
            .padding(padding),
        content = content,
    )
}

@Composable
fun GradientButton(
    text: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    loading: Boolean = false,
    icon: ImageVector? = null,
) {
    val alpha by animateFloatAsState(if (enabled) 1f else 0.45f, label = "btnAlpha")
    Button(
        onClick = onClick,
        enabled = enabled && !loading,
        modifier = modifier.heightIn(min = 54.dp),
        contentPadding = PaddingValues(),
        shape = RoundedCornerShape(16.dp),
        colors = ButtonDefaults.buttonColors(containerColor = Color.Transparent, disabledContainerColor = Color.Transparent),
    ) {
        Box(
            Modifier.fillMaxWidth().heightIn(min = 54.dp)
                .background(RB.AccentGradient, RoundedCornerShape(16.dp), alpha = alpha)
                .padding(horizontal = 20.dp),
            contentAlignment = Alignment.Center,
        ) {
            if (loading) {
                CircularProgressIndicator(Modifier.size(22.dp), color = Color.White, strokeWidth = 2.5.dp)
            } else Row(verticalAlignment = Alignment.CenterVertically) {
                if (icon != null) { Icon(icon, null, tint = Color.White); Spacer(Modifier.width(8.dp)) }
                Text(text, color = Color.White, style = MaterialTheme.typography.labelLarge)
            }
        }
    }
}

@Composable
fun SectionTitle(text: String, modifier: Modifier = Modifier, action: (@Composable () -> Unit)? = null) {
    Row(modifier.fillMaxWidth().padding(top = 8.dp, bottom = 4.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(text, style = MaterialTheme.typography.titleMedium, modifier = Modifier.weight(1f))
        action?.invoke()
    }
}

data class StatusStyle(val color: Color, val icon: ImageVector)

fun statusStyle(status: PublishStatus): StatusStyle = when (status) {
    PublishStatus.PUBLISHED -> StatusStyle(RB.Success, Icons.Rounded.CheckCircle)
    PublishStatus.FAILED -> StatusStyle(RB.Error, Icons.Rounded.ErrorOutline)
    PublishStatus.NEEDS_RECONNECT -> StatusStyle(RB.Warning, Icons.Rounded.LinkOff)
    PublishStatus.PROCESSING -> StatusStyle(RB.Cyan, Icons.Rounded.HourglassTop)
    else -> StatusStyle(RB.Blue, Icons.Rounded.CloudUpload)
}

@Composable
fun StatusChip(status: PublishStatus, modifier: Modifier = Modifier) {
    val style = statusStyle(status)
    val color by animateColorAsState(style.color, label = "chip")
    Row(
        modifier.clip(CircleShape).background(color.copy(alpha = 0.15f)).padding(horizontal = 10.dp, vertical = 5.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(style.icon, null, tint = color, modifier = Modifier.size(14.dp))
        Spacer(Modifier.width(5.dp))
        Text(status.label, color = color, style = MaterialTheme.typography.labelMedium)
    }
}

@Composable
fun StatTile(label: String, value: String, icon: ImageVector, tint: Color, modifier: Modifier = Modifier) {
    RBCard(modifier, padding = 16.dp) {
        Box(Modifier.size(36.dp).clip(RoundedCornerShape(12.dp)).background(tint.copy(alpha = 0.16f)), contentAlignment = Alignment.Center) {
            Icon(icon, null, tint = tint, modifier = Modifier.size(20.dp))
        }
        Spacer(Modifier.height(12.dp))
        Text(value, style = MaterialTheme.typography.headlineMedium)
        Text(label, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@Composable
fun InfoBanner(text: String, modifier: Modifier = Modifier, color: Color = RB.Blue, icon: ImageVector = Icons.Rounded.Info) {
    Row(
        modifier.fillMaxWidth().clip(RoundedCornerShape(14.dp)).background(color.copy(alpha = 0.12f)).padding(14.dp),
        verticalAlignment = Alignment.Top,
    ) {
        Icon(icon, null, tint = color, modifier = Modifier.size(20.dp))
        Spacer(Modifier.width(10.dp))
        Text(text, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurface)
    }
}

@Composable
fun KeyValueRow(key: String, value: String, valueColor: Color = MaterialTheme.colorScheme.onSurface) {
    Row(Modifier.fillMaxWidth().padding(vertical = 4.dp)) {
        Text(key, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.weight(1f))
        Text(value, style = MaterialTheme.typography.bodyMedium, color = valueColor, fontWeight = FontWeight.Medium, maxLines = 1, overflow = TextOverflow.Ellipsis)
    }
}

/** Thumbnail from a local file path or an https URL, with a placeholder. */
@Composable
fun Thumbnail(source: String?, modifier: Modifier = Modifier) {
    val bitmap by produceState<Bitmap?>(null, source) {
        value = withContext(Dispatchers.IO) { loadBitmap(source) }
    }
    Box(modifier.clip(RoundedCornerShape(14.dp)).background(RB.Navy700), contentAlignment = Alignment.Center) {
        val bmp = bitmap
        if (bmp != null) {
            Image(bmp.asImageBitmap(), null, contentScale = ContentScale.Crop, modifier = Modifier.fillMaxSize())
        } else {
            Icon(Icons.Rounded.Movie, null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

private fun loadBitmap(source: String?): Bitmap? = runCatching {
    when {
        source.isNullOrBlank() -> null
        source.startsWith("https://") -> {
            val conn = URL(source).openConnection() as HttpURLConnection
            conn.connectTimeout = 10_000; conn.readTimeout = 10_000
            conn.inputStream.use { BitmapFactory.decodeStream(it) }.also { conn.disconnect() }
        }
        File(source).exists() -> BitmapFactory.decodeFile(source)
        else -> null
    }
}.getOrNull()

@Composable
fun BrandMark(size: Dp = 44.dp) {
    Box(Modifier.size(size).clip(RoundedCornerShape(size / 3)).background(RB.AccentGradient), contentAlignment = Alignment.Center) {
        Icon(Icons.Rounded.PlayArrow, null, tint = Color.White, modifier = Modifier.size(size * 0.6f))
    }
}
