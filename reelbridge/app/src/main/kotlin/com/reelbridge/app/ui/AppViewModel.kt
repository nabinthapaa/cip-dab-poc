package com.reelbridge.app.ui

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import com.google.firebase.auth.FirebaseUser
import com.reelbridge.app.AppContainer
import com.reelbridge.app.ReelBridgeApp
import com.reelbridge.app.data.BackendException
import com.reelbridge.app.data.DraftTooLargeException
import com.reelbridge.app.data.InvalidOutroException
import com.reelbridge.app.data.Outro
import com.reelbridge.app.data.model.*
import com.reelbridge.app.facebook.FacebookLoginOutcome
import com.reelbridge.app.facebook.facebookLogOut
import com.reelbridge.core.publish.PublishStatus
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.launch
import androidx.lifecycle.ViewModelProvider.AndroidViewModelFactory.Companion.APPLICATION_KEY

data class HomeStats(val published: Int, val pending: Int, val failed: Int)

@OptIn(ExperimentalCoroutinesApi::class)
class AppViewModel(private val c: AppContainer) : ViewModel() {

    val user: StateFlow<FirebaseUser?> = c.auth.userFlow.stateIn(viewModelScope, SharingStarted.Eagerly, c.auth.currentUser)

    val connection: StateFlow<FacebookConnection> = user.flatMapLatest { u ->
        if (u == null) flowOf(FacebookConnection.NONE) else c.facebook.connection(u.uid)
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), FacebookConnection.NONE)

    val pages: StateFlow<List<FacebookPage>> = user.flatMapLatest { u ->
        if (u == null) flowOf(emptyList()) else c.facebook.pages(u.uid)
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), emptyList())

    val jobs: StateFlow<List<PublishJob>> = user.flatMapLatest { u ->
        if (u == null) flowOf(emptyList()) else c.jobs.jobs(u.uid)
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), emptyList())

    val settings: StateFlow<UserSettings> = c.settings.settings.stateIn(viewModelScope, SharingStarted.Eagerly, UserSettings())

    val outro: StateFlow<Outro?> = c.outros.outro

    val uploadStages: StateFlow<Map<String, String>> = c.queue.uploadStages.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), emptyMap())

    val uploadProgress: StateFlow<Map<String, Float>> = c.queue.uploadProgress.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), emptyMap())

    val stats: StateFlow<HomeStats> = combine(jobs, c.queue.pendingLocalUploads) { list, local ->
        HomeStats(
            published = list.count { it.status == PublishStatus.PUBLISHED },
            pending = list.count { it.status.isPending } + local,
            failed = list.count { it.status == PublishStatus.FAILED || it.status == PublishStatus.NEEDS_RECONNECT },
        )
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), HomeStats(0, 0, 0))

    private val _busy = MutableStateFlow(false)
    val busy: StateFlow<Boolean> = _busy

    private val _messages = MutableSharedFlow<String>(extraBufferCapacity = 4)
    val messages: SharedFlow<String> = _messages

    private fun launchBusy(block: suspend () -> Unit) = viewModelScope.launch {
        _busy.value = true
        try { block() } catch (e: BackendException) { _messages.emit(friendly(e)) } catch (e: Exception) {
            _messages.emit(e.message ?: "Something went wrong")
        } finally { _busy.value = false }
    }

    fun onFacebookLogin(outcome: FacebookLoginOutcome) {
        when (outcome) {
            FacebookLoginOutcome.Cancelled -> _messages.tryEmit("Facebook Login was cancelled.")
            is FacebookLoginOutcome.Error -> _messages.tryEmit(outcome.message)
            is FacebookLoginOutcome.Success -> launchBusy {
                c.auth.signInWithFacebook(outcome.accessToken)
                val count = c.backend.connectFacebook(outcome.accessToken)
                c.settings.update { it } // mirror settings to users/{uid}
                _messages.emit(
                    if (count == 0) "Connected, but no Facebook Pages were found. Make sure you granted access to your Page."
                    else "Connected. Choose the Page to publish to."
                )
            }
        }
    }

    fun selectPage(pageId: String) = launchBusy { c.backend.selectPage(pageId); _messages.emit("Destination Page saved.") }
    fun refreshPages() = launchBusy { c.backend.refreshPages() }
    fun checkConnection() = launchBusy { c.backend.checkConnection(); _messages.emit("Connection checked.") }

    fun disconnect(revoke: Boolean) = launchBusy {
        runCatching { c.backend.disconnect(revoke) }
        facebookLogOut()
        c.auth.signOut()
        _messages.emit("Facebook disconnected.")
    }

    fun retry(jobId: String) = launchBusy {
        c.backend.retryJob(jobId)
        c.queue.watch(jobId)
        _messages.emit("Retrying…")
    }

    fun updateSettings(transform: (UserSettings) -> UserSettings) = viewModelScope.launch { c.settings.update(transform) }

    /** Saves a new outro picked by the user; keeps the old one if the new clip is unusable. */
    fun setOutro(uri: android.net.Uri) = launchBusy {
        try {
            val (saved, validation) = c.outros.set(uri)
            if (c.settings.current().outroEnabled.not()) c.settings.update { it.copy(outroEnabled = true) }
            val warning = validation.warnings.firstOrNull()?.message
            _messages.emit("Outro saved (${saved.metadata.durationMs / 1000.0}s).${warning?.let { " $it" } ?: ""}")
        } catch (e: InvalidOutroException) {
            _messages.emit(e.message ?: "That video can't be used as an outro.")
        } catch (e: DraftTooLargeException) {
            _messages.emit("The outro file is larger than 200 MB.")
        }
    }

    fun removeOutro() {
        c.outros.remove()
        updateSettings { it.copy(outroEnabled = false) }
        _messages.tryEmit("Outro removed.")
    }

    fun draftStorageBytes(): Long = c.drafts.totalBytes()
    /** Removes local copies older than a day (pending uploads are newer and are kept). */
    fun clearOldDrafts() { c.drafts.prune(keep = emptySet(), maxAgeMs = 24L * 3600 * 1000); _messages.tryEmit("Old local copies cleared.") }
    fun thumbnailFor(jobId: String): String? = c.drafts.thumbnailFor(jobId)

    companion object {
        val Factory: ViewModelProvider.Factory = viewModelFactory {
            initializer { AppViewModel((this[APPLICATION_KEY] as ReelBridgeApp).container) }
        }

        fun friendly(e: BackendException): String = when (e.code) {
            "UNAUTHENTICATED" -> "Please sign in again."
            "PERMISSION_DENIED" -> e.message ?: "Permission denied."
            "FAILED_PRECONDITION" -> e.message ?: "Facebook setup is incomplete."
            "UNAVAILABLE", "DEADLINE_EXCEEDED" -> "Network problem. Check your connection and try again."
            else -> e.message ?: "Something went wrong."
        }
    }
}
