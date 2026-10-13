package app.sideboard.viewer

import android.content.Context
import android.os.Build
import java.io.InputStream
import java.io.OutputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.security.SecureRandom

/**
 * This device's side of a Sideboard Link connection (the other side is android/link's
 * LinkService.kt, which describes what is said). Each thing wanted is a connection of its own:
 * one for the picture, one for touches.
 */
class LinkClient(private val context: Context, private val host: String, private val port: Int) {
    /** What the other device answered instead of letting this one in. */
    class Refused(val answer: String) : Exception(answer)

    class Open(val socket: Socket, val input: InputStream, val output: OutputStream, val line: String)

    /**
     * Connects and asks for [wish]. [asking] is called if the other device first has to ask its
     * owner. Returns the connection with the device's first line about the wish; throws
     * [Refused] with `denied`, `busy` or whatever else came back.
     */
    fun open(wish: String, asking: () -> Unit = {}): Open {
        // By the Wi-Fi, whatever else this phone's traffic goes through.
        Lan.watch(context)
        val socket = Lan.socket()
        try {
            socket.tcpNoDelay = true
            // A connection that dies without a word is noticed in the end.
            socket.keepAlive = true
            socket.connect(InetSocketAddress(host, port), 5_000)
            // Time for the owner of the other device to answer.
            socket.soTimeout = 70_000
            val input = socket.getInputStream()
            val output = socket.getOutputStream()
            output.write("SIDEBOARD-LINK 1\n${token(context)}\n${name()}\n$wish\n".toByteArray())
            output.flush()
            var answer = readLine(input) ?: throw Refused("")
            if (answer == "pairing") {
                asking()
                answer = readLine(input) ?: throw Refused("")
            }
            if (answer != "ok") throw Refused(answer)
            val line = readLine(input) ?: throw Refused("")
            socket.soTimeout = 0
            return Open(socket, input, output, line)
        } catch (error: Exception) {
            runCatching { socket.close() }
            throw error
        }
    }

    companion object {
        const val PORT = 47600
        const val SERVICE_TYPE = "_sideboard-link._tcp"

        /** What the other device shows its owner when asking whether to let this one in. */
        fun name(): String = Build.MODEL.filter { !it.isISOControl() }.take(40).ifBlank { "Android" }

        /** Made up once; what the other device remembers having allowed. */
        fun token(context: Context): String {
            val store = context.getSharedPreferences("link", Context.MODE_PRIVATE)
            store.getString("token", null)?.let { return it }
            val bytes = ByteArray(16).also { SecureRandom().nextBytes(it) }
            val made = bytes.joinToString("") { "%02x".format(it) }
            store.edit().putString("token", made).apply()
            return made
        }

        /** One line, read byte by byte so nothing after it is swallowed. */
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
