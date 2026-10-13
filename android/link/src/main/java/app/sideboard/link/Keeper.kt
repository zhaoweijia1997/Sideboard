package app.sideboard.link

import android.Manifest
import android.content.ComponentName
import android.content.Context
import android.content.pm.PackageManager
import android.provider.Settings

/**
 * Keeps the accessibility service switched on. Android switches such a service off when its
 * app is updated, crashes or is stopped, and normally only the owner can switch it on again, in
 * Settings. With the one permission Sideboard gives this app over adb when it sets it up
 * (WRITE_SECURE_SETTINGS), the app does that itself; without it, this does nothing.
 */
object Keeper {
    fun canKeep(context: Context): Boolean =
        context.checkSelfPermission(Manifest.permission.WRITE_SECURE_SETTINGS) == PackageManager.PERMISSION_GRANTED

    /** Switches the service on if it is off. True when it is on afterwards, as far as the setting goes. */
    fun ensure(context: Context): Boolean {
        val mine = ComponentName(context, TouchService::class.java)
        val resolver = context.contentResolver
        val listed = Settings.Secure.getString(resolver, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES).orEmpty()
        val on = listed.split(':').any { ComponentName.unflattenFromString(it) == mine }
        if (on) return true
        if (!canKeep(context)) return false
        Journal.note("touch: Android had switched the accessibility service off; switching it back on")
        return runCatching {
            val added = if (listed.isBlank()) mine.flattenToString() else listed + ":" + mine.flattenToString()
            Settings.Secure.putString(resolver, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES, added)
            Settings.Secure.putInt(resolver, Settings.Secure.ACCESSIBILITY_ENABLED, 1)
            true
        }.getOrDefault(false)
    }
}
