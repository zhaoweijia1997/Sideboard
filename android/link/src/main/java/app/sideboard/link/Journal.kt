package app.sideboard.link

import android.content.Context
import android.util.Log
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * What happened, a line at a time: connections, the network coming and going, the screen, the
 * announcements, anything that went wrong. Kept on the device (the last few hundred kilobytes,
 * readable before the first unlock too) and handed to a paired Mac that asks for it (`log`),
 * so that "it wouldn't come up last night" can be looked into the next morning, without a cable.
 * Nothing of what is on the screen or typed is ever written here: only that something happened.
 */
object Journal {
    private const val TAG = "SideboardLink"
    private const val MOST = 300_000L
    private val stamp = SimpleDateFormat("MM-dd HH:mm:ss", Locale.US)
    private var file: File? = null
    private var old: File? = null

    @Synchronized
    fun open(context: Context) {
        if (file != null) return
        val folder = context.applicationContext.createDeviceProtectedStorageContext().filesDir
        file = File(folder, "journal.txt")
        old = File(folder, "journal.old.txt")
    }

    @Synchronized
    fun note(text: String) {
        Log.i(TAG, text)
        val file = file ?: return
        runCatching {
            // Two files: when this one is full it becomes the old one, and the old one goes.
            if (file.length() > MOST) {
                old?.delete()
                file.renameTo(old ?: return@runCatching)
            }
            file.appendText("${stamp.format(Date())} $text\n")
        }
    }

    /** Everything kept, oldest first. */
    @Synchronized
    fun text(): String = listOfNotNull(old, file).filter { it.exists() }.joinToString("") { runCatching { it.readText() }.getOrDefault("") }
}
