package com.esp32hub.esp32_hub_app

import android.app.Notification
import android.content.ComponentName
import android.media.MediaMetadata
import android.media.session.MediaController
import android.media.session.MediaSessionManager
import android.media.session.PlaybackState
import android.content.Context
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
 *
 * Privacy: only the app name, a title (max 40 chars) and a text (max 120 chars) are sent, only to the board on the local
 * network. "hide content" sends just the app name. Apps can be blocked individually; the apps seen so far are listed in the
 * app so the user can pick them without the app needing the (sensitive) permission to list every installed package.
 */
class HubNotificationService : NotificationListenerService() {

    companion object {
        /** Latest song state, read by the app's Music screen (title, artist, playing, position, duration, app, artwork PNG). */
        @Volatile var nowPlaying: Map<String, Any?>? = null
    }

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

        // remember the app so the user can block it from the app (bounded list)
        rememberApp(p, n.packageName, app)
        val blocked = (p.getString("blocked", "") ?: "").split(',').filter { it.isNotEmpty() }
        if (blocked.contains(n.packageName)) return
        val hide = p.getBoolean("hide_content", false)

        val key = "${n.packageName}|$title|$text"
        val now = System.currentTimeMillis()
        if (key == lastNotifKey && now - lastNotifAt < 3000) return    // duplicate
        lastNotifKey = key; lastNotifAt = now

        HubSender.post(this, JSONObject()
            .put("cmd", "notify")
            .put("app", app.take(24))
            .put("title", if (hide) "" else title.take(40))
            .put("text", if (hide) "New notification" else text.take(120))
            .put("ttl", 6))
    }

    private fun rememberApp(p: android.content.SharedPreferences, pkg: String, label: String) {
        try {
            val seen = org.json.JSONObject(p.getString("seen", "{}") ?: "{}")
            if (seen.optString(pkg) == label) return
            seen.put(pkg, label)
            while (seen.length() > 40) seen.remove(seen.keys().next())    // bounded: forget the oldest
            p.edit().putString("seen", seen.toString()).apply()
        } catch (_: Exception) { }
    }

    // ------------------------------------------------------------------ now playing
    override fun onListenerConnected() {
        super.onListenerConnected()
        try {
            val m = getSystemService(MEDIA_SESSION_SERVICE) as MediaSessionManager
            sessions = m
            val comp = ComponentName(this, HubNotificationService::class.java)
            runCatching { m.removeOnActiveSessionsChangedListener(sessionsListener) }   // never register twice (a reconnect would duplicate every event)
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
        // the system dropped the listener (process trimmed, permission toggled): ask to be bound again
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.N) {
            try { requestRebind(ComponentName(this, HubNotificationService::class.java)) } catch (_: Exception) { }
        }
        super.onListenerDisconnected()
    }

    override fun onDestroy() {
        main.removeCallbacksAndMessages(null)
        runCatching { sessions?.removeOnActiveSessionsChangedListener(sessionsListener) }
        current?.unregisterCallback(controllerCallback)
        current = null
        super.onDestroy()
    }

    private fun attach(list: List<MediaController>?) {
        current?.unregisterCallback(controllerCallback)
        current = list?.firstOrNull { it.playbackState?.state == PlaybackState.STATE_PLAYING } ?: list?.firstOrNull()
        current?.registerCallback(controllerCallback)
        if (current == null) pushStopped() else pushNowPlaying(force = true)
    }

    /** The music app closed: tell the board so it can go back to what it was showing. */
    private fun pushStopped() {
        nowPlaying = null
        if (!prefs().getBoolean("media", false) || lastKey.isEmpty()) return
        lastKey = ""
        HubSender.post(this, JSONObject()
            .put("cmd", "nowplaying")
            .put("title", lastTitle)
            .put("artist", "")
            .put("playing", false)
            .put("quiet", true))
    }

    /** Keeps the newest song state (with a small cover image when the music app provides one) for the app's Music screen. */
    private fun publishSnapshot(c: MediaController, m: MediaMetadata, title: String, artist: String, playing: Boolean, dur: Int, pos: Int) {
        var art: ByteArray? = null
        try {
            val bmp = m.getBitmap(MediaMetadata.METADATA_KEY_ALBUM_ART) ?: m.getBitmap(MediaMetadata.METADATA_KEY_ART)
            if (bmp != null) {
                val small = android.graphics.Bitmap.createScaledBitmap(bmp, 160, 160, true)
                val out = java.io.ByteArrayOutputStream()
                small.compress(android.graphics.Bitmap.CompressFormat.JPEG, 80, out)
                art = out.toByteArray()
            }
        } catch (_: Exception) { }
        val app = try {
            packageManager.getApplicationLabel(packageManager.getApplicationInfo(c.packageName, 0)).toString()
        } catch (_: Exception) { c.packageName ?: "" }
        nowPlaying = mapOf("title" to title, "artist" to artist, "playing" to playing, "dur" to dur, "pos" to pos, "app" to app, "art" to art, "at" to System.currentTimeMillis())
    }

    private fun pushNowPlaying(force: Boolean) {
        val c = current ?: return
        val m = c.metadata ?: return
        val mediaOn = prefs().getBoolean("media", false)
        val title = m.getString(MediaMetadata.METADATA_KEY_TITLE) ?: return
        val artist = m.getString(MediaMetadata.METADATA_KEY_ARTIST)
            ?: m.getString(MediaMetadata.METADATA_KEY_ALBUM_ARTIST) ?: ""
        val state = c.playbackState
        val playing = state?.state == PlaybackState.STATE_PLAYING
        val dur = (m.getLong(MediaMetadata.METADATA_KEY_DURATION) / 1000).toInt().coerceAtLeast(0)
        val pos = ((state?.position ?: 0L) / 1000).toInt().coerceAtLeast(0)

        publishSnapshot(c, m, title, artist, playing, dur, pos)
        if (!mediaOn) return

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
