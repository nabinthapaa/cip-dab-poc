package com.reelbridge.core.publish

import java.security.MessageDigest

/**
 * Deterministic job id. The same user publishing the same video bytes to the same Page always
 * produces the same key, so the Firestore `create` of publishing_jobs/{key} fails for a duplicate
 * and the backend never posts the same Reel twice.
 */
object IdempotencyKey {
    fun forVideo(uid: String, contentSha256: String, pageId: String): String =
        sha256Hex("v1|$uid|video:${contentSha256.lowercase()}|$pageId")

    /**
     * Identity of what will be published: the shared video's SHA-256, or – when an outro is
     * appended – a hash of both, so "with outro" and "without outro" are different posts while
     * re-sharing the same combination is still detected as a duplicate.
     */
    fun contentId(videoSha256: String, outroSha256: String?): String =
        if (outroSha256 == null) videoSha256.lowercase() else sha256Hex("${videoSha256.lowercase()}|outro:${outroSha256.lowercase()}")

    fun forInstagramMedia(uid: String, igMediaId: String, pageId: String): String =
        sha256Hex("v1|$uid|ig:$igMediaId|$pageId")

    fun sha256Hex(value: String): String = hex(MessageDigest.getInstance("SHA-256").digest(value.toByteArray()))

    fun hex(bytes: ByteArray): String = bytes.joinToString("") { "%02x".format(it) }

    private val KEY = Regex("^[0-9a-f]{64}$")
    fun isValid(key: String): Boolean = KEY.matches(key)
}
