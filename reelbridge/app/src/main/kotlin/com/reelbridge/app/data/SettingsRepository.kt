package com.reelbridge.app.data

import android.content.Context
import androidx.datastore.preferences.core.booleanPreferencesKey
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import com.reelbridge.app.data.model.UserSettings
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map

private val Context.dataStore by preferencesDataStore(name = "settings")

/** Local preferences (DataStore). Also mirrored to users/{uid} so the backend can read them. */
class SettingsRepository(private val context: Context, private val remoteSync: suspend (UserSettings) -> Unit) {
    private object Keys {
        val AUTO = booleanPreferencesKey("auto_publish")
        val TEMPLATE = stringPreferencesKey("caption_template")
        val HASHTAGS = stringPreferencesKey("default_hashtags")
        val NOTIFY = booleanPreferencesKey("notifications")
        val OUTRO = booleanPreferencesKey("outro_enabled")
    }

    val settings: Flow<UserSettings> = context.dataStore.data.map { p ->
        UserSettings(
            autoPublish = p[Keys.AUTO] ?: false,
            captionTemplate = p[Keys.TEMPLATE] ?: "{caption}",
            defaultHashtags = p[Keys.HASHTAGS] ?: "",
            notifications = p[Keys.NOTIFY] ?: true,
            outroEnabled = p[Keys.OUTRO] ?: false,
        )
    }

    suspend fun current(): UserSettings = settings.first()

    suspend fun update(transform: (UserSettings) -> UserSettings) {
        val next = transform(current())
        context.dataStore.edit { p ->
            p[Keys.AUTO] = next.autoPublish
            p[Keys.TEMPLATE] = next.captionTemplate
            p[Keys.HASHTAGS] = next.defaultHashtags
            p[Keys.NOTIFY] = next.notifications
            p[Keys.OUTRO] = next.outroEnabled
        }
        runCatching { remoteSync(next) }
    }
}
