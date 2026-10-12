package app.sideboard.viewer

import android.app.Activity
import android.app.AlertDialog
import android.graphics.Color
import android.media.MediaCodec
import android.media.MediaFormat
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import android.util.TypedValue
import android.view.Gravity
import android.view.MotionEvent
import android.view.Surface
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.View
import android.view.ViewGroup.LayoutParams.MATCH_PARENT
import android.view.ViewGroup.LayoutParams.WRAP_CONTENT
import android.view.WindowManager
import android.widget.Button
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import java.io.InputStream
import java.io.OutputStream
import java.net.Socket

/**
 * Another device's screen, live, and a finger on it: touches on the picture here are touches
 * there. Two connections: one brings the picture (H.264, decoded straight onto the screen),
 * the other takes touches, the three navigation buttons and typed text. Both come back by
 * themselves when they drop; the other device ends the picture whenever its screen is turned.
 */
class ViewerActivity : Activity(), SurfaceHolder.Callback {
    private lateinit var client: LinkClient
    private lateinit var frame: FrameLayout
    private lateinit var picture: SurfaceView
    private lateinit var status: TextView
    private val sender = HandlerThread("viewer-touch").apply { start() }
    private val send = Handler(sender.looper)
    @Volatile private var running = false
    @Volatile private var surface: Surface? = null
    @Volatile private var videoSocket: Socket? = null
    @Volatile private var controlSocket: Socket? = null
    @Volatile private var control: OutputStream? = null
    private var videoWidth = 0
    private var videoHeight = 0

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        client = LinkClient(this, intent.getStringExtra(HOST) ?: "", intent.getIntExtra(PORT, LinkClient.PORT))

        picture = SurfaceView(this)
        picture.holder.addCallback(this)
        picture.setOnTouchListener { view, event -> touched(view, event) }
        status = TextView(this).apply {
            setTextColor(Color.WHITE)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 16f)
            gravity = Gravity.CENTER
            setBackgroundColor(0xAA000000.toInt())
            val padding = dp(16)
            setPadding(padding, padding, padding, padding)
        }
        frame = FrameLayout(this).apply {
            setBackgroundColor(Color.BLACK)
            addView(picture, FrameLayout.LayoutParams(MATCH_PARENT, MATCH_PARENT, Gravity.CENTER))
            addView(status, FrameLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT, Gravity.CENTER))
            addOnLayoutChangeListener { _, _, _, _, _, _, _, _, _ -> post { fit() } }
        }
        val bar = LinearLayout(this).apply {
            setBackgroundColor(Color.BLACK)
            for ((label, key) in listOf(R.string.back to 0, R.string.home to 1, R.string.recents to 2)) {
                addView(button(label) { sendControl(byteArrayOf(3, key.toByte())) }, LinearLayout.LayoutParams(0, WRAP_CONTENT, 1f))
            }
            addView(button(R.string.type) { askText() }, LinearLayout.LayoutParams(0, WRAP_CONTENT, 1f))
            // The other device's power button, in two halves: screen on (its lock screen stays), and lock.
            addView(button(R.string.wake) { sendControl(byteArrayOf(3, 6)) }, LinearLayout.LayoutParams(0, WRAP_CONTENT, 1f))
            addView(button(R.string.lock) { sendControl(byteArrayOf(3, 5)) }, LinearLayout.LayoutParams(0, WRAP_CONTENT, 1f))
        }
        setContentView(LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            addView(frame, LinearLayout.LayoutParams(MATCH_PARENT, 0, 1f))
            addView(bar, LinearLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT))
        })
        title = intent.getStringExtra(NAME)
        say(getString(R.string.state_connecting))
    }

    override fun onStart() {
        super.onStart()
        running = true
        Thread(::watch, "viewer-picture").start()
        Thread(::keepControl, "viewer-control").start()
    }

    override fun onStop() {
        running = false
        runCatching { videoSocket?.close() }
        runCatching { controlSocket?.close() }
        control = null
        super.onStop()
    }

    override fun onDestroy() {
        sender.quitSafely()
        super.onDestroy()
    }

    override fun surfaceCreated(holder: SurfaceHolder) {
        surface = holder.surface
    }

    override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {}

    override fun surfaceDestroyed(holder: SurfaceHolder) {
        surface = null
        // The decoder draws on it: end this round, and start over when there is a surface again.
        runCatching { videoSocket?.close() }
    }

    // MARK: The picture

    /** Asks for the picture and shows it, again and again until the screen is left. */
    private fun watch() {
        while (running) {
            val target = surface
            if (target == null) {
                Thread.sleep(100)
                continue
            }
            try {
                val open = client.open("video 1600 8000000") { say(getString(R.string.state_asking, LinkClient.name())) }
                videoSocket = open.socket
                val parts = open.line.split(' ')
                if (parts.firstOrNull() != "video") {
                    say(getString(R.string.state_refused))
                    runCatching { open.socket.close() }
                    pause(3_000)
                    continue
                }
                val width = parts.getOrNull(1)?.toIntOrNull() ?: 720
                val height = parts.getOrNull(2)?.toIntOrNull() ?: 1280
                Log.i(TAG, "picture $width x $height")
                runOnUiThread {
                    videoWidth = width
                    videoHeight = height
                    fit()
                }
                // Reads give up after a moment, which is how a quiet stream is noticed.
                open.socket.soTimeout = QUIET
                decode(open.input, target, width, height)
            } catch (refused: LinkClient.Refused) {
                when (refused.answer) {
                    "denied" -> {
                        say(getString(R.string.state_denied))
                        pause(5_000)
                    }
                    "busy" -> {
                        say(getString(R.string.state_busy))
                        pause(3_000)
                    }
                    else -> lost()
                }
            } catch (_: Exception) {
                lost()
            } finally {
                runCatching { videoSocket?.close() }
            }
        }
    }

    private fun lost() {
        if (!running) return
        Log.i(TAG, "picture lost")
        say(getString(R.string.state_lost))
        pause(1_000)
    }

    private fun pause(milliseconds: Long) {
        val until = System.currentTimeMillis() + milliseconds
        while (running && System.currentTimeMillis() < until) Thread.sleep(100)
    }

    /**
     * Reads the stream, cuts it into its units (each starts with 00 00 01) and gives them to the
     * decoder, which draws on the surface. A unit is whole when the next one starts; when the
     * stream has been quiet for a moment, the open one counts as whole too (the other device sends
     * whole pictures at a time), so the last picture of a movement isn't held back.
     */
    private fun decode(input: InputStream, target: Surface, width: Int, height: Int) {
        val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, width, height)
        if (Build.VERSION.SDK_INT >= 30) format.setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
        val decoder = MediaCodec.createDecoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
        try {
            decoder.configure(format, target, null, 0)
            decoder.start()
            val info = MediaCodec.BufferInfo()
            var shown = false
            fun give(unit: ByteArray, from: Int, to: Int) {
                if (to - from < 4) return
                val kind = unit[from + 3].toInt() and 0x1F
                val flags = if (kind == 7 || kind == 8) MediaCodec.BUFFER_FLAG_CODEC_CONFIG else 0
                var index = decoder.dequeueInputBuffer(20_000)
                while (index < 0 && running) index = decoder.dequeueInputBuffer(20_000)
                if (index < 0) return
                val buffer = decoder.getInputBuffer(index) ?: return
                buffer.clear()
                buffer.put(unit, from, to - from)
                decoder.queueInputBuffer(index, 0, to - from, System.nanoTime() / 1_000, flags)
                while (true) {
                    val out = decoder.dequeueOutputBuffer(info, 0)
                    if (out < 0) break
                    decoder.releaseOutputBuffer(out, true)
                    if (!shown) {
                        shown = true
                        say(null)
                    }
                }
            }

            var data = ByteArray(1 shl 20)
            var length = 0
            // Where the open unit starts (at its start code), or -1 before the first one.
            var open = -1
            var searched = 0
            while (running) {
                if (length == data.size) data = data.copyOf(data.size * 2)
                val count = try {
                    input.read(data, length, data.size - length)
                } catch (_: java.net.SocketTimeoutException) {
                    // Quiet for a moment: what is open is a whole unit.
                    if (open >= 0 && length - open > 4) {
                        give(data, open, length)
                        length = 0
                        open = -1
                        searched = 0
                    }
                    continue
                }
                if (count < 0) break
                length += count
                var at = maxOf(searched, 0)
                while (at + 2 < length) {
                    if (data[at + 2] > 1) {
                        at += 3
                    } else if (data[at + 2].toInt() == 1 && data[at + 1].toInt() == 0 && data[at].toInt() == 0) {
                        if (open >= 0) give(data, open, at)
                        open = at
                        at += 3
                    } else {
                        at++
                    }
                }
                searched = maxOf(length - 2, 0)
                if (open > 0) {
                    // Keep only the open unit.
                    System.arraycopy(data, open, data, 0, length - open)
                    length -= open
                    searched = maxOf(searched - open, 0)
                    open = 0
                } else if (open < 0 && length > 3) {
                    // Not at a start code: the rest of a unit that was cut short. Start over for a clean picture.
                    return
                }
            }
        } finally {
            runCatching { decoder.stop() }
            runCatching { decoder.release() }
        }
    }

    /** The picture keeps its shape inside the space there is. */
    private fun fit() {
        if (videoWidth == 0 || videoHeight == 0 || frame.width == 0 || frame.height == 0) return
        val scale = minOf(frame.width.toFloat() / videoWidth, frame.height.toFloat() / videoHeight)
        val width = (videoWidth * scale).toInt()
        val height = (videoHeight * scale).toInt()
        val params = picture.layoutParams as FrameLayout.LayoutParams
        if (params.width != width || params.height != height) {
            params.width = width
            params.height = height
            picture.layoutParams = params
        }
    }

    // MARK: Touches

    /** Keeps a connection for touches open. */
    private fun keepControl() {
        while (running) {
            try {
                val open = client.open("control")
                controlSocket = open.socket
                control = open.output
                if (open.line == "touch off") say(getString(R.string.state_touch_off))
                // Nothing comes back on this connection; reading tells when it ends.
                while (running && open.input.read() >= 0) { /* wait */ }
            } catch (_: Exception) {
                // The picture's connection reports trouble; this one just tries again.
            } finally {
                control = null
                runCatching { controlSocket?.close() }
            }
            pause(1_500)
        }
    }

    private fun sendControl(message: ByteArray) {
        send.post {
            val out = control ?: return@post
            runCatching {
                out.write(message)
                out.flush()
            }.onFailure { runCatching { controlSocket?.close() } }
        }
    }

    /** A finger on the picture: where it is, as fractions of the picture, to the other device. */
    private fun touched(view: View, event: MotionEvent): Boolean {
        if (view.width == 0 || view.height == 0) return false
        val kind = when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> 0
            MotionEvent.ACTION_MOVE -> 1
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> 2
            else -> return true
        }
        val x = (event.x / view.width).coerceIn(0f, 1f)
        val y = (event.y / view.height).coerceIn(0f, 1f)
        val across = (x * 65535).toInt()
        val down = (y * 65535).toInt()
        sendControl(byteArrayOf(kind.toByte(), (across shr 8).toByte(), across.toByte(), (down shr 8).toByte(), down.toByte()))
        return true
    }

    private fun askText() {
        val field = EditText(this).apply { hint = getString(R.string.type_hint) }
        AlertDialog.Builder(this)
            .setTitle(R.string.type_title)
            .setView(field)
            .setPositiveButton(R.string.send) { _, _ ->
                val bytes = field.text.toString().toByteArray().take(60_000).toByteArray()
                if (bytes.isNotEmpty()) {
                    sendControl(byteArrayOf(4, (bytes.size shr 8).toByte(), bytes.size.toByte()) + bytes)
                }
            }
            .setNegativeButton(R.string.cancel, null)
            .show()
    }

    // MARK: Small things

    /** A line over the picture, or none once the picture is there. */
    private fun say(text: String?) = runOnUiThread {
        status.text = text.orEmpty()
        status.visibility = if (text == null) View.GONE else View.VISIBLE
    }

    private fun button(label: Int, action: () -> Unit) = Button(this).apply {
        text = getString(label)
        isAllCaps = false
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f)
        setPadding(0, paddingTop, 0, paddingBottom)
        maxLines = 1
        setOnClickListener { action() }
    }

    private fun dp(value: Int) = (value * resources.displayMetrics.density).toInt()

    companion object {
        private const val TAG = "SideboardViewer"
        /** Milliseconds without anything arriving after which the stream counts as quiet. */
        private const val QUIET = 25
        const val HOST = "host"
        const val PORT = "port"
        const val NAME = "name"
    }
}
