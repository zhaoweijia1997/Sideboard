package app.sideboard.link

import android.app.KeyguardManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import org.json.JSONObject
import java.io.InputStream
import java.net.Inet4Address
import java.net.NetworkInterface
import java.net.ServerSocket
import java.net.Socket
import java.util.UUID
import java.util.concurrent.TimeUnit

/**
 * Waits on the local network for Sideboard on a Mac, and tells the network it is here (mDNS,
 * `_sideboard-link._tcp`), so the Mac finds this device whatever address the router gave it.
 *
 * A connection starts with four lines from the Mac:
 *
 *     SIDEBOARD-LINK 1
 *     <its token, 32 hex digits>
 *     <its name>
 *     <what it wants: "info", "video <longest side> <bits per second>", "control" or "update <bytes>">
 *
 * and one back: `ok`, or `pairing` followed, once the owner has answered here, by `ok` or
 * `denied`. After `ok`: for `info` one line of JSON; for `video` a line `video <width> <height>`
 * and then H.264 (Annex B) for as long as the Mac listens; for `control` a line `touch on` or
 * `touch off` and then the Mac's messages (see [TouchService]); for `update` the Mac sends that many
 * bytes of a newer copy of this app and gets `installing` back (see [Updater]).
 */
class LinkService : Service() {
    private var server: ServerSocket? = null
    private var registration: NsdManager.RegistrationListener? = null
    @Volatile private var sharing = false
    @Volatile private var lastLight = 0L

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        instance = this
        val notices = getSystemService(NotificationManager::class.java)
        notices.createNotificationChannel(NotificationChannel(WAITING, getString(R.string.channel_waiting), NotificationManager.IMPORTANCE_MIN))
        notices.createNotificationChannel(NotificationChannel(REQUESTS, getString(R.string.channel_requests), NotificationManager.IMPORTANCE_HIGH))
        show(sharing = false)
        Thread(::listen, "link-listen").start()
        Thread({
            // Now, and every minute: the accessibility service back on if Android switched it off.
            while (instance === this) {
                runCatching { Keeper.ensure(this) }
                runCatching { Thread.sleep(60_000) }
            }
        }, "link-keep").start()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int = START_STICKY

    override fun onDestroy() {
        instance = null
        runCatching { server?.close() }
        registration?.let { runCatching { getSystemService(NsdManager::class.java).unregisterService(it) } }
        ScreenCast.release()
        super.onDestroy()
    }

    /** The notification every foreground service must show; it says so while the screen is being watched. */
    fun show(sharing: Boolean) {
        this.sharing = sharing
        val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE)
        val notice = Notification.Builder(this, WAITING)
            .setSmallIcon(android.R.drawable.stat_sys_data_bluetooth)
            .setContentTitle(getString(if (sharing) R.string.notice_sharing else R.string.notice_waiting))
            .setContentIntent(open)
            .setOngoing(true)
            .build()
        if (Build.VERSION.SDK_INT >= 29) {
            // Capturing the screen needs its own kind of foreground service, and only once it has been allowed.
            val kind = if (sharing) {
                ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE or ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION
            } else {
                ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE
            }
            startForeground(1, notice, kind)
        } else {
            startForeground(1, notice)
        }
    }

    private fun listen() {
        val socket = runCatching { ServerSocket(PORT) }.getOrElse { ServerSocket(0) }
        server = socket
        port = socket.localPort
        announce(socket.localPort)
        while (!socket.isClosed) {
            val client = runCatching { socket.accept() }.getOrNull() ?: break
            Thread({ runCatching { serve(client) }; runCatching { client.close() } }, "link-client").start()
        }
        port = 0
    }

    private fun announce(port: Int) {
        val info = NsdServiceInfo().apply {
            serviceName = "Sideboard Link (${Build.MODEL})"
            serviceType = SERVICE_TYPE
            setPort(port)
            setAttribute("v", "1")
            setAttribute("model", Build.MODEL)
            setAttribute("id", deviceId(this@LinkService))
        }
        val listener = object : NsdManager.RegistrationListener {
            override fun onServiceRegistered(info: NsdServiceInfo) {}
            override fun onRegistrationFailed(info: NsdServiceInfo, error: Int) {}
            override fun onServiceUnregistered(info: NsdServiceInfo) {}
            override fun onUnregistrationFailed(info: NsdServiceInfo, error: Int) {}
        }
        registration = listener
        runCatching { getSystemService(NsdManager::class.java).registerService(info, NsdManager.PROTOCOL_DNS_SD, listener) }
    }

    private fun serve(client: Socket) {
        client.tcpNoDelay = true
        client.soTimeout = 10_000
        val input = client.getInputStream()
        val output = client.getOutputStream()
        fun say(line: String) {
            output.write((line + "\n").toByteArray())
            output.flush()
        }
        if (readLine(input) != "SIDEBOARD-LINK 1") return
        val token = readLine(input)?.takeIf { TOKEN.matches(it) } ?: return
        val name = readLine(input)?.filter { !it.isISOControl() }?.take(40)?.ifBlank { null } ?: return
        val wish = readLine(input)?.split(' ') ?: return

        if (!Pairing.isAllowed(this, token)) {
            val request = Pairing.ask(token, name) ?: return say("busy")
            say("pairing")
            askOwner(request)
            val answered = request.answered.await(PAIRING_SECONDS, TimeUnit.SECONDS)
            getSystemService(NotificationManager::class.java).cancel(REQUEST_NOTICE)
            if (!answered) Pairing.drop(request)
            if (!request.allowed) return say("denied")
        }
        say("ok")
        client.soTimeout = 0
        when (wish.firstOrNull()) {
            "info" -> say(info().toString())
            "video" -> ScreenCast.serve(this, client, wish.getOrNull(1)?.toIntOrNull() ?: 1280, wish.getOrNull(2)?.toIntOrNull() ?: 6_000_000)
            "update" -> {
                val size = wish.getOrNull(1)?.toLongOrNull()?.takeIf { it in 1..50_000_000 } ?: return say("refused")
                say(if (Updater.install(this, input, size)) "installing" else "failed")
            }
            "control" -> {
                say(if (TouchService.instance != null) "touch on" else "touch off")
                TouchService.listen(input)
            }
        }
    }

    /** Turns the screen on, as the power button would; the lock screen stays in the way as usual. */
    fun wake() = light(WAKE_SECONDS)

    /**
     * Somebody is using the device from afar. If the screen is off or the lock screen is up,
     * the screen is turned on and kept on for a while after each touch, so there is time to
     * swipe and enter the PIN; Android's own few seconds on the lock screen are not enough for
     * that. Once unlocked, the device's usual screen timeout is left alone.
     */
    fun touched() {
        val now = System.currentTimeMillis()
        if (now - lastLight < 3_000) return
        val power = getSystemService(PowerManager::class.java)
        val locked = getSystemService(KeyguardManager::class.java).isKeyguardLocked
        if (!power.isInteractive || locked) light(WAKE_SECONDS)
    }

    private fun light(seconds: Int) {
        lastLight = System.currentTimeMillis()
        val power = getSystemService(PowerManager::class.java)
        @Suppress("DEPRECATION")
        val lock = power.newWakeLock(PowerManager.SCREEN_BRIGHT_WAKE_LOCK or PowerManager.ACQUIRE_CAUSES_WAKEUP, "sideboard:wake")
        runCatching { lock.acquire(seconds * 1_000L) }
    }

    /** A notification with Allow and Deny; the app's own screen asks the same while it is open. */
    private fun askOwner(request: Pairing.Request) {
        fun answer(allow: Boolean) = PendingIntent.getBroadcast(
            this, if (allow) 1 else 2,
            Intent(this, Receiver::class.java).setAction(if (allow) Receiver.ALLOW else Receiver.DENY),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE)
        val notice = Notification.Builder(this, REQUESTS)
            .setSmallIcon(android.R.drawable.stat_sys_warning)
            .setContentTitle(getString(R.string.pair_title, request.name))
            .setContentText(getString(R.string.pair_body))
            .setContentIntent(open)
            .setAutoCancel(true)
            .addAction(Notification.Action.Builder(null, getString(R.string.allow), answer(true)).build())
            .addAction(Notification.Action.Builder(null, getString(R.string.deny), answer(false)).build())
            .build()
        getSystemService(NotificationManager::class.java).notify(REQUEST_NOTICE, notice)
    }

    private fun info(): JSONObject {
        val size = ScreenCast.screenSize(this)
        return JSONObject()
            .put("id", deviceId(this))
            .put("model", Build.MODEL)
            .put("maker", Build.MANUFACTURER)
            .put("android", Build.VERSION.RELEASE)
            .put("sdk", Build.VERSION.SDK_INT)
            .put("width", size.x)
            .put("height", size.y)
            .put("touch", TouchService.instance != null)
            .put("keeps", Keeper.canKeep(this))
            .put("version", runCatching { packageManager.getPackageInfo(packageName, 0).versionName }.getOrNull() ?: "")
    }

    companion object {
        /** Tried first; any free port otherwise. The Mac learns the real one from the announcement. */
        const val PORT = 47600
        const val SERVICE_TYPE = "_sideboard-link._tcp"
        private const val WAITING = "waiting"
        private const val REQUESTS = "requests"
        private const val REQUEST_NOTICE = 2
        private const val PAIRING_SECONDS = 60L
        /** How long the screen stays on after a touch from afar while the device is locked. */
        private const val WAKE_SECONDS = 30
        private val TOKEN = Regex("[0-9a-f]{32}")

        @Volatile var instance: LinkService? = null
            private set
        /** The port being listened on; 0 while not running. */
        @Volatile var port = 0
            private set

        fun start(context: Context) {
            val intent = Intent(context, LinkService::class.java)
            if (Build.VERSION.SDK_INT >= 26) context.startForegroundService(intent) else context.startService(intent)
        }

        /** Stays the same for this installation, so the Mac knows the device again at a new address. */
        fun deviceId(context: Context): String {
            val store = context.applicationContext.createDeviceProtectedStorageContext().getSharedPreferences("link", Context.MODE_PRIVATE)
            return store.getString("id", null) ?: UUID.randomUUID().toString().also { store.edit().putString("id", it).apply() }
        }

        /** This device's address on the local network, for showing to the owner. */
        fun localAddress(): String? = runCatching {
            NetworkInterface.getNetworkInterfaces().asSequence()
                .filter { it.isUp && !it.isLoopback }
                .flatMap { it.inetAddresses.asSequence() }
                .firstOrNull { it is Inet4Address && it.isSiteLocalAddress }?.hostAddress
        }.getOrNull()

        /** One line, read byte by byte so nothing after it is swallowed. Null at the end of the stream or when it is too long. */
        fun readLine(input: InputStream): String? {
            val bytes = ArrayList<Byte>()
            while (bytes.size < 512) {
                val next = input.read()
                if (next < 0) return null
                if (next == '\n'.code) return String(bytes.toByteArray()).trimEnd('\r')
                bytes.add(next.toByte())
            }
            return null
        }
    }
}
