package com.reelbridge.core.share

/** A single stream (file) attached to a share intent. */
data class SharedStream(val uri: String, val mimeType: String?)

/** Raw, platform-independent view of an incoming share intent. */
data class ShareInput(
    val action: String?,
    val mimeType: String?,
    val text: String?,
    val subject: String?,
    val streams: List<SharedStream>,
)

/** What ReelBridge decided the shared content is. */
sealed interface SharedPayload {
    /** One or more video files the user shared. `captionHint` is any accompanying text. */
    data class Videos(val streams: List<SharedStream>, val captionHint: String?) : SharedPayload

    /** A link to an Instagram post / reel. The media itself is NOT included. */
    data class InstagramLink(val url: String, val shortcode: String, val kind: InstagramLinkKind) : SharedPayload

    /** Some other web link; ReelBridge cannot publish arbitrary web pages. */
    data class OtherLink(val url: String) : SharedPayload

    /** Content ReelBridge cannot use, with a human-readable reason. */
    data class Unsupported(val reason: UnsupportedReason) : SharedPayload
}

enum class InstagramLinkKind { REEL, POST, TV, STORY }

enum class UnsupportedReason(val message: String) {
    EMPTY("Nothing was shared. Try sharing the Reel again."),
    NOT_A_VIDEO("ReelBridge can only publish videos. The shared item is not a video file."),
    TEXT_WITHOUT_LINK("The shared text does not contain a video or an Instagram link."),
    UNKNOWN_ACTION("This share type is not supported."),
    INSTAGRAM_STORY("Instagram Stories cannot be published as Reels. Share a Reel instead."),
}
