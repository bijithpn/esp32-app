package com.esp32hub.esp32_hub_app

import android.content.Context
import android.content.SharedPreferences
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.Executors

/**
 * Sends commands to the ESP32 Hub over local HTTP, from native code, so notification mirroring and
 * "now playing" keep working when the Flutter UI is closed. The address and token are saved by
 * the Flutter app through the "esp32hub/bridge" method channel.
 */
object HubSender {
    private val executor = Executors.newSingleThreadExecutor()

    fun prefs(ctx: Context): SharedPreferences =
        ctx.getSharedPreferences("hub_bridge", Context.MODE_PRIVATE)

    fun post(ctx: Context, body: JSONObject) {
        val p = prefs(ctx)
        val host = p.getString("host", "") ?: ""
        if (host.isEmpty()) return
        val token = p.getString("token", "") ?: ""
        executor.execute {
            try {
                val c = URL("http://$host/api/cmd").openConnection() as HttpURLConnection
                c.requestMethod = "POST"
                c.connectTimeout = 3000
                c.readTimeout = 4000
                c.doOutput = true
                c.setRequestProperty("Content-Type", "application/json")
                if (token.isNotEmpty()) c.setRequestProperty("X-Hub-Token", token)
                c.outputStream.use { it.write(body.toString().toByteArray(Charsets.UTF_8)) }
                c.responseCode            // wait for the reply so the connection is closed cleanly
                c.disconnect()
            } catch (_: Exception) {
                // board unreachable (different network / off): ignore
            }
        }
    }
}
