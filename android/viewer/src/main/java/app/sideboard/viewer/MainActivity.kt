package app.sideboard.viewer

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiManager
import android.os.Bundle
import android.text.InputType
import android.util.TypedValue
import android.view.ViewGroup.LayoutParams.MATCH_PARENT
import android.view.ViewGroup.LayoutParams.WRAP_CONTENT
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import java.net.Inet4Address
import java.net.NetworkInterface

/** The devices on this network that run Sideboard Link, and a field for an address. A tap opens the device's screen. */
class MainActivity : Activity() {
    private class Found(val name: String, val host: String, val port: Int)

    private lateinit var list: LinearLayout
    private lateinit var none: TextView
    private val found = LinkedHashMap<String, Found>()
    private val waiting = ArrayDeque<NsdServiceInfo>()
    private var resolving = false
    private var discovery: NsdManager.DiscoveryListener? = null
    private var multicast: WifiManager.MulticastLock? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val padding = dp(24)
        val column = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(padding, padding, padding, padding)
        }
        column.addView(text(getString(R.string.app_name), 26f))
        column.addView(text(getString(R.string.main_body), 15f).apply { setPadding(0, dp(10), 0, dp(18)) })
        column.addView(text(getString(R.string.found_title), 17f))
        none = text(getString(R.string.found_none), 15f).apply { setPadding(0, dp(8), 0, dp(8)) }
        column.addView(none)
        list = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        column.addView(list, LinearLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT))

        val address = EditText(this).apply {
            hint = getString(R.string.address_hint)
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_URI
            setSingleLine()
        }
        column.addView(address, LinearLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT).apply { topMargin = dp(20) })
        column.addView(Button(this).apply {
            text = getString(R.string.connect)
            setOnClickListener {
                val typed = address.text.toString().trim()
                if (typed.isEmpty()) return@setOnClickListener
                val host = typed.substringBefore(':')
                val port = typed.substringAfter(':', "").toIntOrNull() ?: LinkClient.PORT
                open(Found(host, host, port))
            }
        }, LinearLayout.LayoutParams(WRAP_CONTENT, WRAP_CONTENT))
        setContentView(ScrollView(this).apply { addView(column) })
    }

    override fun onStart() {
        super.onStart()
        found.clear()
        show()
        // Without this lock some phones don't hear the announcements at all.
        multicast = (applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager).createMulticastLock("viewer").apply {
            setReferenceCounted(false)
            runCatching { acquire() }
        }
        val listener = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(type: String) {}
            override fun onDiscoveryStopped(type: String) {}
            override fun onStartDiscoveryFailed(type: String, error: Int) {}
            override fun onStopDiscoveryFailed(type: String, error: Int) {}
            override fun onServiceFound(info: NsdServiceInfo) = runOnUiThread {
                waiting.addLast(info)
                resolveNext()
            }

            override fun onServiceLost(info: NsdServiceInfo) = runOnUiThread {
                found.remove(info.serviceName)
                show()
            }
        }
        discovery = listener
        runCatching { getSystemService(NsdManager::class.java).discoverServices(LinkClient.SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, listener) }
    }

    override fun onStop() {
        discovery?.let { runCatching { getSystemService(NsdManager::class.java).stopServiceDiscovery(it) } }
        discovery = null
        runCatching { multicast?.release() }
        waiting.clear()
        resolving = false
        super.onStop()
    }

    /** Android looks up one announcement's address at a time. */
    private fun resolveNext() {
        if (resolving) return
        val next = waiting.removeFirstOrNull() ?: return
        resolving = true
        @Suppress("DEPRECATION")
        getSystemService(NsdManager::class.java).resolveService(next, object : NsdManager.ResolveListener {
            override fun onResolveFailed(info: NsdServiceInfo, error: Int) = runOnUiThread {
                resolving = false
                resolveNext()
            }

            override fun onServiceResolved(info: NsdServiceInfo) = runOnUiThread {
                @Suppress("DEPRECATION")
                val host = info.host?.hostAddress
                // This device may run Sideboard Link too; it isn't offered to itself.
                if (host != null && host !in ownAddresses()) {
                    found[info.serviceName] = Found(deviceName(info.serviceName), host, info.port)
                    show()
                }
                resolving = false
                resolveNext()
            }
        })
    }

    private fun show() {
        list.removeAllViews()
        none.visibility = if (found.isEmpty()) android.view.View.VISIBLE else android.view.View.GONE
        for (device in found.values) {
            list.addView(Button(this).apply {
                text = "${device.name}\n${device.host}"
                isAllCaps = false
                setOnClickListener { open(device) }
            }, LinearLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT))
        }
    }

    private fun open(device: Found) {
        startActivity(
            Intent(this, ViewerActivity::class.java)
                .putExtra(ViewerActivity.HOST, device.host)
                .putExtra(ViewerActivity.PORT, device.port)
                .putExtra(ViewerActivity.NAME, device.name),
        )
    }

    /** "Sideboard Link (Pixel XL)" announces a Pixel XL. */
    private fun deviceName(service: String): String {
        val open = service.indexOf('(')
        val close = service.lastIndexOf(')')
        return if (open in 0 until close) service.substring(open + 1, close) else service
    }

    private fun ownAddresses(): Set<String> = runCatching {
        NetworkInterface.getNetworkInterfaces().asSequence()
            .flatMap { it.inetAddresses.asSequence() }
            .filterIsInstance<Inet4Address>()
            .mapNotNull { it.hostAddress }
            .toSet()
    }.getOrDefault(emptySet())

    private fun text(value: String, size: Float) = TextView(this).apply {
        text = value
        setTextSize(TypedValue.COMPLEX_UNIT_SP, size)
    }

    private fun dp(value: Int) = (value * resources.displayMetrics.density).toInt()
}
