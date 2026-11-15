package com.esp32hub.esp32_hub_app

import android.annotation.SuppressLint
import android.content.Intent
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiNetworkSpecifier
import android.os.Build
import android.os.Handler
import android.os.Looper
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
                    // Pin this app to a Wi-Fi that has no internet (the board's hotspot), otherwise Android sends our traffic over mobile data.
                    "bindWifi" -> result.success(bindWifiWithoutInternet(call.argument<Boolean>("force") ?: false))
                    "mdnsFind" -> mdnsFind(call.argument<Int>("timeoutMs") ?: 2500, result)
                    "joinWifi" -> joinWifi(call.argument<String>("ssid") ?: "", call.argument<String>("pass") ?: "", result)
                    "leaveHotspot" -> {
                        val cm = getSystemService(CONNECTIVITY_SERVICE) as ConnectivityManager
                        joinCallback?.let { runCatching { cm.unregisterNetworkCallback(it) } }
                        joinCallback = null
                        cm.bindProcessToNetwork(null)
                        result.success(null)
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

    // Finds boards through mDNS ("_esp32hub._tcp", advertised by the firmware). Replies with their IP addresses.
    private fun mdnsFind(timeoutMs: Int, result: MethodChannel.Result) {
        val main = Handler(Looper.getMainLooper())
        val found = mutableListOf<String>()
        var replied = false
        var listener: NsdManager.DiscoveryListener? = null
        val nsd = try { getSystemService(NSD_SERVICE) as NsdManager } catch (e: Exception) { null }
        if (nsd == null) { result.success(found); return }
        fun finish() {
            if (replied) return
            replied = true
            listener?.let { runCatching { nsd.stopServiceDiscovery(it) } }
            result.success(found)
        }
        listener = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(serviceType: String) {}
            override fun onServiceFound(info: NsdServiceInfo) {
                @Suppress("DEPRECATION")
                nsd.resolveService(info, object : NsdManager.ResolveListener {
                    override fun onResolveFailed(i: NsdServiceInfo, errorCode: Int) {}
                    override fun onServiceResolved(i: NsdServiceInfo) {
                        val ip = i.host?.hostAddress
                        main.post { if (ip != null && !found.contains(ip)) found.add(ip); finish() }
                    }
                })
            }
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

    private var joinCallback: ConnectivityManager.NetworkCallback? = null

    // Joins the board's hotspot straight from its QR code (Android 10+ asks the user to confirm once).
    private fun joinWifi(ssid: String, pass: String, result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q || ssid.isEmpty()) { result.success(false); return }
        try {
            val cm = getSystemService(CONNECTIVITY_SERVICE) as ConnectivityManager
            joinCallback?.let { runCatching { cm.unregisterNetworkCallback(it) } }
            val spec = WifiNetworkSpecifier.Builder().setSsid(ssid).apply { if (pass.isNotEmpty()) setWpa2Passphrase(pass) }.build()
            val req = NetworkRequest.Builder()
                .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
                .removeCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
                .setNetworkSpecifier(spec)
                .build()
            var replied = false
            val cb = object : ConnectivityManager.NetworkCallback() {
                override fun onAvailable(network: Network) {
                    cm.bindProcessToNetwork(network)
                    if (!replied) { replied = true; runOnUiThread { result.success(true) } }
                }
                override fun onUnavailable() {
                    if (!replied) { replied = true; runOnUiThread { result.success(false) } }
                }
            }
            joinCallback = cb
            cm.requestNetwork(req, cb, 30000)
        } catch (e: Exception) {
            result.success(false)
        }
    }

    @Suppress("DEPRECATION")
    private fun bindWifiWithoutInternet(force: Boolean): Boolean {
        return try {
            val cm = getSystemService(CONNECTIVITY_SERVICE) as ConnectivityManager
            for (n in cm.allNetworks) {
                val c = cm.getNetworkCapabilities(n) ?: continue
                // force = talking to the board on the local network: always use the Wi-Fi, even one Android thinks is "fine"
                if (c.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) && (force || !c.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED))) {
                    return cm.bindProcessToNetwork(n)
                }
            }
            cm.bindProcessToNetwork(null)   // normal Wi-Fi with internet (or none): let Android route as usual
            false
        } catch (_: Exception) {
            false
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
