package com.esp32hub.esp32_hub_app

import android.content.Context
import android.content.SharedPreferences
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.InetSocketAddress
import java.net.NetworkInterface
import java.net.Socket
import java.net.URL
import java.util.concurrent.Callable
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Sends commands to the ESP32 Hub over local HTTP, from native code, so notification mirroring and
 * "now playing" keep working when the Flutter UI is closed. The address and token are saved by
 * the Flutter app through the "esp32hub/bridge" method channel.
 *
 * If the board cannot be reached (new IP after a router restart), it is searched for on the local network by
 * its id and the saved address is updated, so everything keeps working without opening the app.
 */
object HubSender {
    private val executor = Executors.newSingleThreadExecutor()
    private val finder = Executors.newSingleThreadExecutor()
    private val finding = AtomicBoolean(false)
    @Volatile private var failures = 0
    @Volatile private var lastFind = 0L

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
                failures = 0
            } catch (_: Exception) {
                // board unreachable (different network / off / new address)
                if (++failures >= 2) rediscover(ctx)
            }
        }
    }

    /** Looks for the board (by id) on every /24 network of this phone and saves its new address. */
    private fun rediscover(ctx: Context) {
        val now = System.currentTimeMillis()
        if (now - lastFind < 60_000 || !finding.compareAndSet(false, true)) return
        lastFind = now
        finder.execute {
            try {
                val p = prefs(ctx)
                val id = p.getString("id", "") ?: ""
                val prefixes = NetworkInterface.getNetworkInterfaces().toList()
                    .flatMap { it.inetAddresses.toList() }
                    .filter { !it.isLoopbackAddress && it.address.size == 4 }
                    .map { a -> a.address.take(3).joinToString(".") { (it.toInt() and 0xFF).toString() } }
                    .filter { !it.startsWith("169.254") }
                    .distinct()
                for (pre in prefixes) {
                    val pool = Executors.newFixedThreadPool(32)
                    val found = (1..254).map { i ->
                        pool.submit(Callable<String?> {
                            val h = "$pre.$i"
                            try {
                                Socket().use { s -> s.connect(InetSocketAddress(h, 80), 400) }
                                val c = URL("http://$h/api/hello").openConnection() as HttpURLConnection
                                c.connectTimeout = 800; c.readTimeout = 1200
                                val txt = c.inputStream.bufferedReader().readText()
                                c.disconnect()
                                val j = JSONObject(txt)
                                if (j.optString("device") == "ESP32-Hub" && !j.optBoolean("ap") && (id.isEmpty() || j.optString("id") == id)) h else null
                            } catch (_: Exception) { null }
                        })
                    }.mapNotNull { it.get() }
                    pool.shutdown()
                    if (found.isNotEmpty()) {
                        p.edit().putString("host", found[0]).apply()
                        failures = 0
                        return@execute
                    }
                }
            } catch (_: Exception) {
            } finally {
                finding.set(false)
            }
        }
    }
}
