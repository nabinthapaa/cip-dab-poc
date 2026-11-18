package com.reelbridge.core.publish

/** Exponential backoff shared by the client queue (mirrors backend/functions/src/retry.ts). */
object RetryPolicy {
    const val MAX_AUTOMATIC_ATTEMPTS = 3
    private const val BASE_DELAY_MS = 60_000L
    private const val MAX_DELAY_MS = 30 * 60_000L

    fun delayMs(attempt: Int): Long {
        val shift = (attempt - 1).coerceIn(0, 10)
        return (BASE_DELAY_MS shl shift).coerceAtMost(MAX_DELAY_MS)
    }

    fun shouldAutoRetry(attempts: Int, retryable: Boolean): Boolean = retryable && attempts < MAX_AUTOMATIC_ATTEMPTS
}
