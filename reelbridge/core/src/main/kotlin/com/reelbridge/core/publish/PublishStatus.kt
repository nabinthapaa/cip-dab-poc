package com.reelbridge.core.publish

/**
 * Status of a publishing job. The wire values are shared with the Cloud Functions backend
 * (backend/functions/src/model.ts) – keep them in sync.
 */
enum class PublishStatus(val wire: String, val label: String) {
    PREPARING("preparing", "Preparing"),
    UPLOADING("uploading", "Uploading"),
    QUEUED("queued", "Queued"),
    PUBLISHING("publishing", "Publishing"),
    PROCESSING("processing", "Processing on Facebook"),
    PUBLISHED("published", "Published"),
    FAILED("failed", "Failed"),
    NEEDS_RECONNECT("needs_reconnect", "Reconnect Facebook");

    val isTerminal: Boolean get() = this == PUBLISHED || this == FAILED || this == NEEDS_RECONNECT
    val isPending: Boolean get() = !isTerminal

    companion object {
        fun fromWire(value: String?): PublishStatus =
            entries.firstOrNull { it.wire == value } ?: FAILED
    }
}

enum class HistoryFilter { ALL, PUBLISHED, PENDING, FAILED;
    fun matches(status: PublishStatus): Boolean = when (this) {
        ALL -> true
        PUBLISHED -> status == PublishStatus.PUBLISHED
        PENDING -> status.isPending
        FAILED -> status == PublishStatus.FAILED || status == PublishStatus.NEEDS_RECONNECT
    }
}
