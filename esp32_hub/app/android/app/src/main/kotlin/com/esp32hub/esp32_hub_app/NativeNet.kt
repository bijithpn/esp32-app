package com.esp32hub.esp32_hub_app

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import org.json.JSONObject
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.HttpURLConnection
import java.net.InetAddress
import java.net.SocketTimeoutException
import java.net.URL
import java.net.ConnectException
import java.net.NoRouteToHostException
import java.net.UnknownHostException
import java.util.concurrent.Callable
import java.util.concurrent.Executors

/**
 * Local-network I/O for the ESP32 Hub, always sent through the phone's Wi-Fi Network object.
 *
 * Why: a Wi-Fi without internet (the board's setup hotspot, or a router whose uplink is down) is not Android's default
 * network while mobile data is on, so plain sockets would leave over the cellular link and never reach 192.168.x.x.
 * Instead of pinning the whole app process to the hotspot (which breaks every other request the app makes), every call to
 * the board goes through Network.openConnection / Network.bindSocket for the right Network. Nothing is bound process-wide.
 */
object NativeNet {
    /** Set while a provisioning session holds the board's hotspot (joined with WifiNetworkSpecifier). */
    @Volatile var hotspot: Network? = null

    private val pool = Executors.newFixedThreadPool(48)

    fun cm(ctx: Context) = ctx.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager

    /** The network to use for the board: the hotspot session, else the Wi-Fi, else null (default routing). */
    @Suppress("DEPRECATION")
    fun lan(ctx: Context): Network? {
        hotspot?.let { return it }
        val c = cm(ctx)
        for (n in c.allNetworks) {
            val caps = c.getNetworkCapabilities(n) ?: continue
            if (caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)) return n
        }
        return null
    }

    /** /24 prefixes ("192.168.1") of the Wi-Fi network (or of the hotspot session). */
    fun prefixes(ctx: Context): List<String> {
        val c = cm(ctx)
        val n = lan(ctx) ?: return emptyList()
        val lp = c.getLinkProperties(n) ?: return emptyList()
        return lp.linkAddresses.mapNotNull { it.address.hostAddress }
            .filter { it.count { ch -> ch == '.' } == 3 && !it.startsWith("169.254") }
            .map { it.substringBeforeLast('.') }.distinct()
    }

    fun snapshot(ctx: Context): Map<String, Any?> {
        val c = cm(ctx)
        var wifi = false; var cell = false; var validated = false
        @Suppress("DEPRECATION")
        for (n in c.allNetworks) {
            val caps = c.getNetworkCapabilities(n) ?: continue
            if (caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)) { wifi = true; validated = caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED) }
            if (caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR)) cell = true
        }
        val p = prefixes(ctx)
        return mapOf("wifi" to wifi, "cellular" to cell, "validated" to validated, "hotspot" to (hotspot != null), "prefixes" to p)
    }

    private fun classify(e: Exception): String = when (e) {
        is SocketTimeoutException -> "timeout"
        is ConnectException -> "refused"
        is NoRouteToHostException -> "unreachable"
        is UnknownHostException -> "dns"
        else -> "io"
    }

    /** One HTTP request. Returns {status, body, ms} or {error, message}. */
    fun http(ctx: Context, method: String, url: String, headers: Map<String, String>, body: String?, timeoutMs: Int): Map<String, Any?> {
        val t0 = System.currentTimeMillis()
        return try {
            val net = lan(ctx)
            val u = URL(url)
            val conn = (if (net != null) net.openConnection(u) else u.openConnection()) as HttpURLConnection
            conn.requestMethod = method
            conn.connectTimeout = minOf(timeoutMs, 4000)
            conn.readTimeout = timeoutMs
            conn.useCaches = false
            headers.forEach { (k, v) -> conn.setRequestProperty(k, v) }
            if (body != null) {
                conn.doOutput = true
                conn.outputStream.use { it.write(body.toByteArray(Charsets.UTF_8)) }
            }
            val code = conn.responseCode
            val stream = if (code >= 400) conn.errorStream else conn.inputStream
            val text = stream?.bufferedReader(Charsets.UTF_8)?.use { it.readText() } ?: ""
            conn.disconnect()
            mapOf("status" to code, "body" to text, "ms" to (System.currentTimeMillis() - t0))
        } catch (e: Exception) {
            mapOf("error" to classify(e), "message" to (e.message ?: e.javaClass.simpleName), "ms" to (System.currentTimeMillis() - t0))
        }
    }

    /** Asks every host in [hosts] for [path]; returns {host, body} for each one that answered with 200. */
    fun sweep(ctx: Context, hosts: List<String>, path: String, timeoutMs: Int): List<Map<String, String>> {
        val net = lan(ctx)
        val jobs = hosts.map { h ->
            pool.submit(Callable<Map<String, String>?> {
                try {
                    val u = URL("http://$h$path")
                    val conn = (if (net != null) net.openConnection(u) else u.openConnection()) as HttpURLConnection
                    conn.connectTimeout = timeoutMs; conn.readTimeout = timeoutMs; conn.useCaches = false
                    val ok = conn.responseCode == 200
                    val txt = if (ok) conn.inputStream.bufferedReader().use { it.readText() } else ""
                    conn.disconnect()
                    if (ok) mapOf("host" to h, "body" to txt) else null
                } catch (_: Exception) { null }
            })
        }
        return jobs.mapNotNull { runCatching { it.get() }.getOrNull() }
    }

    /** UDP discovery: broadcasts the request and collects every answer for [timeoutMs] (stops early shortly after the first). */
    fun udp(ctx: Context, port: Int, magic: String, timeoutMs: Int): List<Map<String, String>> {
        val out = LinkedHashMap<String, String>()
        var sock: DatagramSocket? = null
        try {
            sock = DatagramSocket(null).apply { reuseAddress = true; broadcast = true; bind(java.net.InetSocketAddress(0)) }
            lan(ctx)?.bindSocket(sock)
            val data = magic.toByteArray()
            val targets = mutableListOf("255.255.255.255")
            prefixes(ctx).forEach { targets.add("$it.255") }
            for (t in targets) runCatching { sock.send(DatagramPacket(data, data.size, InetAddress.getByName(t), port)) }
            val end = System.currentTimeMillis() + timeoutMs
            var firstAt = 0L
            val buf = ByteArray(1024)
            while (true) {
                val left = end - System.currentTimeMillis()
                if (left <= 0) break
                if (firstAt != 0L && System.currentTimeMillis() - firstAt > 350) break
                sock.soTimeout = minOf(left, 250L).toInt()
                try {
                    val p = DatagramPacket(buf, buf.size)
                    sock.receive(p)
                    val ip = p.address.hostAddress ?: continue
                    if (!out.containsKey(ip)) { out[ip] = String(p.data, 0, p.length, Charsets.UTF_8); if (firstAt == 0L) firstAt = System.currentTimeMillis() }
                } catch (_: SocketTimeoutException) { }
            }
        } catch (_: Exception) {
        } finally {
            runCatching { sock?.close() }
        }
        return out.map { mapOf("host" to it.key, "body" to it.value) }
    }

    fun json(s: String): JSONObject? = try { JSONObject(s) } catch (_: Exception) { null }
}
