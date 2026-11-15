package com.esp32hub.esp32_hub_app

import android.app.Notification
import android.content.ComponentName
import android.media.MediaMetadata
import android.media.session.MediaController
import android.media.session.MediaSessionManager
import android.media.session.PlaybackState
import android.os.Handler
import android.os.Looper
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import org.json.JSONObject

/**
 * Needs "Notification access" (granted by the user in Android settings).
 *  - Mirrors new notifications to the display ("notify" command).
 *  - Follows the active media session and sends "now playing" (title, artist, position).
 * Both features are switched on/off from the Flutter app (Phone sync screen).
 */
class HubNotificationService : NotificationListenerService() {

    private var sessions: MediaSessionManager? = null
    private var current: MediaController? = null
    private val main = Handler(Looper.getMainLooper())
    private var lastKey = ""
    private var lastTitle = ""
    private var lastSent = 0L
    private var lastNotifKey = ""
    private var lastNotifAt = 0L

    private val sessionsListener =
        MediaSessionManager.OnActiveSessionsChangedListener { list -> attach(list) }

    private val controllerCallback = object : MediaController.Callback() {
        override fun onMetadataChanged(metadata: MediaMetadata?) = pushNowPlaying(force = true)
        override fun onPlaybackStateChanged(state: PlaybackState?) = pushNowPlaying(force = true)
    }

    private val ticker = object : Runnable {
        override fun run() {
            pushNowPlaying(force = false)          // periodic position sync while playing
            main.postDelayed(this, 10_000)
        }
    }

    private fun prefs() = HubSender.prefs(this)

    // ------------------------------------------------------------------ notifications
    override fun onNotificationPosted(sbn: StatusBarNotification?) {
        val n = sbn ?: return
        val p = prefs()
        if (!p.getBoolean("mirror", false)) return
        if (n.packageName == packageName) return
        val notif = n.notification ?: return
        if (notif.flags and Notification.FLAG_ONGOING_EVENT != 0) return
        if (notif.flags and Notification.FLAG_GROUP_SUMMARY != 0) return
        if (notif.category == Notification.CATEGORY_TRANSPORT || notif.category == Notification.CATEGORY_PROGRESS) return

        val extras = notif.extras
        val title = extras.getCharSequence(Notification.EXTRA_TITLE)?.toString() ?: ""
        val text = (extras.getCharSequence(Notification.EXTRA_BIG_TEXT)
            ?: extras.getCharSequence(Notification.EXTRA_TEXT))?.toString() ?: ""
        if (title.isEmpty() && text.isEmpty()) return

        val app = try {
            packageManager.getApplicationLabel(packageManager.getApplicationInfo(n.packageName, 0)).toString()
        } catch (_: Exception) {
            n.packageName
        }

        // comma-separated words; an app whose name contains one of them is ignored
        val ignore = (p.getString("ignore", "") ?: "").split(',').map { it.trim().lowercase() }.filter { it.isNotEmpty() }
        if (ignore.any { app.lowercase().contains(it) || n.packageName.lowercase().contains(it) }) return

        val key = "${n.packageName}|$title|$text"
        val now = System.currentTimeMillis()
        if (key == lastNotifKey && now - lastNotifAt < 3000) return    // duplicate
        lastNotifKey = key; lastNotifAt = now

        HubSender.post(this, JSONObject()
            .put("cmd", "notify")
            .put("app", app)
            .put("title", title)
            .put("text", text)
            .put("ttl", 6))
    }

    // ------------------------------------------------------------------ now playing
    override fun onListenerConnected() {
        super.onListenerConnected()
        try {
            val m = getSystemService(MEDIA_SESSION_SERVICE) as MediaSessionManager
            sessions = m
            val comp = ComponentName(this, HubNotificationService::class.java)
            m.addOnActiveSessionsChangedListener(sessionsListener, comp)
            attach(m.getActiveSessions(comp))
        } catch (_: SecurityException) {
            // access not granted (yet)
        }
        main.removeCallbacks(ticker)
        main.postDelayed(ticker, 10_000)
    }

    override fun onListenerDisconnected() {
        main.removeCallbacks(ticker)
        try { sessions?.removeOnActiveSessionsChangedListener(sessionsListener) } catch (_: Exception) {}
        current?.unregisterCallback(controllerCallback)
        current = null
        super.onListenerDisconnected()
    }

    private fun attach(list: List<MediaController>?) {
        current?.unregisterCallback(controllerCallback)
        current = list?.firstOrNull { it.playbackState?.state == PlaybackState.STATE_PLAYING } ?: list?.firstOrNull()
        current?.registerCallback(controllerCallback)
        if (current == null) pushStopped() else pushNowPlaying(force = true)
    }

    /** The music app closed: tell the board so it can go back to what it was showing. */
    private fun pushStopped() {
        if (!prefs().getBoolean("media", false) || lastKey.isEmpty()) return
        lastKey = ""
        HubSender.post(this, JSONObject()
            .put("cmd", "nowplaying")
            .put("title", lastTitle)
            .put("artist", "")
            .put("playing", false)
            .put("quiet", true))
    }

    private fun pushNowPlaying(force: Boolean) {
        if (!prefs().getBoolean("media", false)) return
        val c = current ?: return
        val m = c.metadata ?: return
        val title = m.getString(MediaMetadata.METADATA_KEY_TITLE) ?: return
        val artist = m.getString(MediaMetadata.METADATA_KEY_ARTIST)
            ?: m.getString(MediaMetadata.METADATA_KEY_ALBUM_ARTIST) ?: ""
        val state = c.playbackState
        val playing = state?.state == PlaybackState.STATE_PLAYING
        val dur = (m.getLong(MediaMetadata.METADATA_KEY_DURATION) / 1000).toInt().coerceAtLeast(0)
        val pos = ((state?.position ?: 0L) / 1000).toInt().coerceAtLeast(0)

        val key = "$title|$artist|$playing"
        val now = System.currentTimeMillis()
        val changed = key != lastKey
        if (!changed && !playing) return                     // nothing new while paused
        if (!force && now - lastSent < 8000) return
        lastKey = key; lastSent = now; lastTitle = title

        HubSender.post(this, JSONObject()
            .put("cmd", "nowplaying")
            .put("title", title)
            .put("artist", artist)
            .put("dur", dur)
            .put("pos", pos)
            .put("playing", playing)
            .put("quiet", !changed))       // a new track / play-pause switches the display, position sync does not
    }
}
