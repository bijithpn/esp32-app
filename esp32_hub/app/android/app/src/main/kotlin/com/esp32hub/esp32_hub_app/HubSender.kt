package com.esp32hub.esp32_hub_app

import android.content.Context
import android.content.SharedPreferences
import org.json.JSONObject
import java.util.ArrayDeque
import java.util.UUID

/**
 * Sends commands to the ESP32 Hub over local HTTP from native code, so notification mirroring and "now playing" keep
 * working when the Flutter UI is closed. Address and token are saved by the Flutter app (the token is stored encrypted
 * with a Keystore key, see [SecureStore]).
 *
 * Delivery rules (so nothing stale is ever replayed after the board was away):
 *  - one worker thread, a queue of at most 6 jobs
 *  - a notification older than 20 s, or a now-playing update older than 30 s, is dropped instead of sent
 *  - only the newest now-playing update is kept
 *  - while the board is unreachable the worker backs off (2 s, 4 s ... 60 s) and drops what arrives meanwhile
 *  - every command carries a request id, so a retry after a lost reply is not executed twice by the board
 */
object HubSender {
    private data class Job(val body: JSONObject, val media: Boolean, val created: Long)

    private val queue = ArrayDeque<Job>()
    private val lock = java.lang.Object()
    private var worker: Thread? = null
    @Volatile private var failures = 0
    @Volatile private var nextTryAt = 0L
    @Volatile private var lastFind = 0L
    @Volatile private var finding = false

    private const val TTL_NOTIFY = 20_000L
    private const val TTL_MEDIA = 30_000L
    private const val MAX_QUEUE = 6

    fun prefs(ctx: Context): SharedPreferences = ctx.getSharedPreferences("hub_bridge", Context.MODE_PRIVATE)

    fun token(ctx: Context): String {
        SecureStore.get(ctx, "bridge_token")?.let { return it }
        val legacy = prefs(ctx).getString("token", "") ?: ""      // written by an older version: move it into the secure store
        if (legacy.isNotEmpty()) {
            SecureStore.put(ctx, "bridge_token", legacy)
            prefs(ctx).edit().remove("token").apply()
        }
        return legacy
    }

    fun post(ctx: Context, body: JSONObject) {
        val app = ctx.applicationContext
        if ((prefs(app).getString("host", "") ?: "").isEmpty()) return
        val media = body.optString("cmd") == "nowplaying"
        synchronized(lock) {
            if (media) queue.removeAll { it.media }                       // only the newest song state matters
            while (queue.size >= MAX_QUEUE) queue.removeFirst()
            body.put("rid", UUID.randomUUID().toString().substring(0, 12))
            queue.addLast(Job(body, media, System.currentTimeMillis()))
            if (worker == null || worker?.isAlive != true) {
                worker = Thread({ run(app) }, "hub-sender").also { it.isDaemon = true; it.start() }
            }
            lock.notifyAll()
        }
    }

    private fun run(ctx: Context) {
        while (true) {
            val job: Job = synchronized(lock) {
                while (queue.isEmpty()) {
                    lock.wait(60_000)
                    if (queue.isEmpty()) { worker = null; return }          // idle for a minute: let the thread end
                }
                queue.removeFirst()
            }
            val age = System.currentTimeMillis() - job.created
            if (age > (if (job.media) TTL_MEDIA else TTL_NOTIFY)) { record(ctx, false, "stale"); continue }
            if (failures >= 2 && System.currentTimeMillis() < nextTryAt) { record(ctx, false, "offline"); continue }
            deliver(ctx, job)
        }
    }

    private fun deliver(ctx: Context, job: Job) {
        val p = prefs(ctx)
        val host = p.getString("host", "") ?: ""
        if (host.isEmpty()) return
        val token = token(ctx)
        val headers = HashMap<String, String>()
        headers["Content-Type"] = "application/json"
        if (token.isNotEmpty()) headers["X-Hub-Token"] = token
        var res: Map<String, Any?> = emptyMap()
        for (attempt in 0..1) {                                              // one retry is safe: the board de-duplicates by request id
            res = NativeNet.http(ctx, "POST", "http://$host/api/cmd", headers, job.body.toString(), 4000)
            if (res["status"] != null) break
        }
        val status = (res["status"] as? Int) ?: 0
        if (status in 200..299) {
            failures = 0; record(ctx, true, "ok")
        } else if (status == 401 || status == 429) {
            record(ctx, false, if (status == 401) "token" else "rate")      // the board is there but refuses: no point in searching for it
        } else {
            failures++
            nextTryAt = System.currentTimeMillis() + minOf(60_000L, 1000L shl minOf(failures, 6))
            record(ctx, false, (res["error"] as? String) ?: "http_$status")
            if (failures >= 2) rediscover(ctx)
        }
    }

    private fun record(ctx: Context, ok: Boolean, code: String) {
        prefs(ctx).edit().putString("last_delivery", "${System.currentTimeMillis()}|${if (ok) 1 else 0}|$code").apply()
    }

    /** Looks for the board (by id): UDP discovery first (one packet), then a /24 sweep, and saves its new address. */
    private fun rediscover(ctx: Context) {
        val now = System.currentTimeMillis()
        if (now - lastFind < 60_000 || finding) return
        lastFind = now; finding = true
        Thread({
            try {
                val p = prefs(ctx)
                val id = p.getString("id", "") ?: ""
                fun pick(list: List<Map<String, String>>): String? {
                    for (m in list) {
                        val j = NativeNet.json(m["body"] ?: "") ?: continue
                        if (j.optString("device") == "ESP32-Hub" && !j.optBoolean("ap") && (id.isEmpty() || j.optString("id") == id)) return m["host"]
                    }
                    return null
                }
                var found = pick(NativeNet.udp(ctx, 41234, "ESP32_HUB_DISCOVER_V1", 1200))
                if (found == null) {
                    for (pre in NativeNet.prefixes(ctx)) {
                        found = pick(NativeNet.sweep(ctx, (1..254).map { "$pre.$it" }, "/api/hello", 700))
                        if (found != null) break
                    }
                }
                if (found != null) { p.edit().putString("host", found).apply(); failures = 0; nextTryAt = 0 }
            } catch (_: Exception) {
            } finally {
                finding = false
            }
        }, "hub-rediscover").also { it.isDaemon = true; it.start() }
    }
}
