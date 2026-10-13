package app.sideboard.link

import android.app.KeyguardManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ServiceInfo
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
    private var announcer: Announcer? = null
    private val started = System.currentTimeMillis()
    /** The screen going on and off, the device dozing, the charger: written down as they happen. */
    private val events = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            Journal.note(
                when (intent.action) {
                    Intent.ACTION_SCREEN_ON -> "screen: on"
                    Intent.ACTION_SCREEN_OFF -> "screen: off"
                    Intent.ACTION_USER_PRESENT -> "screen: unlocked"
                    Intent.ACTION_POWER_CONNECTED -> "power: plugged in"
                    Intent.ACTION_POWER_DISCONNECTED -> "power: unplugged"
                    PowerManager.ACTION_DEVICE_IDLE_MODE_CHANGED ->
                        if (getSystemService(PowerManager::class.java).isDeviceIdleMode) "doze: the device went into deep sleep" else "doze: the device came out of deep sleep"
                    else -> intent.action.orEmpty()
                },
            )
        }
    }
    @Volatile private var sharing = false
    @Volatile private var lastLight = 0L

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        instance = this
        Journal.open(this)
        Journal.note("service: started (version ${version()}, Android ${Build.VERSION.RELEASE})")
        registerReceiver(events, IntentFilter().apply {
            addAction(Intent.ACTION_SCREEN_ON); addAction(Intent.ACTION_SCREEN_OFF); addAction(Intent.ACTION_USER_PRESENT)
            addAction(Intent.ACTION_POWER_CONNECTED); addAction(Intent.ACTION_POWER_DISCONNECTED)
            addAction(PowerManager.ACTION_DEVICE_IDLE_MODE_CHANGED)
        })
        val notices = getSystemService(NotificationManager::class.java)
        notices.createNotificationChannel(NotificationChannel(WAITING, getString(R.string.channel_waiting), NotificationManager.IMPORTANCE_MIN))
        notices.createNotificationChannel(NotificationChannel(REQUESTS, getString(R.string.channel_requests), NotificationManager.IMPORTANCE_HIGH))
        show(sharing = false)
        Thread(::listen, "link-listen").start()
        Thread({
            // Now, and every minute: the accessibility service back on if Android switched it off.
            // Every ten: a line to say this is still running, and the announcement made afresh.
            var minutes = 0
            while (instance === this) {
                runCatching { Keeper.ensure(this) }
                if (minutes > 0 && minutes % 10 == 0) {
                    Journal.note("alive: ${state()}")
                    announcer?.announce()
                }
                minutes++
                runCatching { Thread.sleep(60_000) }
            }
        }, "link-keep").start()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int = START_STICKY

    override fun onDestroy() {
        instance = null
        Journal.note("service: stopping")
        runCatching { unregisterReceiver(events) }
        runCatching { server?.close() }
        announcer?.stop()
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
        val socket = runCatching { ServerSocket(PORT) }.getOrElse {
            Journal.note("listen: port $PORT is taken (${it.message}); using any free one")
            ServerSocket(0)
        }
        server = socket
        port = socket.localPort
        Journal.note("listen: on port ${socket.localPort}, address ${localAddress() ?: "none yet"}")
        announcer = Announcer(this, socket.localPort).also { it.start() }
        while (!socket.isClosed) {
            val client = runCatching { socket.accept() }.onFailure { Journal.note("listen: stopped accepting: ${it.message}") }.getOrNull() ?: break
            Thread({
                val from = client.inetAddress?.hostAddress.orEmpty()
                val began = System.currentTimeMillis()
                val what = arrayOf("nothing said")
                val how = runCatching { serve(client, from, what) }.fold({ it }, { "ended with ${it.javaClass.simpleName}: ${it.message}" })
                runCatching { client.close() }
                // A look at how the device is ("info") comes every few seconds from a Mac that is watching: not worth a line each.
                if (what[0] != "info") Journal.note("from $from: ${what[0]} → $how (${(System.currentTimeMillis() - began) / 1000} s)")
            }, "link-client").start()
        }
        port = 0
    }

    /** Serves one connection; says what was asked in [what] and returns how it ended. */
    private fun serve(client: Socket, from: String, what: Array<String>): String {
        client.tcpNoDelay = true
        // A connection that dies without a word (the other side asleep, or gone from the network) is noticed in the end.
        client.keepAlive = true
        client.soTimeout = 10_000
        val input = client.getInputStream()
        val output = client.getOutputStream()
        fun say(line: String) {
            output.write((line + "\n").toByteArray())
            output.flush()
        }
        if (readLine(input) != "SIDEBOARD-LINK 1") return "not one of ours"
        val token = readLine(input)?.takeIf { TOKEN.matches(it) } ?: return "no token"
        val name = readLine(input)?.filter { !it.isISOControl() }?.take(40)?.ifBlank { null } ?: return "no name"
        val wish = readLine(input)?.split(' ') ?: return "no wish"
        what[0] = "“$name” wants ${wish.joinToString(" ")}".let { if (wish.firstOrNull() == "info") "info" else it }

        if (!Pairing.isAllowed(this, token)) {
            val request = Pairing.ask(token, name) ?: return "busy: another is waiting to be allowed".also { say("busy") }
            say("pairing")
            askOwner(request)
            val answered = request.answered.await(PAIRING_SECONDS, TimeUnit.SECONDS)
            getSystemService(NotificationManager::class.java).cancel(REQUEST_NOTICE)
            if (!answered) Pairing.drop(request)
            if (!request.allowed) {
                say("denied")
                what[0] = "“$name” (not allowed yet) wants ${wish.joinToString(" ")}"
                return if (answered) "denied by the owner" else "nobody answered on the device"
            }
        }
        say("ok")
        client.soTimeout = 0
        return when (wish.firstOrNull()) {
            "info" -> "answered".also { say(info().toString()) }
            // The journal, for looking into what went wrong: its length, then its text.
            "log" -> {
                val text = Journal.text().toByteArray()
                say("log ${text.size}")
                output.write(text)
                output.flush()
                "sent ${text.size / 1024} KB"
            }
            "video" -> ScreenCast.serve(this, client, "“$name” at $from", wish.getOrNull(1)?.toIntOrNull() ?: 1280, wish.getOrNull(2)?.toIntOrNull() ?: 6_000_000)
            "update" -> {
                val size = wish.getOrNull(1)?.toLongOrNull()?.takeIf { it in 1..50_000_000 } ?: return "refused".also { say("refused") }
                val took = Updater.install(this, input, size)
                say(if (took) "installing" else "failed")
                if (took) "installing" else "failed"
            }
            "control" -> {
                say(if (TouchService.instance != null) "touch on" else "touch off")
                TouchService.listen(input)
                "hung up"
            }
            else -> "nothing this version knows"
        }
    }

    private fun version(): String = runCatching { packageManager.getPackageInfo(packageName, 0).versionName }.getOrNull() ?: ""

    /** How the device is, in a line: for the journal now and then, and for whoever asks. */
    private fun state(): String {
        val power = getSystemService(PowerManager::class.java)
        val locked = getSystemService(KeyguardManager::class.java).isKeyguardLocked
        return "screen ${if (power.isInteractive) "on" else "off"}${if (locked) ", locked" else ""}, " +
            "${if (power.isDeviceIdleMode) "dozing, " else ""}wifi ${if (announcer?.wifi == true) "up" else "down"}, " +
            "${if (announcer?.elsewhere == true) "other traffic not by wifi, " else ""}address ${localAddress() ?: "none"}, ${ScreenCast.watching} watching, " +
            "touch ${if (TouchService.instance != null) "on" else "off"}, mdns ${announcer?.last ?: "not started"}"
    }

    /** Turns the screen on, as the power button would; the lock screen stays in the way as usual. */
    fun wake() = light(WAKE_SECONDS)

    /** Somebody is about to watch: the screen on if it is off, and a moment for it to come on. */
    fun wakeToBeSeen() {
        if (getSystemService(PowerManager::class.java).isInteractive) return
        light(WAKE_SECONDS)
        runCatching { Thread.sleep(700) }
    }

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
        val was = power.isInteractive
        @Suppress("DEPRECATION")
        val lock = power.newWakeLock(PowerManager.SCREEN_BRIGHT_WAKE_LOCK or PowerManager.ACQUIRE_CAUSES_WAKEUP, "sideboard:wake")
        val asked = runCatching { lock.acquire(seconds * 1_000L) }
        // Only worth a line when the screen was off: did it come on?
        if (!was) {
            Thread({
                runCatching { Thread.sleep(1_500) }
                Journal.note("wake: the screen was off; asked for it on (${asked.exceptionOrNull()?.message ?: "ok"}); now ${if (power.isInteractive) "on" else "STILL OFF"}")
            }, "link-wake").start()
        }
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
            .put("version", version())
            .put("up", (System.currentTimeMillis() - started) / 1000)
            // Where to find this device again should its announcement go quiet.
            .put("address", localAddress() ?: "")
            .put("port", port)
            .put("state", state())
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
