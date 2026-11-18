package com.reelbridge.app.facebook

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import com.facebook.CallbackManager
import com.facebook.FacebookCallback
import com.facebook.FacebookException
import com.facebook.login.LoginManager
import com.facebook.login.LoginResult

/**
 * Meta's supported Facebook Login flow (Facebook SDK for Android).
 *
 * Permissions requested (see docs/META_SETUP.md for the App Review justification):
 *  - pages_show_list       list the Pages the person manages
 *  - pages_read_engagement read Page metadata / linked Instagram account (required with manage_posts)
 *  - pages_manage_posts    publish Reels to the Page
 *  - instagram_basic       OPTIONAL: read the person's OWN Instagram professional account media,
 *                          so sharing an Instagram link to one of their own Reels can be resolved
 *                          without downloading anything from instagram.com.
 *  - business_management   needed when the Page is owned through a Business portfolio.
 */
object FacebookPermissions {
    val REQUIRED = listOf("public_profile", "pages_show_list", "pages_read_engagement", "pages_manage_posts")
    val OPTIONAL = listOf("instagram_basic", "business_management")
    val ALL = REQUIRED + OPTIONAL
}

sealed interface FacebookLoginOutcome {
    data class Success(val accessToken: String, val declined: Set<String>) : FacebookLoginOutcome
    data object Cancelled : FacebookLoginOutcome
    data class Error(val message: String) : FacebookLoginOutcome
}

/** Returns a function that launches Facebook Login and reports the outcome to [onResult]. */
@Composable
fun rememberFacebookLogin(onResult: (FacebookLoginOutcome) -> Unit): () -> Unit {
    val callback = rememberUpdatedState(onResult)
    val callbackManager = remember { CallbackManager.Factory.create() }
    val loginManager = remember { LoginManager.getInstance() }

    DisposableEffect(callbackManager) {
        loginManager.registerCallback(callbackManager, object : FacebookCallback<LoginResult> {
            override fun onSuccess(result: LoginResult) {
                callback.value(FacebookLoginOutcome.Success(result.accessToken.token, result.recentlyDeniedPermissions))
            }
            override fun onCancel() = callback.value(FacebookLoginOutcome.Cancelled)
            override fun onError(error: FacebookException) =
                callback.value(FacebookLoginOutcome.Error(error.message ?: "Facebook Login failed"))
        })
        onDispose { loginManager.unregisterCallback(callbackManager) }
    }

    val launcher = rememberLauncherForActivityResult(
        loginManager.createLogInActivityResultContract(callbackManager, null)
    ) { /* delivered through the registered callback */ }

    return { launcher.launch(FacebookPermissions.ALL) }
}

fun facebookLogOut() = runCatching { LoginManager.getInstance().logOut() }
