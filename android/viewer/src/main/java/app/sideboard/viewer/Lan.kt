package app.sideboard.viewer

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import java.net.Socket

/**
 * The Wi-Fi, by name. The device being looked at is on the local network, so connections to
 * it must leave by the Wi-Fi even when this phone's traffic otherwise goes somewhere else: an
 * ordinary connection to a local address would then go that other way and never arrive.
 */
object Lan {
    @Volatile private var wifi: Network? = null
    private var watching = false

    /** Starts keeping track of the Wi-Fi; safe to call again. */
    @Synchronized
    fun watch(context: Context) {
        if (watching) return
        val connectivity = context.applicationContext.getSystemService(ConnectivityManager::class.java)
        runCatching {
            connectivity.registerNetworkCallback(
                NetworkRequest.Builder().addTransportType(NetworkCapabilities.TRANSPORT_WIFI).build(),
                object : ConnectivityManager.NetworkCallback() {
                    override fun onAvailable(network: Network) {
                        wifi = network
                    }

                    override fun onLost(network: Network) {
                        if (wifi == network) wifi = null
                    }
                },
            )
            watching = true
        }
    }

    /** A socket that goes out by the Wi-Fi when there is one; an ordinary socket otherwise. */
    fun socket(): Socket = runCatching { wifi?.socketFactory?.createSocket() }.getOrNull() ?: Socket()
}
