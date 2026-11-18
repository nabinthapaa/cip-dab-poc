package com.reelbridge.app.share

import android.net.Uri
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.reelbridge.app.AppContainer
import com.reelbridge.app.data.BackendException
import com.reelbridge.app.data.DraftTooLargeException
import com.reelbridge.app.data.FacebookRepository
import com.reelbridge.app.data.model.InspectedDraft
import com.reelbridge.app.data.model.InstagramResolution
import com.reelbridge.app.ui.AppViewModel
import com.reelbridge.core.caption.CaptionBuilder
import com.reelbridge.core.share.ShareClassifier
import com.reelbridge.core.share.ShareInput
import com.reelbridge.core.share.SharedPayload
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull

sealed interface ShareUiState {
    data class Working(val message: String) : ShareUiState
    /** Cannot continue. [openApp] = the fix is inside ReelBridge (connect / choose Page). */
    data class Blocked(val title: String, val message: String, val openApp: Boolean = false) : ShareUiState
    data class ReviewVideos(val drafts: List<InspectedDraft>, val caption: String, val pageName: String) : ShareUiState
    data class ReviewInstagram(val url: String, val resolution: InstagramResolution, val caption: String, val pageName: String) : ShareUiState
    data class Done(val title: String, val message: String, val autoClose: Boolean) : ShareUiState
}

class ShareViewModel(private val c: AppContainer) : ViewModel() {
    private val _state = MutableStateFlow<ShareUiState>(ShareUiState.Working("Reading shared content…"))
    val state: StateFlow<ShareUiState> = _state
    private var handled = false

    private data class Destination(val uid: String, val pageId: String, val pageName: String)

    fun handle(input: ShareInput) {
        if (handled) return
        handled = true
        viewModelScope.launch { process(input) }
    }

    private suspend fun process(input: ShareInput) {
        val payload = ShareClassifier.classify(input)
        when (payload) {
            is SharedPayload.Unsupported -> { _state.value = ShareUiState.Blocked("Can't use this share", payload.reason.message); return }
            is SharedPayload.OtherLink -> {
                _state.value = ShareUiState.Blocked(
                    "That's a web link, not a video",
                    "ReelBridge can publish a video file you share, or a Reel from your own connected Instagram account. It can't download videos from websites.",
                )
                return
            }
            else -> Unit
        }

        val dest = destination() ?: return
        val settings = c.settings.current()

        when (payload) {
            is SharedPayload.Videos -> handleVideos(payload, dest, settings.autoPublish, settings.captionTemplate, settings.defaultHashtags)
            is SharedPayload.InstagramLink -> handleInstagram(payload, dest, settings.autoPublish, settings.captionTemplate, settings.defaultHashtags)
            else -> Unit
        }
    }

    /** Checks the one-time setup. Returns null (and shows why) when it is incomplete. */
    private suspend fun destination(): Destination? {
        if (!c.firebaseReady) {
            _state.value = ShareUiState.Blocked("Setup required", "This build isn't connected to Firebase. See the README.")
            return null
        }
        val user = c.auth.currentUser
        if (user == null) {
            _state.value = ShareUiState.Blocked("Connect Facebook first", "Open ReelBridge and connect your Facebook Page. You only need to do this once.", openApp = true)
            return null
        }
        _state.value = ShareUiState.Working("Checking your Facebook Page…")
        val conn = withTimeoutOrNull(10_000) { c.facebook.connection(user.uid).first() }
        return when {
            conn == null || conn.status == FacebookRepository.STATUS_ERROR -> { _state.value = ShareUiState.Blocked("No connection", "Couldn't reach ReelBridge. Check your internet connection and share again."); null }
            !conn.connected -> { _state.value = ShareUiState.Blocked("Reconnect Facebook", "Your Facebook connection needs attention. Open ReelBridge to reconnect.", openApp = true); null }
            conn.selectedPageId == null -> { _state.value = ShareUiState.Blocked("Choose a Page", "Open ReelBridge and choose which Facebook Page to publish to.", openApp = true); null }
            else -> Destination(user.uid, conn.selectedPageId, conn.selectedPageName ?: "your Page")
        }
    }

    private suspend fun handleVideos(p: SharedPayload.Videos, d: Destination, auto: Boolean, template: String, tags: String) {
        val drafts = mutableListOf<InspectedDraft>()
        val problems = mutableListOf<String>()
        p.streams.forEachIndexed { i, s ->
            _state.value = ShareUiState.Working(if (p.streams.size > 1) "Preparing video ${i + 1} of ${p.streams.size}…" else "Preparing video…")
            try {
                drafts += c.drafts.import(Uri.parse(s.uri), s.mimeType, p.captionHint)
            } catch (e: DraftTooLargeException) {
                problems += e.message.orEmpty()
            } catch (e: SecurityException) {
                problems += "ReelBridge wasn't given access to the shared file. Try sharing it again."
            } catch (e: Exception) {
                problems += "Couldn't read the shared video (${e.message ?: e.javaClass.simpleName})."
            }
        }
        if (drafts.isEmpty()) {
            _state.value = ShareUiState.Blocked("Couldn't prepare the video", problems.distinct().joinToString("\n"))
            return
        }
        val caption = CaptionBuilder.build(p.captionHint, template, tags)
        if (auto && drafts.all { it.validation.isPublishable }) {
            enqueue(drafts, caption, d, autoClose = true)
        } else {
            _state.value = ShareUiState.ReviewVideos(drafts, caption, d.pageName)
        }
    }

    fun publishVideos(caption: String) {
        val s = _state.value as? ShareUiState.ReviewVideos ?: return
        viewModelScope.launch {
            val d = destination() ?: return@launch
            enqueue(s.drafts.filter { it.validation.isPublishable }, CaptionBuilder.truncate(caption), d, autoClose = false)
        }
    }

    private fun enqueue(drafts: List<InspectedDraft>, caption: String, d: Destination, autoClose: Boolean) {
        drafts.forEach { c.queue.enqueue(d.uid, it.draft.id, it.draft.sha256, caption, d.pageId, d.pageName) }
        val n = drafts.size
        _state.value = ShareUiState.Done(
            if (n == 1) "Publishing to ${d.pageName}" else "Publishing $n Reels to ${d.pageName}",
            "Uploading in the background. You can go back to Instagram — we'll notify you when it's live.",
            autoClose,
        )
    }

    private suspend fun handleInstagram(p: SharedPayload.InstagramLink, d: Destination, auto: Boolean, template: String, tags: String) {
        _state.value = ShareUiState.Working("Looking for this Reel in your Instagram account…")
        val res = try {
            c.backend.resolveInstagramReel(p.url)
        } catch (e: BackendException) {
            _state.value = ShareUiState.Blocked("Couldn't check this link", AppViewModel.friendly(e)); return
        }
        if (!res.found) {
            _state.value = ShareUiState.Blocked(
                "Share the video file instead",
                (res.message ?: "This Reel isn't from your connected Instagram account.") +
                    "\n\nInstagram only shares a link here, not the video. ReelBridge can publish Reels from your own linked Instagram professional account, or any video file you share directly (for example from your gallery). It never downloads videos from Instagram pages.",
                openApp = res.reason == "missing_permission" || res.reason == "no_instagram_account",
            )
            return
        }
        val caption = CaptionBuilder.build(res.caption, template, tags)
        if (auto) importInstagram(p.url, caption, d, autoClose = true)
        else _state.value = ShareUiState.ReviewInstagram(p.url, res, caption, d.pageName)
    }

    fun publishInstagram(caption: String) {
        val s = _state.value as? ShareUiState.ReviewInstagram ?: return
        viewModelScope.launch {
            val d = destination() ?: return@launch
            importInstagram(s.url, CaptionBuilder.truncate(caption), d, autoClose = false)
        }
    }

    private suspend fun importInstagram(url: String, caption: String, d: Destination, autoClose: Boolean) {
        _state.value = ShareUiState.Working("Sending your Reel to ${d.pageName}…")
        try {
            val r = c.backend.importInstagramReel(url, caption)
            if (r.jobId.isNotBlank()) c.queue.watch(r.jobId)
            _state.value = if (r.duplicate) ShareUiState.Done("Already shared", "This Reel was already sent to ${d.pageName} (status: ${r.status ?: "unknown"}). It won't be posted twice.", autoClose)
            else ShareUiState.Done("Publishing to ${d.pageName}", "ReelBridge is publishing your Reel. We'll notify you when it's live.", autoClose)
        } catch (e: BackendException) {
            _state.value = ShareUiState.Blocked("Couldn't publish", AppViewModel.friendly(e))
        }
    }
}
