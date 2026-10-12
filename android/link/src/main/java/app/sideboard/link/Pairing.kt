package app.sideboard.link

import android.content.Context
import java.util.concurrent.CountDownLatch

/**
 * Which Macs may connect. A Mac makes up a long random token once and sends it with every
 * connection; the first time, the owner is asked on this device, and from then on that token is
 * let in. Kept in storage that can be read before the first unlock after a restart.
 */
object Pairing {
    /** A Mac waiting for an answer on this device. */
    class Request(val token: String, val name: String) {
        val answered = CountDownLatch(1)
        @Volatile var allowed = false
    }

    @Volatile
    var pending: Request? = null
        private set

    private fun store(context: Context) =
        context.applicationContext.createDeviceProtectedStorageContext().getSharedPreferences("macs", Context.MODE_PRIVATE)

    fun isAllowed(context: Context, token: String): Boolean = store(context).contains(token)

    /** Lets a Mac in without asking: it came by adb, which is trust enough. */
    fun allow(context: Context, token: String, name: String) {
        store(context).edit().putString(token, name).apply()
    }

    /** The names of the Macs allowed so far. */
    fun names(context: Context): List<String> = store(context).all.values.map { it.toString() }.sorted()

    fun forgetAll(context: Context) {
        store(context).edit().clear().apply()
    }

    /**
     * Puts the question to the owner. The same Mac asking again (its picture and its touches
     * connect separately, and it retries) joins the question already asked; null when another
     * Mac is waiting.
     */
    @Synchronized
    fun ask(token: String, name: String): Request? {
        val waiting = pending
        if (waiting != null) return waiting.takeIf { it.token == token }
        return Request(token, name).also { pending = it }
    }

    /** The owner's answer, from the notification or the app's screen. */
    @Synchronized
    fun answer(context: Context, allow: Boolean) {
        val request = pending ?: return
        if (allow) store(context).edit().putString(request.token, request.name).apply()
        request.allowed = allow
        pending = null
        request.answered.countDown()
    }

    /** Nobody answered in time: that counts as no, for everyone waiting on it. */
    @Synchronized
    fun drop(request: Request) {
        if (pending === request) pending = null
        request.answered.countDown()
    }
}
