package com.esp32hub.esp32_hub_app

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.EventChannel

/**
 * Pushes network changes to Flutter (EventChannel "esp32hub/network") so the app reacts to Wi-Fi coming back, a new IP,
 * a Wi-Fi without internet, or the phone moving to mobile data without polling. It binds nothing: see [NativeNet].
 */
class NetworkMonitor(ctx: Context) : EventChannel.StreamHandler {
    private val app = ctx.applicationContext
    private val cm = NativeNet.cm(app)
    private val main = Handler(Looper.getMainLooper())
    private var sink: EventChannel.EventSink? = null
    private var defCb: ConnectivityManager.NetworkCallback? = null
    private var wifiCb: ConnectivityManager.NetworkCallback? = null
    private var lastWifiKey = ""

    private fun emit(m: Map<String, Any?>) { main.post { sink?.success(m) } }

    override fun onListen(args: Any?, events: EventChannel.EventSink?) {
        sink = events
        register()
        emit(mapOf("t" to "snapshot") + NativeNet.snapshot(app))
    }

    override fun onCancel(args: Any?) {
        sink = null
        unregister()
    }

    private fun register() {
        if (defCb != null) return
        val d = object : ConnectivityManager.NetworkCallback() {
            override fun onCapabilitiesChanged(n: Network, c: NetworkCapabilities) {
                val t = when {
                    c.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> "wifi"
                    c.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> "cellular"
                    else -> "other"
                }
                emit(mapOf("t" to "default", "transport" to t, "validated" to c.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)))
            }
            override fun onLost(n: Network) { emit(mapOf("t" to "default", "transport" to "none", "validated" to false)) }
        }
        val w = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(n: Network) { emit(mapOf("t" to "wifi", "state" to "available") + NativeNet.snapshot(app)) }
            override fun onLinkPropertiesChanged(n: Network, lp: android.net.LinkProperties) {
                // fires on a new IP address / a different network: the cached board address may be stale now
                val key = lp.linkAddresses.joinToString(",") { it.address.hostAddress ?: "" }
                if (key != lastWifiKey) { lastWifiKey = key; emit(mapOf("t" to "wifi", "state" to "changed") + NativeNet.snapshot(app)) }
            }
            override fun onLost(n: Network) { lastWifiKey = ""; emit(mapOf("t" to "wifi", "state" to "lost") + NativeNet.snapshot(app)) }
        }
        try {
            cm.registerDefaultNetworkCallback(d)
            cm.registerNetworkCallback(NetworkRequest.Builder().addTransportType(NetworkCapabilities.TRANSPORT_WIFI).build(), w)
            defCb = d; wifiCb = w
        } catch (_: Exception) { }
    }

    private fun unregister() {
        defCb?.let { runCatching { cm.unregisterNetworkCallback(it) } }
        wifiCb?.let { runCatching { cm.unregisterNetworkCallback(it) } }
        defCb = null; wifiCb = null
    }

    fun notifyHotspot(state: String) = emit(mapOf("t" to "hotspot", "state" to state))
}
