package com.weijiazhao.sideboard

import android.app.AppOpsManager
import android.app.usage.UsageEvents
import android.app.usage.UsageStatsManager
import android.content.ContentValues
import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
import android.os.Process
import android.os.SystemClock

/**
 * The device's screen, power and app history, kept for [KEEP_DAYS] days. Copied from Android's
 * own usage events a few times a day (Android only keeps those for about a week), plus the exact
 * start-up time noted at boot. Stays on the device; Sideboard reads it over adb.
 */
class History(context: Context) : SQLiteOpenHelper(context, "history.db", null, 1) {

    override fun onCreate(db: SQLiteDatabase) {
        db.execSQL("CREATE TABLE events (time INTEGER NOT NULL, type INTEGER NOT NULL, package TEXT NOT NULL, UNIQUE(time, type, package))")
        db.execSQL("CREATE INDEX events_time ON events(time)")
        db.execSQL("CREATE TABLE meta (key TEXT PRIMARY KEY, value INTEGER NOT NULL)")
    }

    override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) = Unit

    fun add(time: Long, type: Int, packageName: String) {
        writableDatabase.insertWithOnConflict("events", null, ContentValues().apply {
            put("time", time)
            put("type", type)
            put("package", packageName)
        }, SQLiteDatabase.CONFLICT_IGNORE)
    }

    fun meta(key: String): Long? =
        readableDatabase.rawQuery("SELECT value FROM meta WHERE key = ?", arrayOf(key)).use { if (it.moveToFirst()) it.getLong(0) else null }

    fun setMeta(key: String, value: Long) {
        writableDatabase.insertWithOnConflict("meta", null, ContentValues().apply {
            put("key", key)
            put("value", value)
        }, SQLiteDatabase.CONFLICT_REPLACE)
    }

    fun count(): Long = readableDatabase.rawQuery("SELECT COUNT(*) FROM events", null).use { it.moveToFirst(); it.getLong(0) }

    companion object {
        const val KEEP_DAYS = 90L
        private const val DAY = 86_400_000L

        /** Our own type for the start-up time noted at boot; the rest are UsageEvents types. */
        const val BOOTED = 1000
        val TYPES = setOf(
            UsageEvents.Event.ACTIVITY_RESUMED, // 1
            15, // SCREEN_INTERACTIVE
            16, // SCREEN_NON_INTERACTIVE
            26, // DEVICE_SHUTDOWN
            27, // DEVICE_STARTUP
        )

        fun hasUsageAccess(context: Context): Boolean {
            val appOps = context.getSystemService(AppOpsManager::class.java)
            @Suppress("DEPRECATION")
            val mode = appOps.checkOpNoThrow(AppOpsManager.OPSTR_GET_USAGE_STATS, Process.myUid(), context.packageName)
            return mode == AppOpsManager.MODE_ALLOWED
        }

        /** Copies new usage events and forgets old ones. Takes well under a second. */
        @Synchronized
        fun record(context: Context) {
            History(context).use { history ->
                val now = System.currentTimeMillis()
                if (history.meta("since") == null) history.setMeta("since", now)
                if (hasUsageAccess(context)) {
                    // An hour of overlap, in case Android wrote events late; duplicates are ignored.
                    val from = (history.meta("lastRead")?.minus(3_600_000L)) ?: (now - 10 * DAY)
                    val usage = context.getSystemService(UsageStatsManager::class.java)
                    val events = usage.queryEvents(from, now)
                    val event = UsageEvents.Event()
                    val db = history.writableDatabase
                    db.beginTransaction()
                    try {
                        while (events.hasNextEvent()) {
                            events.getNextEvent(event)
                            if (event.eventType in TYPES) history.add(event.timeStamp, event.eventType, event.packageName ?: "")
                        }
                        db.setTransactionSuccessful()
                    } finally {
                        db.endTransaction()
                    }
                    history.setMeta("lastRead", now)
                }
                history.writableDatabase.delete("events", "time < ?", arrayOf((now - KEEP_DAYS * DAY).toString()))
            }
        }

        /** The moment the device started, from the time since boot. */
        fun recordBoot(context: Context) {
            History(context).use { it.add(System.currentTimeMillis() - SystemClock.elapsedRealtime(), BOOTED, "android") }
        }
    }
}
