package app.sideboard.link

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/** Starts waiting for the Mac when the device starts (before the first unlock too), and takes the owner's Allow or Deny from the notification. */
class Receiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            ALLOW -> Pairing.answer(context, true)
            DENY -> Pairing.answer(context, false)
            else -> runCatching { LinkService.start(context) }
        }
    }

    companion object {
        const val ALLOW = "app.sideboard.link.ALLOW"
        const val DENY = "app.sideboard.link.DENY"
    }
}
