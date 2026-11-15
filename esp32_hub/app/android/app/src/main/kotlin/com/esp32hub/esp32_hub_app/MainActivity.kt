package com.esp32hub.esp32_hub_app

import android.annotation.SuppressLint
import android.content.Intent
import android.location.LocationManager
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "esp32hub/bridge")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    // Is "Notification access" granted to this app?
                    "isGranted" -> {
                        val enabled = Settings.Secure.getString(contentResolver, "enabled_notification_listeners") ?: ""
                        result.success(enabled.contains(packageName))
                    }
                    "openSettings" -> {
                        startActivity(Intent("android.settings.ACTION_NOTIFICATION_LISTENER_SETTINGS")
                            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                        result.success(null)
                    }
                    // host, token, mirror, media, ignore
                    "setConfig" -> {
                        HubSender.prefs(this).edit()
                            .putString("host", call.argument<String>("host") ?: "")
                            .putString("token", call.argument<String>("token") ?: "")
                            .putBoolean("mirror", call.argument<Boolean>("mirror") ?: false)
                            .putBoolean("media", call.argument<Boolean>("media") ?: false)
                            .putString("ignore", call.argument<String>("ignore") ?: "")
                            .putString("id", call.argument<String>("id") ?: "")
                            .apply()
                        result.success(true)
                    }
                    "getConfig" -> {
                        val p = HubSender.prefs(this)
                        result.success(mapOf(
                            "host" to (p.getString("host", "") ?: ""),
                            "token" to (p.getString("token", "") ?: ""),
                            "mirror" to p.getBoolean("mirror", false),
                            "media" to p.getBoolean("media", false),
                            "ignore" to (p.getString("ignore", "") ?: "")
                        ))
                    }
                    // Last known position (needs the location permission, asked by the Flutter side). Used for the weather.
                    "getLocation" -> result.success(lastLocation())
                    else -> result.notImplemented()
                }
            }
    }

    @SuppressLint("MissingPermission")
    private fun lastLocation(): Map<String, Double>? {
        return try {
            val lm = getSystemService(LOCATION_SERVICE) as LocationManager
            val best = lm.getProviders(true)
                .mapNotNull { runCatching { lm.getLastKnownLocation(it) }.getOrNull() }
                .maxByOrNull { it.time }
            if (best == null) null else mapOf("lat" to best.latitude, "lon" to best.longitude)
        } catch (_: SecurityException) {
            null
        }
    }
}
