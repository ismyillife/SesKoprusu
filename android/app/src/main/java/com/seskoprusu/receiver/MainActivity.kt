package com.seskoprusu.receiver

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.widget.Button
import android.widget.RadioGroup
import android.widget.TextView
import java.net.Inet4Address
import java.net.NetworkInterface

class MainActivity : Activity() {

    private lateinit var statusText: TextView
    private lateinit var addressText: TextView
    private lateinit var formatText: TextView
    private lateinit var toggleButton: Button
    private lateinit var bufferGroup: RadioGroup

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)

        statusText = findViewById(R.id.status)
        addressText = findViewById(R.id.address)
        formatText = findViewById(R.id.format)
        toggleButton = findViewById(R.id.toggle)
        bufferGroup = findViewById(R.id.bufferGroup)

        if (Build.VERSION.SDK_INT >= 33 &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1)
        }

        val prefs = getPreferences(MODE_PRIVATE)
        AudioReceiverService.bufferMs = prefs.getInt("bufferMs", 200)
        bufferGroup.check(
            when (AudioReceiverService.bufferMs) {
                100 -> R.id.buf100
                400 -> R.id.buf400
                else -> R.id.buf200
            }
        )
        bufferGroup.setOnCheckedChangeListener { _, id ->
            val ms = when (id) { R.id.buf100 -> 100; R.id.buf400 -> 400; else -> 200 }
            AudioReceiverService.bufferMs = ms
            prefs.edit().putInt("bufferMs", ms).apply()
        }

        toggleButton.setOnClickListener {
            val intent = Intent(this, AudioReceiverService::class.java)
            if (AudioReceiverService.state.running) stopService(intent) else startForegroundService(intent)
        }
    }

    override fun onResume() {
        super.onResume()
        AudioReceiverService.listener = { render(it) }
        render(AudioReceiverService.state)
    }

    override fun onPause() {
        AudioReceiverService.listener = null
        super.onPause()
    }

    private fun render(s: AudioReceiverService.State) {
        toggleButton.text = if (s.running) "Durdur" else "Başlat"
        statusText.text = when {
            s.error != null -> "Hata: ${s.error}"
            !s.running -> "Kapalı"
            s.client != null -> "Bağlı: ${s.client}"
            else -> "iPhone bekleniyor…"
        }
        formatText.text = if (s.sampleRate > 0)
            "${s.sampleRate} Hz · ${if (s.channels == 2) "stereo" else "mono"}" else ""

        val ips = localIpv4()
        addressText.text = if (ips.isEmpty()) "Wi-Fi bağlantısı yok"
        else ips.joinToString("\n") { "$it:${AudioReceiverService.PORT}" }
    }

    private fun localIpv4(): List<String> = try {
        NetworkInterface.getNetworkInterfaces().toList()
            .filter { it.isUp && !it.isLoopback }
            .flatMap { it.inetAddresses.toList() }
            .filterIsInstance<Inet4Address>()
            .mapNotNull { it.hostAddress }
    } catch (_: Exception) {
        emptyList()
    }
}
