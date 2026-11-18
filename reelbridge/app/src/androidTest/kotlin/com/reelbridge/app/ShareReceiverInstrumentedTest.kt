package com.reelbridge.app

import android.Manifest
import android.content.Intent
import android.net.Uri
import android.os.Build
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.assertIsDisplayed
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.rule.GrantPermissionRule
import com.reelbridge.app.share.ShareReceiverActivity
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/**
 * End-to-end on a device: Android's share intents → ShareReceiverActivity → what the user sees.
 * CI builds have no Firebase project, so steps that need the backend must show "Setup required"
 * (never a fake success).
 */
@RunWith(AndroidJUnit4::class)
class ShareReceiverInstrumentedTest {
    @get:Rule val compose = createEmptyComposeRule()

    @get:Rule val notifications: GrantPermissionRule =
        if (Build.VERSION.SDK_INT >= 33) GrantPermissionRule.grant(Manifest.permission.POST_NOTIFICATIONS) else GrantPermissionRule.grant()

    private val context = InstrumentationRegistry.getInstrumentation().targetContext

    private fun share(build: Intent.() -> Unit): ActivityScenario<ShareReceiverActivity> =
        ActivityScenario.launch(Intent(context, ShareReceiverActivity::class.java).apply(build))

    private fun awaitText(text: String, substring: Boolean = false) {
        compose.waitUntil(10_000) { compose.onAllNodesWithText(text, substring = substring).fetchSemanticsNodes().isNotEmpty() }
        compose.onNodeWithText(text, substring = substring).assertIsDisplayed()
    }

    @Test fun plainTextWithoutLinkExplainsTheProblem() {
        share { action = Intent.ACTION_SEND; type = "text/plain"; putExtra(Intent.EXTRA_TEXT, "just some words") }.use {
            awaitText("Can't use this share")
            awaitText("does not contain a video or an Instagram link", substring = true)
        }
    }

    @Test fun nonInstagramLinkIsRefused() {
        share { action = Intent.ACTION_SEND; type = "text/plain"; putExtra(Intent.EXTRA_TEXT, "https://example.com/watch?v=1") }.use {
            awaitText("That's a web link, not a video")
        }
    }

    @Test fun instagramStoryIsRefused() {
        share { action = Intent.ACTION_SEND; type = "text/plain"; putExtra(Intent.EXTRA_TEXT, "https://www.instagram.com/stories/someone/123/") }.use {
            awaitText("Instagram Stories cannot be published", substring = true)
        }
    }

    @Test fun imageIsRefused() {
        share {
            action = Intent.ACTION_SEND; type = "image/png"
            putExtra(Intent.EXTRA_STREAM, Uri.parse("content://com.reelbridge.test.none/image.png"))
        }.use { awaitText("can only publish videos", substring = true) }
    }

    @Test fun instagramReelLinkRequiresSetupOrConnection() {
        share { action = Intent.ACTION_SEND; type = "text/plain"; putExtra(Intent.EXTRA_TEXT, "https://www.instagram.com/reel/C9xYz_1-AbC/?igsh=x") }.use {
            awaitText(if (BuildConfig.FIREBASE_CONFIGURED) "Connect Facebook first" else "Setup required")
        }
    }

    @Test fun sharedVideoRequiresSetupOrConnection() {
        share {
            action = Intent.ACTION_SEND; type = "video/mp4"
            putExtra(Intent.EXTRA_STREAM, Uri.parse("content://com.reelbridge.test.none/video.mp4"))
        }.use { awaitText(if (BuildConfig.FIREBASE_CONFIGURED) "Connect Facebook first" else "Setup required") }
    }

    @Test fun mainScreenOpens() {
        ActivityScenario.launch(MainActivity::class.java).use {
            if (BuildConfig.FIREBASE_CONFIGURED) awaitText("ReelBridge") else awaitText("Setup required")
        }
    }
}
