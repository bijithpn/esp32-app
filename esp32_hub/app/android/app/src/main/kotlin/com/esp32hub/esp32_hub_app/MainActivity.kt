package com.esp32hub.esp32_hub_app

import android.content.Intent
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
                    else -> result.notImplemented()
                }
            }
    }
}
