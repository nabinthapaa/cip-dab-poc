package com.reelbridge.core.share

/**
 * Decides what an incoming ACTION_SEND / ACTION_SEND_MULTIPLE share contains.
 * Pure logic so it can be unit tested without Android.
 */
object ShareClassifier {
    const val ACTION_SEND = "android.intent.action.SEND"
    const val ACTION_SEND_MULTIPLE = "android.intent.action.SEND_MULTIPLE"

    fun classify(input: ShareInput): SharedPayload {
        if (input.action != ACTION_SEND && input.action != ACTION_SEND_MULTIPLE) {
            return SharedPayload.Unsupported(UnsupportedReason.UNKNOWN_ACTION)
        }

        val text = listOfNotNull(input.text, input.subject).joinToString("\n").ifBlank { null }

        if (input.streams.isNotEmpty()) {
            val videos = input.streams.filter { isVideo(it.mimeType ?: input.mimeType) }
            return if (videos.isNotEmpty()) {
                SharedPayload.Videos(videos, captionHint = input.text?.let(::stripUrls)?.ifBlank { null })
            } else {
                SharedPayload.Unsupported(UnsupportedReason.NOT_A_VIDEO)
            }
        }

        if (text == null) return SharedPayload.Unsupported(UnsupportedReason.EMPTY)

        val urls = InstagramUrls.extractUrls(text)
        urls.firstNotNullOfOrNull(InstagramUrls::parse)?.let { link ->
            return if (link.kind == InstagramLinkKind.STORY) {
                SharedPayload.Unsupported(UnsupportedReason.INSTAGRAM_STORY)
            } else link
        }
        urls.firstOrNull()?.let { return SharedPayload.OtherLink(it) }
        return SharedPayload.Unsupported(UnsupportedReason.TEXT_WITHOUT_LINK)
    }

    fun isVideo(mimeType: String?): Boolean = mimeType?.lowercase()?.startsWith("video/") == true

    private fun stripUrls(text: String): String =
        InstagramUrls.extractUrls(text).fold(text) { acc, url -> acc.replace(url, "") }.trim()
}
