package com.reelbridge.app.ui

import android.text.format.DateUtils
import java.text.DateFormat
import java.util.Date

fun relativeTime(ms: Long?): String =
    if (ms == null) "—" else DateUtils.getRelativeTimeSpanString(ms, System.currentTimeMillis(), DateUtils.MINUTE_IN_MILLIS).toString()

fun absoluteTime(ms: Long?): String =
    if (ms == null) "—" else DateFormat.getDateTimeInstance(DateFormat.MEDIUM, DateFormat.SHORT).format(Date(ms))

fun formatBytes(bytes: Long): String = when {
    bytes >= 1L shl 30 -> "%.1f GB".format(bytes / (1L shl 30).toDouble())
    bytes >= 1L shl 20 -> "%.1f MB".format(bytes / (1L shl 20).toDouble())
    bytes >= 1L shl 10 -> "%.0f KB".format(bytes / (1L shl 10).toDouble())
    else -> "$bytes B"
}

fun formatDuration(ms: Long): String = "%d:%02d".format(ms / 60_000, (ms / 1000) % 60)
