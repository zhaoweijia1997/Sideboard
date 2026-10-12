package app.sideboard.link

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.graphics.Path
import android.graphics.PointF
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import java.io.DataInputStream
import java.io.InputStream

/**
 * Turns the Mac's messages into touches. Each message starts with one byte saying what it is:
 *
 *     0 finger down, 1 finger moved, 2 finger up:  x, y (two bytes each, 0…65535 across and down the screen)
 *     3 a key:  one byte (0 Back, 1 Home, 2 Recents, 3 notifications, 4 quick settings, 5 lock the screen, 6 wake the screen)
 *     4 text:   its length in bytes (two bytes), then UTF-8; "\n" is Return and "\u0008" deletes backwards
 *     5 scroll: x, y, then how far across and down (two signed bytes each, same scale as x and y)
 *
 * A drag is one gesture that keeps being continued, so the finger follows the mouse while it
 * moves. Android runs one piece of a gesture at a time; moves that arrive meanwhile are joined
 * into the next piece.
 *
 * It also answers Android's "start capturing the screen?" when that was asked on the Mac's
 * behalf ([ScreenCast.asking]), so the device needn't be touched.
 */
class TouchService : AccessibilityService() {
    private val main = Handler(Looper.getMainLooper())
    private var stroke: GestureDescription.StrokeDescription? = null
    private var last = PointF()
    private var busy = false
    private var nextMove: PointF? = null
    private var lift = false

    override fun onServiceConnected() {
        instance = this
        // The owner turned this on: make sure the Mac is being waited for.
        LinkService.start(this)
    }

    override fun onUnbind(intent: android.content.Intent?): Boolean {
        instance = null
        return super.onUnbind(intent)
    }

    override fun onInterrupt() {}

    override fun onAccessibilityEvent(event: AccessibilityEvent) {
        val from = event.packageName?.toString() ?: return
        // Android's "update this app?", when the Mac sent the update: its Update button.
        if (Updater.asking && from.endsWith("packageinstaller")) {
            val root = rootInActiveWindow ?: return
            val confirm = (root.findAccessibilityNodeInfosByViewId("$from:id/ok_button") + root.findAccessibilityNodeInfosByViewId("android:id/button1"))
                .firstOrNull { it.isClickable && it.isEnabled }
            confirm?.performAction(AccessibilityNodeInfo.ACTION_CLICK)
            return
        }
        if (!ScreenCast.asking) return
        // Android's question belongs to the system's own interface.
        if (from != "com.android.systemui") return
        val root = rootInActiveWindow ?: return
        val start = root.findAccessibilityNodeInfosByViewId("android:id/button1").firstOrNull { it.isClickable && it.isEnabled }
            ?: START_WORDS.firstNotNullOfOrNull { word -> root.findAccessibilityNodeInfosByText(word).firstOrNull { it.isClickable && it.isEnabled } }
        start?.performAction(AccessibilityNodeInfo.ACTION_CLICK)
    }

    private fun point(x: Int, y: Int): PointF {
        val size = ScreenCast.screenSize(this)
        return PointF((x / 65535f * size.x).coerceIn(0f, size.x - 1f), (y / 65535f * size.y).coerceIn(0f, size.y - 1f))
    }

    private fun down(at: PointF) {
        stroke = null
        nextMove = null
        lift = false
        last = at
        val made = GestureDescription.StrokeDescription(Path().apply { moveTo(at.x, at.y) }, 0, PIECE, true)
        send(made)
    }

    private fun move(to: PointF) {
        if (stroke == null && !busy) return
        nextMove = to
        pump()
    }

    private fun up() {
        if (stroke == null && !busy) return
        lift = true
        pump()
    }

    /** Sends the next piece once the one before has run. */
    private fun pump() {
        if (busy) return
        val current = stroke ?: return
        val to = nextMove
        if (to != null) {
            nextMove = null
            val path = Path().apply { moveTo(last.x, last.y); lineTo(to.x, to.y) }
            last = to
            send(current.continueStroke(path, 0, PIECE, true))
        } else if (lift) {
            lift = false
            val path = Path().apply { moveTo(last.x, last.y) }
            stroke = null
            dispatch(current.continueStroke(path, 0, 1, false))
        }
    }

    private fun send(piece: GestureDescription.StrokeDescription) {
        stroke = piece
        dispatch(piece)
    }

    private fun dispatch(piece: GestureDescription.StrokeDescription) {
        busy = true
        val accepted = dispatchGesture(GestureDescription.Builder().addStroke(piece).build(), object : GestureResultCallback() {
            override fun onCompleted(gesture: GestureDescription) {
                busy = false
                pump()
            }

            override fun onCancelled(gesture: GestureDescription) {
                busy = false
                stroke = null
                nextMove = null
                lift = false
            }
        }, main)
        if (!accepted) {
            busy = false
            stroke = null
        }
    }

    /** A wheel turn: a short swipe the other way, as a finger would do it. */
    private fun scroll(at: PointF, across: Float, downwards: Float) {
        // Not in the middle of a drag; anything else still running is over as far as the Mac is concerned.
        if (stroke != null) return
        val size = ScreenCast.screenSize(this)
        val end = PointF((at.x - across).coerceIn(0f, size.x - 1f), (at.y - downwards).coerceIn(0f, size.y - 1f))
        val path = Path().apply { moveTo(at.x, at.y); lineTo(end.x, end.y) }
        dispatch(GestureDescription.StrokeDescription(path, 0, 120))
    }

    private fun key(which: Int) {
        val action = when (which) {
            0 -> GLOBAL_ACTION_BACK
            1 -> GLOBAL_ACTION_HOME
            2 -> GLOBAL_ACTION_RECENTS
            3 -> GLOBAL_ACTION_NOTIFICATIONS
            4 -> GLOBAL_ACTION_QUICK_SETTINGS
            5 -> if (Build.VERSION.SDK_INT >= 28) GLOBAL_ACTION_LOCK_SCREEN else return
            else -> return
        }
        performGlobalAction(action)
    }

    /** Types into whatever field has the cursor, by rewriting its text. */
    private fun type(text: String) {
        val field = rootInActiveWindow?.findFocus(AccessibilityNodeInfo.FOCUS_INPUT) ?: return
        if (text == "\n" && Build.VERSION.SDK_INT >= 30) {
            field.performAction(AccessibilityNodeInfo.AccessibilityAction.ACTION_IME_ENTER.id)
            return
        }
        var now = if (Build.VERSION.SDK_INT >= 26 && field.isShowingHintText) "" else field.text?.toString().orEmpty()
        for (char in text) {
            now = if (char == '\b') now.dropLast(1) else now + char
        }
        field.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, Bundle().apply {
            putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, now)
        })
    }

    companion object {
        /** How long one piece of a drag takes, in milliseconds: short enough to follow the mouse. */
        private const val PIECE = 24L
        /** The button's words where it has no usual name, newest first. */
        private val START_WORDS = listOf("Share screen", "Start now", "Start", "共享屏幕", "立即开始", "开始")

        @Volatile var instance: TouchService? = null
            private set

        /** Reads the Mac's messages until it hangs up. Messages still count when the service is off; they just do nothing. */
        fun listen(input: InputStream) {
            val data = DataInputStream(input)
            while (true) {
                val kind = data.read()
                if (kind < 0) return
                when (kind) {
                    0, 1, 2 -> {
                        val x = data.readUnsignedShort()
                        val y = data.readUnsignedShort()
                        run { service -> val at = service.point(x, y); if (kind == 0) service.down(at) else if (kind == 1) service.move(at) else service.up() }
                    }
                    3 -> {
                        val which = data.read()
                        // Waking the screen needs no accessibility service.
                        if (which == 6) LinkService.instance?.wake() else run { it.key(which) }
                    }
                    4 -> {
                        val bytes = ByteArray(data.readUnsignedShort())
                        data.readFully(bytes)
                        run { it.type(String(bytes)) }
                    }
                    5 -> {
                        val x = data.readUnsignedShort()
                        val y = data.readUnsignedShort()
                        val across = data.readShort()
                        val downwards = data.readShort()
                        run { service ->
                            val size = ScreenCast.screenSize(service)
                            service.scroll(service.point(x, y), across / 65535f * size.x, downwards / 65535f * size.y)
                        }
                    }
                    else -> return
                }
            }
        }

        private fun run(action: (TouchService) -> Unit) {
            val service = instance ?: return
            service.main.post { runCatching { action(service) } }
        }
    }
}
