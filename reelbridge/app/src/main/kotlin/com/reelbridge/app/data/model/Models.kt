package com.reelbridge.app.data.model

import com.reelbridge.core.publish.PublishStatus
import com.reelbridge.core.video.VideoMetadata
import com.reelbridge.core.video.VideoValidation

/** Public (non-secret) view of facebook_connections/{uid}. Tokens never reach the client. */
data class FacebookConnection(
    val connected: Boolean,
    val status: String,
    val fbUserName: String?,
    val selectedPageId: String?,
    val selectedPageName: String?,
    val grantedPermissions: List<String>,
    val missingPermissions: List<String>,
    val userTokenExpiresAtMs: Long?,
    val dataAccessExpiresAtMs: Long?,
    val checkedAtMs: Long?,
    val lastError: String?,
) {
    companion object {
        val NONE = FacebookConnection(false, "disconnected", null, null, null, emptyList(), emptyList(), null, null, null, null)
    }
}

data class FacebookPage(
    val pageId: String,
    val name: String,
    val pictureUrl: String?,
    val canPublish: Boolean,
    val instagramUsername: String?,
)

data class PublishJob(
    val id: String,
    val status: PublishStatus,
    val caption: String,
    val pageId: String,
    val pageName: String?,
    val source: String,
    val thumbnailUrl: String?,
    val errorMessage: String?,
    val retryable: Boolean,
    val attempts: Int,
    val createdAtMs: Long?,
    val updatedAtMs: Long?,
    val publishedAtMs: Long?,
    val permalinkUrl: String?,
)

data class UserSettings(
    val autoPublish: Boolean = false,
    val captionTemplate: String = "{caption}",
    val defaultHashtags: String = "",
    val notifications: Boolean = true,
    /** Append the saved outro to Reels by default (can be changed per Reel before publishing). */
    val outroEnabled: Boolean = false,
)

/** A video the user shared, copied into app-private storage. */
data class Draft(
    val id: String,
    val videoPath: String,
    val thumbnailPath: String?,
    val sha256: String,
    val metadata: VideoMetadata,
    val captionHint: String?,
    val createdAtMs: Long,
)

data class InspectedDraft(val draft: Draft, val validation: VideoValidation)

/** Result of resolving an Instagram link against the user's OWN connected Instagram account. */
data class InstagramResolution(
    val found: Boolean,
    val mediaId: String?,
    val caption: String?,
    val thumbnailUrl: String?,
    val reason: String?,
    val message: String?,
)
