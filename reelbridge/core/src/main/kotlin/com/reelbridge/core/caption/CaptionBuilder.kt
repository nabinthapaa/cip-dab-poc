package com.reelbridge.core.caption

import com.reelbridge.core.share.InstagramUrls

/**
 * Builds the Reel description from the shared text, the user's template and default hashtags.
 * Template placeholder: `{caption}`. Links from the share sheet are removed.
 */
object CaptionBuilder {
    const val MAX_LENGTH = 2_200
    const val DEFAULT_TEMPLATE = "{caption}"

    fun build(sharedText: String?, template: String?, defaultHashtags: String?): String {
        val base = clean(sharedText)
        val tpl = template?.takeIf { it.isNotBlank() } ?: DEFAULT_TEMPLATE
        val withTemplate = if (tpl.contains("{caption}")) tpl.replace("{caption}", base) else listOf(base, tpl).filter { it.isNotBlank() }.joinToString("\n\n")
        val tags = normalizeHashtags(defaultHashtags)
            .filterNot { tag -> withTemplate.contains(tag, ignoreCase = true) }
        val full = listOf(withTemplate.trim(), tags.joinToString(" ")).filter { it.isNotBlank() }.joinToString("\n\n")
        return truncate(full.replace(Regex("\n{3,}"), "\n\n").trim())
    }

    /** Removes URLs and collapses whitespace on each line. */
    fun clean(text: String?): String {
        if (text.isNullOrBlank()) return ""
        val noUrls = InstagramUrls.extractUrls(text).fold(text) { acc, url -> acc.replace(url, "") }
        return noUrls.lines().joinToString("\n") { it.replace(Regex("[ \t]+"), " ").trim() }.trim()
    }

    /** "foo, #bar baz" -> ["#foo", "#bar", "#baz"] (deduplicated, order kept). */
    fun normalizeHashtags(raw: String?): List<String> =
        raw.orEmpty().split(Regex("[\\s,]+"))
            .map { it.trim().trimStart('#') }
            .filter { it.isNotEmpty() && it.all { c -> c.isLetterOrDigit() || c == '_' } }
            .map { "#$it" }
            .distinctBy { it.lowercase() }

    fun truncate(text: String): String =
        if (text.length <= MAX_LENGTH) text else text.take(MAX_LENGTH - 1).trimEnd() + "…"
}
