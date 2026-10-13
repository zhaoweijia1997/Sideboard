package app.sideboard.link

import android.content.Context
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.Looper

/**
 * Tells the local network this device is here (mDNS, `_sideboard-link._tcp`), and keeps telling
 * it. Said once at start, an announcement goes stale: after the Wi-Fi drops and comes back, the
 * phone's traffic changes its way out, or simply a long while, Android's announcer may stop answering while still
 * believing it is registered. So the announcement is made again whenever the Wi-Fi changes
 * and every few minutes, the old one taken down first (two at once and Android renames the
 * second, and the Mac would take it for another device). Multicast is held open too: with the
 * screen off a phone otherwise stops hearing the questions it is meant to answer.
 */
class Announcer(private val context: Context, private val port: Int) {
    private val nsd = context.getSystemService(NsdManager::class.java)
    private val connectivity = context.getSystemService(ConnectivityManager::class.java)
    private val main = Handler(Looper.getMainLooper())
    private var registered: NsdManager.RegistrationListener? = null
    private var busy = false
    @Volatile private var stopped = false
    private var again = false
    private var multicast: WifiManager.MulticastLock? = null
    @Volatile var wifi = false
        private set
    /** This app's traffic doesn't leave by the Wi-Fi by default: something else has taken over the phone's way out. */
    @Volatile var elsewhere = false
        private set
    /** How the last announcement went, for whoever asks how the device is. */
    @Volatile var last = "not yet"
        private set

    private val wifiWatch = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) {
            wifi = true
            wifiNetwork = network
            Journal.note("wifi: connected ($network)")
            route(defaultNetwork)
            soon()
        }

        override fun onLost(network: Network) {
            wifi = false
            if (wifiNetwork == network) wifiNetwork = null
            Journal.note("wifi: lost ($network)")
        }

        override fun onLinkPropertiesChanged(network: Network, properties: LinkProperties) {
            Journal.note("wifi: address " + properties.linkAddresses.map { it.address }.filterIsInstance<java.net.Inet4Address>().joinToString { it.hostAddress.orEmpty() }.ifEmpty { "none" })
            soon()
        }
    }

    private val defaultWatch = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) = route(network)

        override fun onLost(network: Network) {
            Journal.note("network: the default one is gone ($network)")
        }
    }

    private var wifiNetwork: Network? = null
    private var defaultNetwork: Network? = null

    /** The network this app's traffic leaves by when it doesn't say otherwise: is it the Wi-Fi itself, or something laid over it? */
    @Synchronized
    private fun route(network: Network?) {
        defaultNetwork = network
        val now = network != null && wifiNetwork != null && network != wifiNetwork
        if (now != elsewhere) {
            elsewhere = now
            Journal.note(if (now) "route: this app's traffic no longer leaves by the Wi-Fi itself (network $network, Wi-Fi is $wifiNetwork)" else "route: this app's traffic leaves by the Wi-Fi itself again")
            soon()
        }
    }

    fun start() {
        multicast = runCatching {
            (context.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager).createMulticastLock("sideboard-link").apply {
                setReferenceCounted(false)
                acquire()
            }
        }.onFailure { Journal.note("multicast: couldn't hold it open: ${it.message}") }.getOrNull()
        runCatching {
            connectivity.registerNetworkCallback(NetworkRequest.Builder().addTransportType(NetworkCapabilities.TRANSPORT_WIFI).build(), wifiWatch)
            connectivity.registerDefaultNetworkCallback(defaultWatch)
        }.onFailure { Journal.note("network: can't watch it: ${it.message}") }
        announce()
    }

    fun stop() {
        stopped = true
        main.removeCallbacksAndMessages(null)
        runCatching { connectivity.unregisterNetworkCallback(wifiWatch) }
        runCatching { connectivity.unregisterNetworkCallback(defaultWatch) }
        synchronized(this) { registered }?.let { runCatching { nsd.unregisterService(it) } }
        runCatching { multicast?.release() }
    }

    /** A moment after a change, once: changes come in bursts. */
    private fun soon() {
        main.removeCallbacks(refresh)
        main.postDelayed(refresh, 3_000)
    }

    private val refresh = Runnable { announce() }

    /** Takes the announcement down, if there is one, and makes it afresh. */
    fun announce() {
        val down: NsdManager.RegistrationListener?
        synchronized(this) {
            if (busy) {
                again = true
                return
            }
            busy = true
            down = registered
            registered = null
        }
        if (down == null) register() else if (runCatching { nsd.unregisterService(down) }.isFailure) register()
        // Should Android never answer, don't stay stuck.
        main.postDelayed({ done("timed out") }, 20_000)
    }

    private fun register() {
        if (stopped) return
        val info = NsdServiceInfo().apply {
            serviceName = "Sideboard Link (${Build.MODEL})"
            serviceType = LinkService.SERVICE_TYPE
            setPort(this@Announcer.port)
            setAttribute("v", "1")
            setAttribute("model", Build.MODEL)
            setAttribute("id", LinkService.deviceId(context))
        }
        val listener = object : NsdManager.RegistrationListener {
            override fun onServiceRegistered(info: NsdServiceInfo) {
                synchronized(this@Announcer) { registered = this }
                done("announced as “${info.serviceName}”")
            }

            override fun onRegistrationFailed(info: NsdServiceInfo, error: Int) = done("announcing failed (error $error)")

            // The old one is down: up with the new.
            override fun onServiceUnregistered(info: NsdServiceInfo) = register()
            override fun onUnregistrationFailed(info: NsdServiceInfo, error: Int) = register()
        }
        // Taking the old one down reports to the old listener, which is this same kind of object: it calls register().
        runCatching { nsd.registerService(info, NsdManager.PROTOCOL_DNS_SD, listener) }.onFailure { done("announcing failed: ${it.message}") }
    }

    private fun done(result: String) {
        val more: Boolean
        synchronized(this) {
            if (!busy) return
            busy = false
            more = again
            again = false
        }
        if (result != last) Journal.note("mdns: $result")
        last = result
        if (more) soon()
    }
}
