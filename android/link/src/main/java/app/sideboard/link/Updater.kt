package app.sideboard.link

import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import java.io.InputStream

/**
 * Installs a newer copy of this app sent by the Mac, so an update needs no cable. Android only
 * accepts it if it is signed with the same key as the copy installed, and asks the owner to
 * confirm; with the accessibility service on, [TouchService] presses "Update" there.
 */
object Updater {
    /** Android's "update this app?" is on the screen on the Mac's behalf, until this time. */
    @Volatile var askingUntil = 0L
        private set

    val asking: Boolean get() = System.currentTimeMillis() < askingUntil

    /** Reads [size] bytes of APK from the Mac and hands them to Android's installer. False when they didn't all arrive. */
    fun install(context: Context, input: InputStream, size: Long): Boolean {
        val installer = context.packageManager.packageInstaller
        val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL).apply {
            setAppPackageName(context.packageName)
        }
        val id = installer.createSession(params)
        val session = installer.openSession(id)
        try {
            session.openWrite("update", 0, size).use { out ->
                val buffer = ByteArray(64 * 1024)
                var left = size
                while (left > 0) {
                    val count = input.read(buffer, 0, minOf(left, buffer.size.toLong()).toInt())
                    if (count < 0) {
                        session.abandon()
                        return false
                    }
                    out.write(buffer, 0, count)
                    left -= count
                }
                session.fsync(out)
            }
            val status = PendingIntent.getBroadcast(
                context, 3, Intent(context, Receiver::class.java).setAction(Receiver.INSTALL),
                PendingIntent.FLAG_MUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
            askingUntil = System.currentTimeMillis() + 60_000
            session.commit(status.intentSender)
            return true
        } catch (error: Exception) {
            runCatching { session.abandon() }
            return false
        } finally {
            session.close()
        }
    }

    /** What the installer says next: usually that the owner must confirm, which means opening its question. */
    fun onStatus(context: Context, intent: Intent) {
        if (intent.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE) != PackageInstaller.STATUS_PENDING_USER_ACTION) {
            askingUntil = 0
            return
        }
        @Suppress("DEPRECATION")
        val confirm = intent.getParcelableExtra<Intent>(Intent.EXTRA_INTENT) ?: return
        runCatching { context.startActivity(confirm.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) }
    }
}
