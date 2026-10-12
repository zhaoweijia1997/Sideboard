package app.sideboard.link

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/** Starts waiting for the Mac when the device starts (before the first unlock too), takes the owner's Allow or Deny from the notification, and hears from Android's installer about an update. */
class Receiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            ALLOW -> Pairing.answer(context, true)
            DENY -> Pairing.answer(context, false)
            INSTALL -> Updater.onStatus(context, intent)
            else -> runCatching { LinkService.start(context) }
        }
    }

    companion object {
        const val ALLOW = "app.sideboard.link.ALLOW"
        const val DENY = "app.sideboard.link.DENY"
        const val INSTALL = "app.sideboard.link.INSTALL"
    }
}
