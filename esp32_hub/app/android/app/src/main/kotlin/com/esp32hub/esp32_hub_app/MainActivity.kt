package com.esp32hub.esp32_hub_app

import android.annotation.SuppressLint
import android.content.Context
import android.content.Intent
import android.location.LocationManager
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiManager
import android.net.wifi.WifiNetworkSpecifier
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/**
 * Platform bridge for the app. Nothing here binds the process to a network: traffic to the board goes through
 * [NativeNet] (Network.openConnection / bindSocket), so the phone keeps normal routing for everything else.
 */
class MainActivity : FlutterActivity() {
    private val io = Executors.newCachedThreadPool()
    private var monitor: NetworkMonitor? = null
    private var joinCallback: ConnectivityManager.NetworkCallback? = null
    private var multicastLock: WifiManager.MulticastLock? = null

    private fun reply(result: MethodChannel.Result, value: Any?) = runOnUiThread { result.success(value) }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val mon = NetworkMonitor(this)
        monitor = mon
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, "esp32hub/network").setStreamHandler(mon)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "esp32hub/bridge").setMethodCallHandler { call, result ->
            when (call.method) {
                // ---- permissions / settings
                "isGranted" -> {
                    val enabled = Settings.Secure.getString(contentResolver, "enabled_notification_listeners") ?: ""
                    result.success(enabled.contains(packageName))
                }
                "openSettings" -> {
                    startActivity(Intent("android.settings.ACTION_NOTIFICATION_LISTENER_SETTINGS").addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                    result.success(null)
                }
                "batteryStatus" -> {
                    val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
                    result.success(mapOf("ignoringOptimizations" to pm.isIgnoringBatteryOptimizations(packageName), "sdk" to Build.VERSION.SDK_INT))
                }
                "openBatterySettings" -> {
                    startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                    result.success(null)
                }

                // ---- network (all of it bound to the Wi-Fi Network, never to the process)
                "net.snapshot" -> result.success(NativeNet.snapshot(this))
                "net.http" -> {
                    val a = call.arguments as Map<*, *>
                    io.execute {
                        val headers = (a["headers"] as? Map<*, *>)?.entries?.associate { "${it.key}" to "${it.value}" } ?: emptyMap()
                        reply(result, NativeNet.http(this, "${a["method"] ?: "GET"}", "${a["url"]}", headers, a["body"] as? String, (a["timeoutMs"] as? Int) ?: 6000))
                    }
                }
                "net.sweep" -> {
                    val hosts = (call.argument<List<String>>("hosts") ?: emptyList())
                    io.execute { reply(result, NativeNet.sweep(this, hosts, call.argument<String>("path") ?: "/api/hello", call.argument<Int>("timeoutMs") ?: 700)) }
                }
                "net.udp" -> io.execute {
                    reply(result, NativeNet.udp(this, call.argument<Int>("port") ?: 41234, call.argument<String>("magic") ?: "ESP32_HUB_DISCOVER_V1", call.argument<Int>("timeoutMs") ?: 1200))
                }
                "net.mdns" -> mdnsFind(call.argument<Int>("timeoutMs") ?: 2500, result)
                "wifi.join" -> joinWifi(call.argument<String>("ssid") ?: "", call.argument<String>("pass") ?: "", result)
                "wifi.leave" -> {
                    leaveHotspot()
                    result.success(null)
                }

                // ---- secure storage (Android Keystore, AES-GCM)
                "secure.get" -> io.execute { reply(result, SecureStore.get(this, call.argument<String>("name") ?: "")) }
                "secure.set" -> io.execute {
                    SecureStore.put(this, call.argument<String>("name") ?: "", call.argument<String>("value"))
                    reply(result, true)
                }
                "secure.delete" -> io.execute { SecureStore.remove(this, call.argument<String>("name") ?: ""); reply(result, true) }

                // ---- background sync configuration (read by HubNotificationService / HubSender)
                "setConfig" -> {
                    val e = HubSender.prefs(this).edit()
                    call.argument<String>("host")?.let { e.putString("host", it) }
                    call.argument<String>("id")?.let { e.putString("id", it) }
                    call.argument<Boolean>("mirror")?.let { e.putBoolean("mirror", it) }
                    call.argument<Boolean>("media")?.let { e.putBoolean("media", it) }
                    call.argument<String>("ignore")?.let { e.putString("ignore", it) }
                    call.argument<Boolean>("hideContent")?.let { e.putBoolean("hide_content", it) }
                    call.argument<String>("blocked")?.let { e.putString("blocked", it) }
                    e.apply()
                    call.argument<String>("token")?.let { t -> io.execute { SecureStore.put(this, "bridge_token", t); reply(result, true) } } ?: result.success(true)
                }
                "getConfig" -> {
                    val p = HubSender.prefs(this)
                    result.success(mapOf(
                        "host" to (p.getString("host", "") ?: ""),
                        "mirror" to p.getBoolean("mirror", false),
                        "media" to p.getBoolean("media", false),
                        "ignore" to (p.getString("ignore", "") ?: ""),
                        "hideContent" to p.getBoolean("hide_content", false),
                        "blocked" to (p.getString("blocked", "") ?: ""),
                        "seen" to (p.getString("seen", "{}") ?: "{}"),
                        "lastDelivery" to (p.getString("last_delivery", "") ?: "")
                    ))
                }
                "media.now" -> {
                    val n = HubNotificationService.nowPlaying
                    result.success(if (n == null || System.currentTimeMillis() - ((n["at"] as? Long) ?: 0L) > 120_000L) null else n)
                }
                "getLocation" -> result.success(lastLocation())
                else -> result.notImplemented()
            }
        }
    }

    override fun onDestroy() {
        leaveHotspot()
        runCatching { multicastLock?.release() }
        super.onDestroy()
    }

    // ------------------------------------------------------------------ hotspot (WifiNetworkSpecifier)
    private fun leaveHotspot() {
        val cm = NativeNet.cm(this)
        joinCallback?.let { runCatching { cm.unregisterNetworkCallback(it) } }
        joinCallback = null
        NativeNet.hotspot = null
    }

    /**
     * Joins the board's hotspot (Android 10+ shows its own approval dialog once). Replies {ok, code}:
     * ok | unsupported | unavailable (the user said no, the dialog timed out, or the hotspot is not in range) | error.
     * The joined Network is kept for [NativeNet] only; the process is NOT bound to it, so mobile data and the home
     * Wi-Fi keep working for everything else. It is released when [leaveHotspot] runs.
     */
    private fun joinWifi(ssid: String, pass: String, result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) { result.success(mapOf("ok" to false, "code" to "unsupported")); return }
        if (ssid.isEmpty()) { result.success(mapOf("ok" to false, "code" to "error")); return }
        try {
            leaveHotspot()
            val cm = NativeNet.cm(this)
            val spec = WifiNetworkSpecifier.Builder().setSsid(ssid).apply { if (pass.isNotEmpty()) setWpa2Passphrase(pass) }.build()
            val req = NetworkRequest.Builder()
                .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
                .removeCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
                .setNetworkSpecifier(spec)
                .build()
            var replied = false
            val cb = object : ConnectivityManager.NetworkCallback() {
                override fun onAvailable(network: Network) {
                    NativeNet.hotspot = network
                    if (!replied) { replied = true; reply(result, mapOf("ok" to true, "code" to "ok")) }
                }
                override fun onUnavailable() {
                    if (!replied) { replied = true; reply(result, mapOf("ok" to false, "code" to "unavailable")) }
                }
                override fun onLost(network: Network) {
                    if (NativeNet.hotspot == network) NativeNet.hotspot = null
                    monitor?.notifyHotspot("lost")                 // the board left (rebooted, or pairing mode ended)
                }
            }
            joinCallback = cb
            cm.requestNetwork(req, cb, 60000)
        } catch (e: Exception) {
            result.success(mapOf("ok" to false, "code" to "error", "message" to (e.message ?: "")))
        }
    }

    // ------------------------------------------------------------------ mDNS
    /**
     * Finds boards through mDNS ("_esp32hub._tcp"). NsdManager resolves one service at a time, so resolves are queued.
     * Replies a list of {host, id, name, fw}. Holds a multicast lock while it runs (many phones filter multicast otherwise).
     */
    private fun mdnsFind(timeoutMs: Int, result: MethodChannel.Result) {
        val main = Handler(Looper.getMainLooper())
        val found = LinkedHashMap<String, Map<String, String>>()
        var replied = false
        var listener: NsdManager.DiscoveryListener? = null
        val nsd = try { getSystemService(NSD_SERVICE) as NsdManager } catch (e: Exception) { null }
        if (nsd == null) { result.success(emptyList<Any>()); return }
        try {
            val wm = applicationContext.getSystemService(WIFI_SERVICE) as WifiManager
            multicastLock = wm.createMulticastLock("esp32hub-mdns").apply { setReferenceCounted(false); acquire() }
        } catch (_: Exception) { }
        val pending = ArrayDeque<NsdServiceInfo>()
        var resolving = false

        fun finish() {
            if (replied) return
            replied = true
            listener?.let { runCatching { nsd.stopServiceDiscovery(it) } }
            runCatching { multicastLock?.release() }
            result.success(found.values.toList())
        }

        fun resolveNext() {
            if (resolving || replied) return
            val info = pending.removeFirstOrNull() ?: return
            resolving = true
            @Suppress("DEPRECATION")
            nsd.resolveService(info, object : NsdManager.ResolveListener {
                override fun onResolveFailed(i: NsdServiceInfo, errorCode: Int) { main.post { resolving = false; resolveNext() } }
                override fun onServiceResolved(i: NsdServiceInfo) {
                    main.post {
                        val ip = i.host?.hostAddress
                        if (ip != null && !found.containsKey(ip)) {
                            val attrs = i.attributes ?: emptyMap()
                            fun a(k: String) = attrs[k]?.let { String(it) } ?: ""
                            found[ip] = mapOf("host" to ip, "id" to a("id"), "name" to a("name").ifEmpty { i.serviceName ?: "" }, "fw" to a("fw"))
                        }
                        resolving = false
                        resolveNext()
                    }
                }
            })
        }

        listener = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(serviceType: String) {}
            override fun onServiceFound(info: NsdServiceInfo) { main.post { pending.add(info); resolveNext() } }
            override fun onServiceLost(info: NsdServiceInfo) {}
            override fun onDiscoveryStopped(serviceType: String) {}
            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) { main.post { finish() } }
            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {}
        }
        try {
            nsd.discoverServices("_esp32hub._tcp", NsdManager.PROTOCOL_DNS_SD, listener)
        } catch (e: Exception) {
            finish(); return
        }
        main.postDelayed({ finish() }, timeoutMs.toLong())
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
