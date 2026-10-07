package com.weijiazhao.sideboard

import android.content.BroadcastReceiver
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.inputmethodservice.InputMethodService
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Base64
import android.text.InputType
import android.view.KeyEvent
import android.view.View
import android.view.inputmethod.EditorInfo

/**
 * A keyboard with no keys: it types what Sideboard on the Mac sends, in any language, and reads or
 * sets the clipboard (Android only lets the active keyboard read it). Sideboard switches to it while
 * its typing window is open and switches back afterwards. If that ever doesn't happen, it switches
 * back by itself after a few idle minutes.
 *
 *     am broadcast -p com.weijiazhao.sideboard -a com.weijiazhao.sideboard.TYPE --es b64 <base64 UTF-8>
 *
 * Actions: TYPE (b64), KEY (code: enter, delete), SET_CLIP (b64), GET_CLIP (result data: base64).
 * Result 1 means done, 2 that no text field has focus.
 * Only senders holding DUMP (the adb shell) can reach it.
 */
class TypingService : InputMethodService() {
    private val handler = Handler(Looper.getMainLooper())
    /** A text field has focus (Android also binds keyboards to screens with no field). */
    private var editing = false
    private val idle = Runnable {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) switchToPreviousInputMethod()
    }

    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            handler.removeCallbacks(idle)
            handler.postDelayed(idle, IDLE_MS)
            val connection = currentInputConnection?.takeIf { editing }
            when (intent.action) {
                TYPE -> {
                    val text = decode(intent.getStringExtra("b64")) ?: return
                    resultCode = if (connection?.commitText(text, 1) == true) 1 else NO_FIELD
                }
                KEY -> {
                    if (connection == null) {
                        resultCode = NO_FIELD
                        return
                    }
                    when (intent.getStringExtra("code")) {
                        "enter" -> if (!sendDefaultEditorAction(true)) sendDownUpKeyEvents(KeyEvent.KEYCODE_ENTER)
                        "delete" -> sendDownUpKeyEvents(KeyEvent.KEYCODE_DEL)
                    }
                    resultCode = 1
                }
                SET_CLIP -> {
                    val text = decode(intent.getStringExtra("b64")) ?: return
                    getSystemService(ClipboardManager::class.java).setPrimaryClip(ClipData.newPlainText("Sideboard", text))
                    resultCode = 1
                }
                GET_CLIP -> {
                    val clip = getSystemService(ClipboardManager::class.java).primaryClip
                    val text = clip?.takeIf { it.itemCount > 0 }?.getItemAt(0)?.coerceToText(context)?.toString() ?: ""
                    resultCode = 1
                    resultData = Base64.encodeToString(text.toByteArray(), Base64.NO_WRAP)
                }
            }
        }
    }

    override fun onCreate() {
        super.onCreate()
        val filter = IntentFilter().apply { listOf(TYPE, KEY, SET_CLIP, GET_CLIP).forEach(::addAction) }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(receiver, filter, PERMISSION, null, RECEIVER_EXPORTED)
        } else {
            registerReceiver(receiver, filter, PERMISSION, null)
        }
        handler.postDelayed(idle, IDLE_MS)
    }

    override fun onDestroy() {
        handler.removeCallbacks(idle)
        unregisterReceiver(receiver)
        super.onDestroy()
    }

    override fun onStartInput(attribute: EditorInfo, restarting: Boolean) {
        super.onStartInput(attribute, restarting)
        editing = attribute.inputType != InputType.TYPE_NULL
    }

    override fun onFinishInput() {
        super.onFinishInput()
        editing = false
    }

    /** Nothing appears on screen: the typing happens from the Mac. */
    override fun onEvaluateInputViewShown() = false
    override fun onCreateInputView(): View = View(this)
    override fun onEvaluateFullscreenMode() = false

    private fun decode(b64: String?): String? =
        b64?.let { runCatching { String(Base64.decode(it, Base64.DEFAULT)) }.getOrNull() }

    companion object {
        const val TYPE = "com.weijiazhao.sideboard.TYPE"
        const val KEY = "com.weijiazhao.sideboard.KEY"
        const val SET_CLIP = "com.weijiazhao.sideboard.SET_CLIP"
        const val GET_CLIP = "com.weijiazhao.sideboard.GET_CLIP"
        const val PERMISSION = "android.permission.DUMP"
        const val IDLE_MS = 5 * 60_000L
        /** 0 is what `am broadcast` reports when nobody received it (this keyboard isn't active). */
        const val NO_FIELD = 2
    }
}
