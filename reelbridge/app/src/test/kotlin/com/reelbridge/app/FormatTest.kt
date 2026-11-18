package com.reelbridge.app

import com.reelbridge.app.media.VideoInspector
import com.reelbridge.app.ui.formatBytes
import com.reelbridge.app.ui.formatDuration
import org.junit.Assert.assertEquals
import org.junit.Test

class FormatTest {
    @Test fun bytes() {
        assertEquals("512 B", formatBytes(512))
        assertEquals("2 KB", formatBytes(2048))
        assertEquals("1.5 MB", formatBytes(1_572_864))
        assertEquals("1.0 GB", formatBytes(1L shl 30))
    }

    @Test fun duration() {
        assertEquals("0:04", formatDuration(4_000))
        assertEquals("1:30", formatDuration(90_000))
    }

    @Test fun mimeAliases() {
        assertEquals("video/quicktime", VideoInspector.normalizeMime("video/x-quicktime"))
        assertEquals("video/mp4", VideoInspector.normalizeMime("VIDEO/MP4"))
        assertEquals("video/mp4", VideoInspector.normalizeMime("video/x-m4v"))
    }
}
