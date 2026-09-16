package com.example.fic_pos_mobile

import android.app.*
import android.content.Context
import android.content.Intent
import android.graphics.BitmapFactory
import android.media.AudioAttributes
import android.net.Uri
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.atomic.AtomicBoolean

class FicNotificationService : Service() {
    companion object {
        private const val SERVICE_CHANNEL = "fic_pos_background"
        private const val ALERT_SOUND_CHANNEL = "fic_pos_alert_sound_v1103"
        private const val ALERT_SILENT_CHANNEL = "fic_pos_alert_silent_v1103"
        private const val SERVICE_NOTIFICATION_ID = 23300
    }

    private val running = AtomicBoolean(false)
    private var worker: Thread? = null
    @Volatile private var rateLimitUntilMs: Long = 0L
    @Volatile private var rateLimitStreak: Int = 0

    override fun onCreate() {
        super.onCreate()
        createChannels()
        startForeground(SERVICE_NOTIFICATION_ID, serviceNotification())
        startPolling()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (!running.get()) startPolling()
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        running.set(false)
        worker?.interrupt()
        worker = null
        super.onDestroy()
    }

    private fun startPolling() {
        if (!running.compareAndSet(false, true)) return
        worker = Thread {
            while (running.get()) {
                try { pollOnce() } catch (_: Throwable) {}
                try { Thread.sleep(5000) } catch (_: InterruptedException) { break }
            }
        }.apply { name = "FIC-POS-Background-Alerts"; start() }
    }

    private fun pollOnce() {
        if (System.currentTimeMillis() < rateLimitUntilMs) return
        val flutterPrefs = getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
        val base = flutterPrefs.getString("flutter.base", "")?.trimEnd('/') ?: ""
        val token = flutterPrefs.getString("flutter.token", "") ?: ""
        if (base.isBlank() || token.isBlank()) return

        val bgPrefs = getSharedPreferences("fic_pos_bg", Context.MODE_PRIVATE)
        pollEventStream(base, token, bgPrefs)
        pollQrFallback(base, token, bgPrefs)
    }

    private fun pollEventStream(base: String, token: String, bgPrefs: android.content.SharedPreferences) {
        val hasCursor = bgPrefs.contains("last_event_id")
        val lastId = bgPrefs.getLong("last_event_id", 0L)
        val url = URL("$base/api/mobile/v1/notification-events?after_id=$lastId")
        val conn = open(url, token)
        try {
            if (!responseOk(conn)) return
            val body = conn.inputStream.bufferedReader().use { it.readText() }
            val json = JSONObject(body)
            val latest = json.optLong("latest_id", lastId)
            val events = json.optJSONArray("events")

            // Lần đầu chỉ lấy mốc hiện tại, tránh phát lại lịch sử cũ.
            if (!hasCursor) {
                bgPrefs.edit().putLong("last_event_id", latest).apply()
                return
            }

            var maxSeen = lastId
            if (events != null) {
                for (i in 0 until events.length()) {
                    val e = events.optJSONObject(i) ?: continue
                    val id = e.optLong("id", 0L)
                    if (id <= lastId) continue
                    showAlert(e)
                    if (e.optString("type") == "qr_order_new") {
                        val qrId = e.optString("ref_id").toLongOrNull()
                            ?: e.optJSONObject("payload")?.optLong("qr_order_id", 0L)
                            ?: 0L
                        if (qrId > 0) bgPrefs.edit().putLong("last_qr_pending_id", qrId).apply()
                    }
                    if (id > maxSeen) maxSeen = id
                }
            }
            if (latest > maxSeen) maxSeen = latest
            if (maxSeen > lastId) bgPrefs.edit().putLong("last_event_id", maxSeen).apply()
        } catch (_: Throwable) {
            // Fallback QR phía dưới vẫn tiếp tục hoạt động.
        } finally {
            conn.disconnect()
        }
    }

    private fun pollQrFallback(base: String, token: String, bgPrefs: android.content.SharedPreferences) {
        val hasCursor = bgPrefs.contains("last_qr_pending_id")
        val lastQrId = bgPrefs.getLong("last_qr_pending_id", 0L)
        val conn = open(URL("$base/api/mobile/v1/qr-pending"), token)
        try {
            if (!responseOk(conn)) return
            val body = conn.inputStream.bufferedReader().use { it.readText() }
            val json = JSONObject(body)
            val latestId = json.optLong("latest_id", 0L)
            val count = json.optInt("count", 0)

            if (!hasCursor) {
                bgPrefs.edit().putLong("last_qr_pending_id", latestId).apply()
                return
            }
            if (count <= 0 || latestId <= lastQrId) return

            val detail = fetchQrDetail(base, token, latestId)
            val table = detail?.first ?: "Bàn có khách gọi món"
            val qty = detail?.second ?: count
            val code = detail?.third.orEmpty()
            val bodyText = buildString {
                append("$qty món đang chờ xác nhận")
                if (code.isNotBlank()) append(" • $code")
                append("\nNhấn để mở FIC POS và xử lý đơn.")
            }
            showQrAlert(latestId, table, bodyText)
            bgPrefs.edit().putLong("last_qr_pending_id", latestId).apply()
        } catch (_: Throwable) {
        } finally {
            conn.disconnect()
        }
    }

    private fun fetchQrDetail(base: String, token: String, wantedId: Long): Triple<String, Int, String>? {
        val conn = open(URL("$base/api/mobile/v1/qr-orders"), token)
        try {
            if (!responseOk(conn)) return null
            val json = JSONObject(conn.inputStream.bufferedReader().use { it.readText() })
            val rows = json.optJSONArray("data") ?: return null
            for (i in 0 until rows.length()) {
                val row = rows.optJSONObject(i) ?: continue
                if (row.optLong("id", 0L) != wantedId) continue
                val table = row.optString("tenban", "Bàn có khách gọi món")
                val code = row.optString("public_code", "")
                val items = row.optJSONArray("items")
                var qty = 0
                if (items != null) {
                    for (j in 0 until items.length()) {
                        qty += items.optJSONObject(j)?.optInt("quantity", 1) ?: 1
                    }
                }
                if (qty <= 0) qty = 1
                return Triple(table, qty, code)
            }
            return null
        } catch (_: Throwable) {
            return null
        } finally {
            conn.disconnect()
        }
    }

    private fun responseOk(conn: HttpURLConnection): Boolean {
        val code = try { conn.responseCode } catch (_: Throwable) { return false }
        if (code == 429) {
            rateLimitStreak = (rateLimitStreak + 1).coerceAtMost(6)
            val retryHeader = conn.getHeaderField("Retry-After")?.toLongOrNull()?.coerceIn(1L, 60L)
            val fallback = (2L shl (rateLimitStreak - 1).coerceAtMost(4)).coerceAtMost(30L)
            val waitSeconds = retryHeader ?: fallback
            rateLimitUntilMs = System.currentTimeMillis() + waitSeconds * 1000L
            return false
        }
        if (code in 200..299) {
            rateLimitStreak = 0
            rateLimitUntilMs = 0L
            return true
        }
        return false
    }

    private fun open(url: URL, token: String): HttpURLConnection =
        (url.openConnection() as HttpURLConnection).apply {
            requestMethod = "GET"
            connectTimeout = 7000
            readTimeout = 7000
            setRequestProperty("Accept", "application/json")
            setRequestProperty("Authorization", "Bearer $token")
            useCaches = false
        }

    private fun showAlert(event: JSONObject) {
        val bgPrefs = getSharedPreferences("fic_pos_bg", Context.MODE_PRIVATE)
        val sound = bgPrefs.getBoolean("sound_enabled", true)
        val rawTitle = event.optString("title", "FIC POS")
        val body = event.optString("body", "Có thông báo mới")
        val type = event.optString("type", "")
        // FCM V253 owns payment_request; avoid a duplicate system notification from polling.
        if (type == "payment_request") return
        val id = event.optLong("id", System.currentTimeMillis()).toInt()
        val title = if (type == "qr_order_new") "🍽️ $rawTitle" else if (type == "payment_completed") "✅ $rawTitle" else rawTitle
        showSystemNotification(id, title, body, type, sound)
    }

    private fun showQrAlert(qrId: Long, table: String, body: String) {
        val sound = getSharedPreferences("fic_pos_bg", Context.MODE_PRIVATE).getBoolean("sound_enabled", true)
        showSystemNotification((900000L + qrId).toInt(), "🍽️ Đơn QR mới • $table", body, "qr_order_new", sound)
    }

    private fun showSystemNotification(id: Int, title: String, body: String, type: String, sound: Boolean) {
        // Khi app đang mở, QR dùng banner Flutter đẹp để tránh kêu/hiện trùng 2 lần.
        if (type == "qr_order_new" && getSharedPreferences("fic_pos_bg", Context.MODE_PRIVATE).getBoolean("app_foreground", false)) return
        val channel = if (sound) ALERT_SOUND_CHANNEL else ALERT_SILENT_CHANNEL
        val openIntent = packageManager.getLaunchIntentForPackage(packageName)?.apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP
            putExtra("fic_notification_type", type)
        }
        val pending = if (openIntent != null) PendingIntent.getActivity(
            this, id, openIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or if (Build.VERSION.SDK_INT >= 23) PendingIntent.FLAG_IMMUTABLE else 0
        ) else null

        val builder = NotificationCompat.Builder(this, channel)
            .setSmallIcon(android.R.drawable.ic_dialog_email)
            .setLargeIcon(BitmapFactory.decodeResource(resources, R.mipmap.ic_launcher))
            .setContentTitle(title)
            .setContentText(body.substringBefore('\n'))
            .setStyle(NotificationCompat.BigTextStyle().bigText(body))
            .setSubText(if (type == "qr_order_new") "FIC POS • Gọi món tại bàn" else "FIC POS")
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setAutoCancel(true)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setCategory(if (type == "payment_completed") NotificationCompat.CATEGORY_STATUS else NotificationCompat.CATEGORY_MESSAGE)
        if (pending != null) {
            builder.setContentIntent(pending)
            if (type == "qr_order_new") builder.addAction(0, "MỞ ĐƠN", pending)
        }
        (getSystemService(NOTIFICATION_SERVICE) as NotificationManager).notify(id, builder.build())
    }

    private fun createChannels() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        manager.createNotificationChannel(NotificationChannel(
            SERVICE_CHANNEL, "FIC POS chạy nền", NotificationManager.IMPORTANCE_LOW
        ).apply { description = "Duy trì theo dõi gọi món QR và thanh toán khi app ở nền"; setSound(null, null); enableVibration(false) })

        manager.createNotificationChannel(NotificationChannel(
            ALERT_SOUND_CHANNEL, "Đơn QR & thanh toán quan trọng", NotificationManager.IMPORTANCE_HIGH
        ).apply {
            description = "Hiện thông báo nổi và phát âm khi có đơn QR hoặc thanh toán mới"
            enableVibration(true)
            vibrationPattern = longArrayOf(0, 220, 120, 220)
            val attrs = AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_NOTIFICATION).build()
            setSound(Uri.parse("content://settings/system/notification_sound"), attrs)
        })

        manager.createNotificationChannel(NotificationChannel(
            ALERT_SILENT_CHANNEL, "Đơn QR & thanh toán (im lặng)", NotificationManager.IMPORTANCE_HIGH
        ).apply {
            description = "Vẫn hiện thông báo nổi khi nút loa FIC POS đang tắt"
            setSound(null, null)
            enableVibration(true)
            vibrationPattern = longArrayOf(0, 180, 100, 180)
        })
    }

    private fun serviceNotification(): Notification {
        val launch = packageManager.getLaunchIntentForPackage(packageName)
        val pending = if (launch != null) PendingIntent.getActivity(
            this, 23300, launch,
            PendingIntent.FLAG_UPDATE_CURRENT or if (Build.VERSION.SDK_INT >= 23) PendingIntent.FLAG_IMMUTABLE else 0
        ) else null
        return NotificationCompat.Builder(this, SERVICE_CHANNEL)
            .setSmallIcon(android.R.drawable.stat_notify_sync_noanim)
            .setContentTitle("FIC POS đang chạy nền")
            .setContentText("Sẵn sàng báo đơn QR và thanh toán")
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .apply { if (pending != null) setContentIntent(pending) }
            .build()
    }
}
