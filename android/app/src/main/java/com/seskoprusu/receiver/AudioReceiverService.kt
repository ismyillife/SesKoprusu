package com.seskoprusu.receiver

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.util.Log
import java.io.BufferedInputStream
import java.io.DataInputStream
import java.io.IOException
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import kotlin.concurrent.thread

/**
 * iPhone'dan gelen PCM ses akışını TCP üzerinden alıp AudioTrack ile çalar.
 *
 * Paket biçimi (big-endian başlık, 16 bayt):
 *   magic   u32  = 'SKP1'
 *   rate    u32  (örn. 44100)
 *   chans   u16  (1 veya 2)
 *   bits    u16  (16)
 *   length  u32  (yük bayt sayısı)
 *   payload      16-bit little-endian, araya serpiştirilmiş (interleaved) PCM
 */
class AudioReceiverService : Service() {

    data class State(
        val running: Boolean = false,
        val client: String? = null,
        val sampleRate: Int = 0,
        val channels: Int = 0,
        val error: String? = null,
    )

    companion object {
        const val PORT = 50505
        const val SERVICE_TYPE = "_seskoprusu._tcp"
        const val ACTION_STOP = "com.seskoprusu.receiver.STOP"
        private const val MAGIC = 0x534B5031 // "SKP1"
        private const val CHANNEL_ID = "ses_koprusu"
        private const val NOTIF_ID = 1
        private const val TAG = "SesKoprusu"

        @Volatile var state = State()
            private set

        /** Arayüz dinleyicisi; ana iş parçacığında çağrılır. */
        var listener: ((State) -> Unit)? = null

        /** Gecikme tamponu (ms). Değişince çalan iz yeniden kurulur. */
        @Volatile var bufferMs = 200
            set(value) { field = value; trackDirty = true }
        @Volatile private var trackDirty = false

        private val main = Handler(Looper.getMainLooper())

        private fun publish(s: State) {
            state = s
            main.post { listener?.invoke(s) }
        }
    }

    private var serverSocket: ServerSocket? = null
    @Volatile private var client: Socket? = null
    private var nsdManager: NsdManager? = null
    private var nsdListener: NsdManager.RegistrationListener? = null
    private var wifiLock: WifiManager.WifiLock? = null
    private var wakeLock: PowerManager.WakeLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        val nm = getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(
            NotificationChannel(CHANNEL_ID, "Ses Köprüsü", NotificationManager.IMPORTANCE_LOW)
        )
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopSelf()
            return START_NOT_STICKY
        }
        if (serverSocket != null) return START_NOT_STICKY

        val notif = buildNotification("iPhone bekleniyor…")
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(NOTIF_ID, notif, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK)
        } else {
            startForeground(NOTIF_ID, notif)
        }
        acquireLocks()

        try {
            val ss = ServerSocket()
            ss.reuseAddress = true
            ss.bind(InetSocketAddress(PORT))
            serverSocket = ss
            registerNsd()
            publish(State(running = true))
            thread(name = "accept") { acceptLoop(ss) }
        } catch (e: IOException) {
            Log.e(TAG, "Sunucu açılamadı", e)
            publish(State(running = false, error = "Port $PORT açılamadı: ${e.message}"))
            stopSelf()
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        try { serverSocket?.close() } catch (_: IOException) {}
        serverSocket = null
        try { client?.close() } catch (_: IOException) {}
        client = null
        unregisterNsd()
        releaseLocks()
        publish(State(running = false))
        super.onDestroy()
    }

    // ---------------------------------------------------------------- ağ

    private fun acceptLoop(ss: ServerSocket) {
        while (!ss.isClosed) {
            val s = try { ss.accept() } catch (e: IOException) { break }
            // Yeni bağlantı eskisinin yerini alır.
            try { client?.close() } catch (_: IOException) {}
            client = s
            thread(name = "client") { handleClient(s) }
        }
    }

    private fun handleClient(s: Socket) {
        val addr = s.inetAddress?.hostAddress ?: "?"
        Log.i(TAG, "Bağlandı: $addr")
        publish(state.copy(client = addr, error = null))
        updateNotification("Bağlı: $addr")

        var track: AudioTrack? = null
        var curRate = 0
        var curCh = 0
        var buf = ByteArray(16 * 1024)
        try {
            s.tcpNoDelay = true
            s.receiveBufferSize = 128 * 1024
            val input = DataInputStream(BufferedInputStream(s.getInputStream(), 64 * 1024))
            while (true) {
                if (input.readInt() != MAGIC) throw IOException("Geçersiz paket")
                val rate = input.readInt()
                val ch = input.readShort().toInt()
                val bits = input.readShort().toInt()
                val len = input.readInt()
                if (bits != 16 || ch !in 1..2 || rate !in 8000..192000 || len <= 0 || len > 1_000_000) {
                    throw IOException("Desteklenmeyen biçim: $rate Hz, $ch kanal, $bits bit, $len bayt")
                }
                if (buf.size < len) buf = ByteArray(len)
                input.readFully(buf, 0, len)

                var t = track
                if (t == null || rate != curRate || ch != curCh || trackDirty) {
                    t?.release()
                    trackDirty = false
                    t = createTrack(rate, ch)
                    track = t
                    curRate = rate
                    curCh = ch
                    publish(state.copy(sampleRate = rate, channels = ch))
                }
                // Bloklamayan yazma: tampon doluysa fazlası atılır, böylece gecikme
                // hiçbir zaman tampon boyunu aşmaz.
                t.write(buf, 0, len - (len % (2 * ch)), AudioTrack.WRITE_NON_BLOCKING)
            }
        } catch (e: IOException) {
            Log.i(TAG, "Bağlantı kapandı: ${e.message}")
        } finally {
            track?.let { it.pause(); it.flush(); it.release() }
            try { s.close() } catch (_: IOException) {}
            if (client === s) {
                client = null
                if (serverSocket != null) {
                    publish(state.copy(client = null, sampleRate = 0, channels = 0))
                    updateNotification("iPhone bekleniyor…")
                }
            }
        }
    }

    private fun createTrack(rate: Int, ch: Int): AudioTrack {
        val mask = if (ch == 1) AudioFormat.CHANNEL_OUT_MONO else AudioFormat.CHANNEL_OUT_STEREO
        val minBuf = AudioTrack.getMinBufferSize(rate, mask, AudioFormat.ENCODING_PCM_16BIT)
        val wanted = rate * 2 * ch * bufferMs / 1000
        val t = AudioTrack.Builder()
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                    .build()
            )
            .setAudioFormat(
                AudioFormat.Builder()
                    .setSampleRate(rate)
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                    .setChannelMask(mask)
                    .build()
            )
            .setBufferSizeInBytes(maxOf(minBuf, wanted))
            .setTransferMode(AudioTrack.MODE_STREAM)
            .build()
        t.play()
        return t
    }

    // ---------------------------------------------------------------- NSD (Bonjour)

    private fun registerNsd() {
        val info = NsdServiceInfo().apply {
            serviceName = "SesKoprusu-${Build.MODEL}".take(60)
            serviceType = SERVICE_TYPE
            port = PORT
        }
        val l = object : NsdManager.RegistrationListener {
            override fun onServiceRegistered(i: NsdServiceInfo) { Log.i(TAG, "NSD kaydı: ${i.serviceName}") }
            override fun onRegistrationFailed(i: NsdServiceInfo, code: Int) { Log.w(TAG, "NSD kaydı başarısız: $code") }
            override fun onServiceUnregistered(i: NsdServiceInfo) {}
            override fun onUnregistrationFailed(i: NsdServiceInfo, code: Int) {}
        }
        nsdManager = getSystemService(NsdManager::class.java)
        nsdListener = l
        nsdManager?.registerService(info, NsdManager.PROTOCOL_DNS_SD, l)
    }

    private fun unregisterNsd() {
        val l = nsdListener ?: return
        try { nsdManager?.unregisterService(l) } catch (_: IllegalArgumentException) {}
        nsdListener = null
    }

    // ---------------------------------------------------------------- kilitler / bildirim

    @Suppress("DEPRECATION")
    private fun acquireLocks() {
        val wm = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
        val mode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q)
            WifiManager.WIFI_MODE_FULL_LOW_LATENCY else WifiManager.WIFI_MODE_FULL_HIGH_PERF
        wifiLock = wm.createWifiLock(mode, "SesKoprusu:wifi").apply { setReferenceCounted(false); acquire() }
        val pm = getSystemService(PowerManager::class.java)
        wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "SesKoprusu:cpu").apply {
            setReferenceCounted(false); acquire()
        }
    }

    private fun releaseLocks() {
        wifiLock?.let { if (it.isHeld) it.release() }
        wakeLock?.let { if (it.isHeld) it.release() }
        wifiLock = null
        wakeLock = null
    }

    private fun buildNotification(text: String): Notification {
        val open = PendingIntent.getActivity(
            this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE
        )
        val stop = PendingIntent.getService(
            this, 1, Intent(this, AudioReceiverService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_IMMUTABLE
        )
        return Notification.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_media_play)
            .setContentTitle("Ses Köprüsü")
            .setContentText(text)
            .setContentIntent(open)
            .setOngoing(true)
            .addAction(Notification.Action.Builder(null, "Durdur", stop).build())
            .build()
    }

    private fun updateNotification(text: String) {
        getSystemService(NotificationManager::class.java).notify(NOTIF_ID, buildNotification(text))
    }
}
