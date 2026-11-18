package com.reelbridge.core.share

/**
 * Parses Instagram links. Only extracts identifiers – it never fetches anything.
 */
object InstagramUrls {
    private val URL_IN_TEXT = Regex("""https?://[^\s<>"']+""", RegexOption.IGNORE_CASE)

    private val INSTAGRAM = Regex(
        """^https?://(?:www\.|m\.)?(?:instagram\.com|instagr\.am)/(?:[A-Za-z0-9._]+/)?(reels?|p|tv|stories)/([A-Za-z0-9_\-.]+)/?""",
        RegexOption.IGNORE_CASE,
    )

    /** Returns every http(s) URL found in [text], with trailing punctuation trimmed. */
    fun extractUrls(text: String?): List<String> =
        if (text.isNullOrBlank()) emptyList()
        else URL_IN_TEXT.findAll(text).map { it.value.trimEnd('.', ',', ')', ']', '!', '?', ';') }.toList()

    /** Parses an Instagram media URL, or returns null if [url] is not one. */
    fun parse(url: String): SharedPayload.InstagramLink? {
        val m = INSTAGRAM.find(url.trim()) ?: return null
        val kind = when (m.groupValues[1].lowercase()) {
            "reel", "reels" -> InstagramLinkKind.REEL
            "p" -> InstagramLinkKind.POST
            "tv" -> InstagramLinkKind.TV
            else -> InstagramLinkKind.STORY
        }
        val shortcode = m.groupValues[2]
        val canonical = when (kind) {
            InstagramLinkKind.STORY -> url.trim().substringBefore('?')
            else -> "https://www.instagram.com/${if (kind == InstagramLinkKind.REEL) "reel" else m.groupValues[1].lowercase()}/$shortcode/"
        }
        return SharedPayload.InstagramLink(canonical, shortcode, kind)
    }
}
