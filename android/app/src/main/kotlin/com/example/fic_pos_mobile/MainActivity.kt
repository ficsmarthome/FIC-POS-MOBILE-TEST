package com.example.fic_pos_mobile

import android.Manifest
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.content.BroadcastReceiver
import android.content.Context
import android.content.IntentFilter
import android.os.Handler
import android.os.Looper
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.UUID

class MainActivity : FlutterActivity() {
    private val channelName = "fic_pos/background_notifications"
    private val printerChannelName = "fic_pos/printer"

    override fun onResume() {
        super.onResume()
        getSharedPreferences("fic_pos_bg", MODE_PRIVATE).edit().putBoolean("app_foreground", true).apply()
    }

    override fun onPause() {
        getSharedPreferences("fic_pos_bg", MODE_PRIVATE).edit().putBoolean("app_foreground", false).apply()
        super.onPause()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName).setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    requestNotificationPermissionIfNeeded()
                    val sound = call.argument<Boolean>("sound") ?: true
                    getSharedPreferences("fic_pos_bg", MODE_PRIVATE).edit().putBoolean("sound_enabled", sound).apply()
                    val intent = Intent(this, FicNotificationService::class.java)
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) startForegroundService(intent) else startService(intent)
                    result.success(true)
                }
                "stop" -> { stopService(Intent(this, FicNotificationService::class.java)); result.success(true) }
                "setSound" -> {
                    val sound = call.argument<Boolean>("sound") ?: true
                    getSharedPreferences("fic_pos_bg", MODE_PRIVATE).edit().putBoolean("sound_enabled", sound).apply()
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, printerChannelName).setMethodCallHandler { call, result ->
            when (call.method) {
                "bondedBluetooth" -> {
                    try {
                        ensureBluetoothConnectPermission()
                        val adapter = BluetoothAdapter.getDefaultAdapter()
                        if (adapter == null) { result.success(emptyList<Map<String,String>>()); return@setMethodCallHandler }
                        val rows = adapter.bondedDevices.map { d -> mapOf("name" to (d.name ?: "Bluetooth"), "address" to d.address) }
                        result.success(rows)
                    } catch (e: SecurityException) {
                        result.error("BT_PERMISSION", "Cần cấp quyền Thiết bị ở gần/Bluetooth cho FIC POS.", null)
                    } catch (e: Exception) {
                        result.error("BT_LIST", e.message ?: "Không đọc được thiết bị Bluetooth.", null)
                    }
                }
                "scanBluetooth" -> {
                    try {
                        ensureBluetoothConnectPermission()
                        val adapter = BluetoothAdapter.getDefaultAdapter()
                        if (adapter == null) { result.success(emptyList<Map<String,String>>()); return@setMethodCallHandler }
                        val found = linkedMapOf<String, Map<String,String>>()
                        adapter.bondedDevices.forEach { d -> found[d.address] = mapOf("name" to (d.name ?: "Bluetooth"), "address" to d.address) }
                        val receiver = object : BroadcastReceiver() {
                            override fun onReceive(context: Context?, intent: Intent?) {
                                if (BluetoothDevice.ACTION_FOUND == intent?.action) {
                                    val d: BluetoothDevice? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE, BluetoothDevice::class.java) else intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE)
                                    if (d != null) try { found[d.address] = mapOf("name" to (d.name ?: "Bluetooth"), "address" to d.address) } catch (_: SecurityException) {}
                                }
                            }
                        }
                        registerReceiver(receiver, IntentFilter(BluetoothDevice.ACTION_FOUND))
                        adapter.cancelDiscovery(); adapter.startDiscovery()
                        Handler(Looper.getMainLooper()).postDelayed({
                            try { adapter.cancelDiscovery() } catch (_: Exception) {}
                            try { unregisterReceiver(receiver) } catch (_: Exception) {}
                            result.success(found.values.toList())
                        }, 6500)
                    } catch (e: SecurityException) {
                        result.error("BT_PERMISSION", "Cần cấp quyền Thiết bị ở gần/Bluetooth cho FIC POS.", null)
                    } catch (e: Exception) {
                        result.error("BT_SCAN", e.message ?: "Không quét được thiết bị Bluetooth.", null)
                    }
                }
                "printBluetooth" -> {
                    val address = call.argument<String>("address") ?: ""
                    val raw = call.argument<ByteArray>("bytes")
                    if (address.isBlank() || raw == null) { result.error("BT_ARGS", "Thiếu địa chỉ hoặc dữ liệu in.", null); return@setMethodCallHandler }
                    Thread {
                        try {
                            ensureBluetoothConnectPermission()
                            val adapter = BluetoothAdapter.getDefaultAdapter() ?: throw IllegalStateException("Thiết bị không hỗ trợ Bluetooth.")
                            val device: BluetoothDevice = adapter.getRemoteDevice(address)
                            val uuid = UUID.fromString("00001101-0000-1000-8000-00805F9B34FB") // Serial Port Profile
                            adapter.cancelDiscovery()
                            val socket = device.createRfcommSocketToServiceRecord(uuid)
                            socket.connect()
                            socket.outputStream.use { out -> out.write(raw); out.flush() }
                            socket.close()
                            runOnUiThread { result.success(true) }
                        } catch (e: SecurityException) {
                            runOnUiThread { result.error("BT_PERMISSION", "Cần cấp quyền Thiết bị ở gần/Bluetooth cho FIC POS.", null) }
                        } catch (e: Exception) {
                            runOnUiThread { result.error("BT_PRINT", e.message ?: "Không in được qua Bluetooth.", null) }
                        }
                    }.start()
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun ensureBluetoothConnectPermission() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(arrayOf(Manifest.permission.BLUETOOTH_CONNECT, Manifest.permission.BLUETOOTH_SCAN), 23302)
            throw SecurityException("Bluetooth permission requested")
        }
    }

    private fun requestNotificationPermissionIfNeeded() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 23301)
        }
    }
}
