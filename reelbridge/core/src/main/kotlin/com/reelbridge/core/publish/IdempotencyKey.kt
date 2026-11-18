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

    fun forInstagramMedia(uid: String, igMediaId: String, pageId: String): String =
        sha256Hex("v1|$uid|ig:$igMediaId|$pageId")

    fun sha256Hex(value: String): String = hex(MessageDigest.getInstance("SHA-256").digest(value.toByteArray()))

    fun hex(bytes: ByteArray): String = bytes.joinToString("") { "%02x".format(it) }

    private val KEY = Regex("^[0-9a-f]{64}$")
    fun isValid(key: String): Boolean = KEY.matches(key)
}
