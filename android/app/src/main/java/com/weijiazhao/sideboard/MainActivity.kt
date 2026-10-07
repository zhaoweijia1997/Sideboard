package com.weijiazhao.sideboard

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import android.provider.Settings
import android.text.format.DateFormat
import android.util.TypedValue
import android.view.Gravity
import android.view.ViewGroup.LayoutParams.MATCH_PARENT
import android.view.ViewGroup.LayoutParams.WRAP_CONTENT
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import java.util.Date

/** What this app does and whether it's recording, on the device itself. Works with a TV remote. */
class MainActivity : Activity() {
    private lateinit var status: TextView
    private lateinit var access: TextView
    private lateinit var settings: Button

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val padding = dp(32)
        val column = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(padding, padding, padding, padding)
        }
        column.addView(text(getString(R.string.app_name), 28f))
        column.addView(text(getString(R.string.main_body), 16f).apply { setPadding(0, dp(12), 0, dp(20)) })
        status = text("", 16f)
        access = text("", 16f).apply { setPadding(0, dp(8), 0, dp(8)) }
        column.addView(status)
        column.addView(access)
        settings = Button(this).apply {
            text = getString(R.string.open_settings)
            setOnClickListener { runCatching { startActivity(Intent(Settings.ACTION_USAGE_ACCESS_SETTINGS)) } }
        }
        column.addView(settings, LinearLayout.LayoutParams(WRAP_CONTENT, WRAP_CONTENT))
        column.addView(EditText(this).apply {
            hint = getString(R.string.test_field)
            setPadding(dp(12), dp(16), dp(12), dp(16))
        }, LinearLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT).apply { topMargin = dp(24) })
        setContentView(ScrollView(this).apply { addView(column) })

        RecordJob.schedule(this)
    }

    override fun onResume() {
        super.onResume()
        Thread {
            runCatching { History.record(applicationContext) }
            val (since, count) = History(applicationContext).use { (it.meta("since") ?: 0L) to it.count() }
            val allowed = History.hasUsageAccess(applicationContext)
            runOnUiThread { show(since, count, allowed) }
        }.start()
    }

    private fun show(since: Long, count: Long, allowed: Boolean) {
        val date = DateFormat.getMediumDateFormat(this).format(Date(since))
        status.text = getString(R.string.status, date, count)
        access.text = getString(if (allowed) R.string.access_allowed else R.string.access_missing)
        settings.visibility = if (allowed) android.view.View.GONE else android.view.View.VISIBLE
    }

    private fun text(value: String, size: Float) = TextView(this).apply {
        text = value
        setTextSize(TypedValue.COMPLEX_UNIT_SP, size)
        gravity = Gravity.START
    }

    private fun dp(value: Int) = (value * resources.displayMetrics.density).toInt()
}
