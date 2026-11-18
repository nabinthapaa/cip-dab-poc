package com.reelbridge.app.share

import android.content.ContentResolver
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.webkit.MimeTypeMap
import com.reelbridge.core.share.ShareInput
import com.reelbridge.core.share.SharedStream

/** Converts an Android share Intent into the platform-independent [ShareInput]. */
object ShareIntentParser {

    fun parse(intent: Intent, resolver: ContentResolver): ShareInput {
        val uris = LinkedHashSet<Uri>()
        when (intent.action) {
            Intent.ACTION_SEND -> streamExtra(intent)?.let(uris::add)
            Intent.ACTION_SEND_MULTIPLE -> uris += streamListExtra(intent)
        }
        intent.clipData?.let { clip -> for (i in 0 until clip.itemCount) clip.getItemAt(i).uri?.let(uris::add) }

        return ShareInput(
            action = intent.action,
            mimeType = intent.type,
            text = intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString(),
            subject = intent.getStringExtra(Intent.EXTRA_SUBJECT),
            streams = uris.filter { it.scheme == ContentResolver.SCHEME_CONTENT || it.scheme == ContentResolver.SCHEME_FILE }
                .map { SharedStream(it.toString(), mimeOf(resolver, it)) },
        )
    }

    private fun mimeOf(resolver: ContentResolver, uri: Uri): String? =
        runCatching { resolver.getType(uri) }.getOrNull()
            ?: MimeTypeMap.getFileExtensionFromUrl(uri.toString())?.lowercase()?.let { MimeTypeMap.getSingleton().getMimeTypeFromExtension(it) }

    @Suppress("DEPRECATION")
    private fun streamExtra(intent: Intent): Uri? =
        if (Build.VERSION.SDK_INT >= 33) intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
        else intent.getParcelableExtra(Intent.EXTRA_STREAM) as? Uri

    @Suppress("DEPRECATION")
    private fun streamListExtra(intent: Intent): List<Uri> =
        (if (Build.VERSION.SDK_INT >= 33) intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java)
        else intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)).orEmpty()
}
