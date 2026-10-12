package app.sideboard.link

import android.app.Activity
import android.content.Intent
import android.media.projection.MediaProjectionConfig
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Bundle

/** Brings up Android's own "let this app capture the screen?" and passes the answer on. Shows nothing itself. */
class CaptureActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (savedInstanceState != null) return
        val manager = getSystemService(MediaProjectionManager::class.java)
        // Newer Androids offer "one app" first; the Mac is after the whole screen.
        val question = if (Build.VERSION.SDK_INT >= 34) {
            manager.createScreenCaptureIntent(MediaProjectionConfig.createConfigForDefaultDisplay())
        } else {
            manager.createScreenCaptureIntent()
        }
        runCatching { @Suppress("DEPRECATION") startActivityForResult(question, 1) }.onFailure {
            ScreenCast.onConsent(RESULT_CANCELED, null)
            finish()
        }
    }

    @Deprecated("The platform's own callback; this activity uses no libraries.")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        ScreenCast.onConsent(resultCode, data)
        finish()
    }
}
