package app.sideboard.link

import android.app.Activity
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.TypedValue
import android.view.View
import android.view.ViewGroup.LayoutParams.WRAP_CONTENT
import android.widget.Button
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView

/** What the app does, whether it is waiting for the Mac, which Macs are allowed, and a Mac's request while one is waiting. */
class MainActivity : Activity() {
    private lateinit var state: TextView
    private lateinit var touch: TextView
    private lateinit var settings: Button
    private lateinit var macs: TextView
    private lateinit var forget: Button
    private lateinit var request: TextView
    private lateinit var answers: LinearLayout
    private val main = Handler(Looper.getMainLooper())
    private val tick = object : Runnable {
        override fun run() {
            show()
            main.postDelayed(this, 1_000)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val padding = dp(28)
        val column = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(padding, padding, padding, padding)
        }
        column.addView(text(getString(R.string.app_name), 26f))
        column.addView(text(getString(R.string.main_body), 15f).apply { setPadding(0, dp(10), 0, dp(18)) })

        request = text("", 17f)
        answers = LinearLayout(this).apply {
            addView(Button(this@MainActivity).apply {
                text = getString(R.string.allow)
                setOnClickListener { Pairing.answer(this@MainActivity, true); show() }
            })
            addView(Button(this@MainActivity).apply {
                text = getString(R.string.deny)
                setOnClickListener { Pairing.answer(this@MainActivity, false); show() }
            })
        }
        column.addView(request)
        column.addView(answers)

        state = text("", 15f)
        touch = text("", 15f).apply { setPadding(0, dp(8), 0, dp(8)) }
        settings = Button(this).apply {
            text = getString(R.string.open_accessibility)
            setOnClickListener { runCatching { startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)) } }
        }
        macs = text("", 15f).apply { setPadding(0, dp(16), 0, dp(8)) }
        forget = Button(this).apply {
            text = getString(R.string.forget_all)
            setOnClickListener { Pairing.forgetAll(this@MainActivity); show() }
        }
        column.addView(state)
        column.addView(touch)
        column.addView(settings, LinearLayout.LayoutParams(WRAP_CONTENT, WRAP_CONTENT))
        column.addView(macs)
        column.addView(forget, LinearLayout.LayoutParams(WRAP_CONTENT, WRAP_CONTENT))
        setContentView(ScrollView(this).apply { addView(column) })

        if (Build.VERSION.SDK_INT >= 33) requestPermissions(arrayOf(android.Manifest.permission.POST_NOTIFICATIONS), 1)
        runCatching { LinkService.start(this) }
    }

    override fun onResume() {
        super.onResume()
        main.post(tick)
    }

    override fun onPause() {
        main.removeCallbacks(tick)
        super.onPause()
    }

    private fun show() {
        val asking = Pairing.pending
        request.text = asking?.let { getString(R.string.pair_title, it.name) + "\n" + getString(R.string.pair_body) }.orEmpty()
        request.visibility = if (asking != null) View.VISIBLE else View.GONE
        answers.visibility = request.visibility

        val port = LinkService.port
        state.text = if (port > 0) getString(R.string.state_waiting, LinkService.localAddress() ?: "?", port) else getString(R.string.state_stopped)
        val on = TouchService.instance != null
        touch.text = getString(if (on) R.string.touch_on else R.string.touch_off)
        settings.visibility = if (on) View.GONE else View.VISIBLE

        val names = Pairing.names(this)
        macs.text = if (names.isEmpty()) getString(R.string.macs_none) else getString(R.string.macs_title) + "\n" + names.joinToString("\n") { "· $it" }
        forget.visibility = if (names.isEmpty()) View.GONE else View.VISIBLE
    }

    private fun text(value: String, size: Float) = TextView(this).apply {
        text = value
        setTextSize(TypedValue.COMPLEX_UNIT_SP, size)
    }

    private fun dp(value: Int) = (value * resources.displayMetrics.density).toInt()
}
