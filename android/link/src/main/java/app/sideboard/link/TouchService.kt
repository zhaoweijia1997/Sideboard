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
 *     8, 9, 10 a second finger down, moved, up: x, y. For pinching (since 0.5)
 *     6 a tap:  x, y. Down and up in one, done here, so that it is a tap however long the
 *               network took between the two (since 0.4)
 *
 * A drag is one gesture that keeps being continued, so the finger follows the mouse while it
 * moves. Android runs one piece of a gesture at a time; moves that arrive meanwhile are joined
 * into the next piece. With a second finger down, each piece carries both.
 *
 * Several can be connected at once. Whoever puts a finger down first has the screen until it
 * lifts; the others' touches are left out meanwhile. Keys and text are taken from anybody.
 *
 * It also answers Android's "start capturing the screen?" when that was asked on the Mac's
 * behalf ([ScreenCast.asking]), so the device needn't be touched.
 */
class TouchService : AccessibilityService() {
    private val main = Handler(Looper.getMainLooper())
    /** A finger held on the screen for somebody far away. */
    private class Finger(var last: PointF) {
        /** The piece of its gesture sent last; null before the first. */
        var stroke: GestureDescription.StrokeDescription? = null
        var next: PointF? = null
        var lift = false
    }

    /** Two at most: one to tap and drag, a second one to pinch. */
    private val fingers = arrayOfNulls<Finger>(2)
    private var busy = false
    /** Goes up whenever the gesture is begun afresh, so that what Android says about the one before is ignored. */
    private var round = 0
    /** A second finger arrived during a piece: begin afresh with both as soon as that piece has run. */
    private var afresh = false
    /** Where the first finger went down and where it is. */
    private var downAt = PointF()
    private var last = PointF()
    /** The lock-screen key the first finger went down on, to be pressed when it lifts. */
    private var padKey: AccessibilityNodeInfo? = null

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

    private fun down(id: Int, at: PointF) {
        if (id == 0) {
            downAt = PointF(at.x, at.y)
            last = at
            // On a key of the lock screen's pad no finger is put down at all: the key is
            // pressed directly when the finger lifts (see [padKeyAt]).
            padKey = padKeyAt(at)
            if (padKey != null) {
                fingers.fill(null)
                return
            }
        }
        val other = fingers[1 - id]
        fingers[id] = Finger(at)
        if (other != null && other.stroke != null) {
            // Android won't add a finger to a gesture that is under way. So the gesture begins
            // again with both where they are; the one before is called off, not lifted, and so
            // doesn't count as a tap. Not in the middle of a piece, though: beginning afresh
            // while one is still running gets the new gesture called off as well, more often
            // than not. Then it waits for that piece to end, a few milliseconds.
            if (busy) afresh = true else beginAfresh()
        }
        pump()
    }

    /** Every finger held starts a new gesture where it is. */
    private fun beginAfresh() {
        afresh = false
        for (finger in fingers) {
            finger?.stroke = null
            finger?.lift = false
        }
        round++
        busy = false
    }

    /** A whole tap, timed on this device. */
    private fun tap(at: PointF) {
        fingers.fill(null)
        round++
        last = at
        downAt = PointF(at.x, at.y)
        padKey = null
        val key = padKeyAt(at)
        if (key != null) {
            key.performAction(AccessibilityNodeInfo.ACTION_CLICK)
            return
        }
        dispatch(GestureDescription.Builder().addStroke(GestureDescription.StrokeDescription(Path().apply { moveTo(at.x, at.y) }, 0, TAP)).build())
    }

    private fun move(id: Int, to: PointF) {
        val finger = fingers[id] ?: return
        finger.next = to
        if (id == 0) last = to
        pump()
    }

    private fun up(id: Int) {
        if (id == 0) {
            val key = padKey
            padKey = null
            if (key != null) {
                key.performAction(AccessibilityNodeInfo.ACTION_CLICK)
                return
            }
        }
        val finger = fingers[id] ?: return
        finger.lift = true
        // Two fingers end together: the one left behind would otherwise jump about as a lone finger.
        fingers[1 - id]?.lift = true
        pump()
    }

    /**
     * The key of the lock screen's PIN pad at [at], if the device is locked and there is one.
     * The pad is unreliable with gestures made for somebody else (short ones it ignores, longer
     * ones it takes), so its keys are pressed directly, the way a screen reader does for its
     * user, and never touched as well: one press, one digit.
     */
    private fun padKeyAt(at: PointF): AccessibilityNodeInfo? {
        if (!getSystemService(android.app.KeyguardManager::class.java).isKeyguardLocked) return null
        val root = rootInActiveWindow ?: return null
        val bounds = android.graphics.Rect()
        fun keyAt(node: AccessibilityNodeInfo): AccessibilityNodeInfo? {
            node.getBoundsInScreen(bounds)
            if (!bounds.contains(at.x.toInt(), at.y.toInt())) return null
            for (index in 0 until node.childCount) {
                val child = node.getChild(index) ?: continue
                keyAt(child)?.let { return it }
            }
            val name = node.viewIdResourceName.orEmpty()
            val isKey = name.startsWith("com.android.systemui:id/key") || name == "com.android.systemui:id/delete_button"
            return node.takeIf { isKey && it.isClickable }
        }
        return keyAt(root)
    }

    /**
     * Sends the next piece once the one before has run: one gesture that carries every finger
     * on the screen on, whether it moved or not, so that none of them is let go by accident.
     */
    private fun pump() {
        if (busy) return
        val held = fingers.filterNotNull()
        if (held.none { it.stroke == null || it.next != null || it.lift }) return
        val gesture = GestureDescription.Builder()
        for (finger in held) {
            val to = finger.next
            finger.next = null
            val path = Path().apply {
                moveTo(finger.last.x, finger.last.y)
                if (to != null) lineTo(to.x, to.y)
            }
            if (to != null) finger.last = to
            val current = finger.stroke
            // A finger that still has somewhere to go gets there first and lifts in the next piece.
            val lifting = current != null && finger.lift && to == null
            val piece = current?.continueStroke(path, 0, if (lifting) 1 else PIECE, !lifting)
                ?: GestureDescription.StrokeDescription(path, 0, PIECE, true)
            finger.stroke = piece
            if (lifting) fingers[fingers.indexOf(finger)] = null
            gesture.addStroke(piece)
        }
        dispatch(gesture.build())
    }

    private fun dispatch(gesture: GestureDescription) {
        busy = true
        val mine = round
        val accepted = dispatchGesture(gesture, object : GestureResultCallback() {
            override fun onCompleted(gesture: GestureDescription) {
                if (mine != round) return
                busy = false
                if (afresh) beginAfresh()
                pump()
            }

            override fun onCancelled(gesture: GestureDescription) {
                if (mine != round) return
                busy = false
                afresh = false
                fingers.fill(null)
            }
        }, main)
        if (!accepted) {
            busy = false
            fingers.fill(null)
        }
    }

    /** A wheel turn: a short swipe the other way, as a finger would do it. */
    private fun scroll(at: PointF, across: Float, downwards: Float) {
        // Not in the middle of a drag; anything else still running is over as far as the Mac is concerned.
        if (fingers.any { it != null }) return
        val size = ScreenCast.screenSize(this)
        val end = PointF((at.x - across).coerceIn(0f, size.x - 1f), (at.y - downwards).coerceIn(0f, size.y - 1f))
        val path = Path().apply { moveTo(at.x, at.y); lineTo(end.x, end.y) }
        dispatch(GestureDescription.Builder().addStroke(GestureDescription.StrokeDescription(path, 0, 120)).build())
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

    /**
     * Types into whatever field has the cursor, by rewriting its text. Where there is no such
     * field but there are keys on the screen, as on the lock screen's PIN pad, it presses the
     * keys instead: each character's own key, Return for the pad's Enter, and its delete key.
     */
    private fun type(text: String) {
        val root = rootInActiveWindow ?: return
        val field = root.findFocus(AccessibilityNodeInfo.FOCUS_INPUT)
        if (field == null || !field.isEditable) {
            if (text.isNotEmpty() && key(root, text[0]) == null && getSystemService(android.app.KeyguardManager::class.java).isKeyguardLocked) {
                // The lock screen without its keys yet: swipe it up first, as a finger would, then press them.
                val size = ScreenCast.screenSize(this)
                val path = Path().apply { moveTo(size.x / 2f, size.y * 0.9f); lineTo(size.x / 2f, size.y * 0.2f) }
                dispatchGesture(GestureDescription.Builder().addStroke(GestureDescription.StrokeDescription(path, 0, 200)).build(), null, null)
                main.postDelayed({ rootInActiveWindow?.let { shown -> for (char in text) key(shown, char)?.performAction(AccessibilityNodeInfo.ACTION_CLICK) } }, 900)
                return
            }
            for (char in text) key(root, char)?.performAction(AccessibilityNodeInfo.ACTION_CLICK)
            return
        }
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

    /** The on-screen key for [char], found by its label or, for Enter and delete, by the lock screen's names for them. */
    private fun key(root: AccessibilityNodeInfo, char: Char): AccessibilityNodeInfo? {
        val found = when (char) {
            '\n' -> root.findAccessibilityNodeInfosByViewId("com.android.systemui:id/key_enter")
            '\b' -> root.findAccessibilityNodeInfosByViewId("com.android.systemui:id/delete_button")
            else -> root.findAccessibilityNodeInfosByText(char.toString()).filter { it.text?.toString() == char.toString() || it.contentDescription?.toString() == char.toString() }
        }
        // The label may sit inside the key: the nearest thing that can be pressed.
        var key = found.firstOrNull()
        while (key != null && !key.isClickable) key = key.parent
        return key
    }

    companion object {
        /** How long one piece of a drag takes, in milliseconds: short enough to follow the mouse. */
        private const val PIECE = 24L
        /** How long a tap's finger stays down. */
        private const val TAP = 50L
        /** The button's words where it has no usual name, newest first. */
        private val START_WORDS = listOf("Share screen", "Start now", "Start", "共享屏幕", "立即开始", "开始")

        @Volatile var instance: TouchService? = null
            private set

        /** Reads the Mac's messages until it hangs up. Messages still count when the service is off; they just do nothing. */
        fun listen(input: InputStream) {
            val data = DataInputStream(input)
            // Each connection is somebody: a Mac, a phone. Whoever puts a finger down first has
            // the screen until it lifts; touches from anybody else meanwhile are left out, so
            // that two people don't tear one gesture apart between them.
            val me = people.incrementAndGet()
            while (true) {
                val kind = data.read()
                if (kind < 0) return
                // A finger going down, a key or text: the screen comes on if it was off or locked.
                if (kind != 1 && kind != 2 && kind != 9 && kind != 10) LinkService.instance?.touched()

                when (kind) {
                    0, 1, 2 -> {
                        val x = data.readUnsignedShort()
                        val y = data.readUnsignedShort()
                        if (!mayTouch(me, begins = kind == 0)) continue
                        if (kind == 2) letGo(me)
                        run { service -> val at = service.point(x, y); if (kind == 0) service.down(0, at) else if (kind == 1) service.move(0, at) else service.up(0) }
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
                    8, 9, 10 -> {
                        val x = data.readUnsignedShort()
                        val y = data.readUnsignedShort()
                        if (!mayTouch(me, begins = false)) continue
                        run { service -> val at = service.point(x, y); if (kind == 8) service.down(1, at) else if (kind == 9) service.move(1, at) else service.up(1) }
                    }
                    6 -> {
                        val x = data.readUnsignedShort()
                        val y = data.readUnsignedShort()
                        if (!mayTouch(me, begins = true)) continue
                        letGo(me)
                        run { it.tap(it.point(x, y)) }
                    }
                    5 -> {
                        val x = data.readUnsignedShort()
                        val y = data.readUnsignedShort()
                        val across = data.readShort()
                        val downwards = data.readShort()
                        if (!mayTouch(me, begins = true)) continue
                        letGo(me)
                        run { service ->
                            val size = ScreenCast.screenSize(service)
                            service.scroll(service.point(x, y), across / 65535f * size.x, downwards / 65535f * size.y)
                        }
                    }
                    else -> return
                }
            }
        }

        private val people = java.util.concurrent.atomic.AtomicInteger()
        /** Who has a finger down, and when they last moved it: a hold that has gone quiet (a lost connection) runs out. */
        private var holder = 0
        private var heldAt = 0L

        /** Whether [who] may touch now. With [begins], a free screen becomes theirs; without, only an ongoing hold of their own counts. */
        @Synchronized
        private fun mayTouch(who: Int, begins: Boolean): Boolean {
            val now = System.currentTimeMillis()
            if (holder != 0 && holder != who && now - heldAt > 3_000) holder = 0
            if (holder == 0 && begins) holder = who
            if (holder != who) return false
            heldAt = now
            return true
        }

        @Synchronized
        private fun letGo(who: Int) {
            if (holder == who) holder = 0
        }

        private fun run(action: (TouchService) -> Unit) {
            val service = instance ?: return
            service.main.post { runCatching { action(service) } }
        }
    }
}
