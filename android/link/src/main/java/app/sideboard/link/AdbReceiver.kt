package app.sideboard.link

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * `adb shell am broadcast -a app.sideboard.link.PAIR -n app.sideboard.link/.AdbReceiver --es token … --es name …`:
 * a Mac that has this device on adb is trusted with it already, so it may add itself to the
 * allowed Macs without a question on the screen. Only the adb shell can send this (see the manifest).
 */
class AdbReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val token = intent.getStringExtra("token")?.takeIf { Regex("[0-9a-f]{32}").matches(it) } ?: return
        val name = intent.getStringExtra("name")?.filter { !it.isISOControl() }?.take(40)?.ifBlank { null } ?: "Mac"
        Pairing.allow(context, token, name)
        resultCode = 1
        runCatching { LinkService.start(context) }
    }
}
