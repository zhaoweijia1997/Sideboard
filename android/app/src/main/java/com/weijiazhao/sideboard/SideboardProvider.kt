package com.weijiazhao.sideboard

import android.content.ContentProvider
import android.content.ContentValues
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.database.Cursor
import android.database.MatrixCursor
import android.graphics.Bitmap
import android.graphics.Canvas
import android.net.Uri
import android.util.Base64
import java.io.ByteArrayOutputStream

/**
 * What Sideboard reads over adb, for example
 *
 *     content query --uri content://com.weijiazhao.sideboard.provider/events?since=1700000000000
 *
 * Only callers holding DUMP (the adb shell) may read it. Free text comes in the last column, since
 * `content query` prints rows as "name=value, name=value".
 *
 * - info: version, recording since, number of events, whether usage access is allowed
 * - events?since=ms: time, type, package
 * - apps: package, label
 * - icons: package, png (base64, 64 × 64) for apps with a launcher icon and apps you added
 */
class SideboardProvider : ContentProvider() {
    override fun onCreate() = true

    override fun query(uri: Uri, projection: Array<String>?, selection: String?, selectionArgs: Array<String>?, sortOrder: String?): Cursor? {
        val context = context ?: return null
        // Right after Sideboard installs the app nothing has scheduled the job yet; its first read does.
        runCatching { RecordJob.schedule(context) }
        return when (uri.lastPathSegment) {
            "info" -> MatrixCursor(arrayOf("version", "since", "events", "usage_access", "last_read")).apply {
                runCatching { History.record(context) }
                History(context).use { history ->
                    addRow(arrayOf(BuildConfigVersion.name(context), history.meta("since") ?: 0, history.count(),
                        if (History.hasUsageAccess(context)) 1 else 0, history.meta("lastRead") ?: 0))
                }
            }
            "events" -> MatrixCursor(arrayOf("time", "type", "package")).apply {
                // Catch up first, so the newest events are included.
                runCatching { History.record(context) }
                val since = uri.getQueryParameter("since")?.toLongOrNull() ?: 0L
                History(context).use { history ->
                    history.readableDatabase.rawQuery(
                        "SELECT time, type, package FROM events WHERE time >= ? ORDER BY time", arrayOf(since.toString()),
                    ).use { rows -> while (rows.moveToNext()) addRow(arrayOf(rows.getLong(0), rows.getInt(1), rows.getString(2))) }
                }
            }
            "apps" -> MatrixCursor(arrayOf("package", "label")).apply {
                val pm = context.packageManager
                for (app in pm.getInstalledApplications(0)) {
                    addRow(arrayOf(app.packageName, pm.getApplicationLabel(app).toString().replace('\n', ' ')))
                }
            }
            "icons" -> MatrixCursor(arrayOf("package", "png")).apply {
                val pm = context.packageManager
                val launchable = HashSet<String>()
                for (category in listOf(Intent.CATEGORY_LAUNCHER, Intent.CATEGORY_LEANBACK_LAUNCHER)) {
                    pm.queryIntentActivities(Intent(Intent.ACTION_MAIN).addCategory(category), 0)
                        .forEach { launchable.add(it.activityInfo.packageName) }
                }
                for (app in pm.getInstalledApplications(0)) {
                    val added = app.flags and ApplicationInfo.FLAG_SYSTEM == 0
                    if (!added && app.packageName !in launchable) continue
                    runCatching { addRow(arrayOf(app.packageName, png(pm.getApplicationIcon(app)))) }
                }
            }
            else -> null
        }
    }

    private fun png(drawable: android.graphics.drawable.Drawable): String {
        val size = 64
        val bitmap = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        drawable.setBounds(0, 0, size, size)
        drawable.draw(Canvas(bitmap))
        val bytes = ByteArrayOutputStream().use { out ->
            bitmap.compress(Bitmap.CompressFormat.PNG, 100, out)
            out.toByteArray()
        }
        bitmap.recycle()
        return Base64.encodeToString(bytes, Base64.NO_WRAP)
    }

    override fun getType(uri: Uri): String? = null
    override fun insert(uri: Uri, values: ContentValues?): Uri? = null
    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<String>?) = 0
    override fun update(uri: Uri, values: ContentValues?, selection: String?, selectionArgs: Array<String>?) = 0
}

/** The installed version name, without generating BuildConfig. */
object BuildConfigVersion {
    fun name(context: android.content.Context): String =
        runCatching { context.packageManager.getPackageInfo(context.packageName, 0).versionName }.getOrNull() ?: "?"
}
