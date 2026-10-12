package app.sideboard.link

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.graphics.Point
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Handler
import android.os.Looper
import android.view.Display
import android.view.WindowManager
import java.net.Socket
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * The screen as an H.264 stream for one Mac at a time. Android asks the owner before an app may
 * capture the screen ([CaptureActivity] brings that question up; with the accessibility service
 * on, [TouchService] answers it, so nobody has to be at the device). The permission is kept for
 * as long as the app lives; each viewer gets its own encoder.
 */
object ScreenCast {
    private var projection: MediaProjection? = null
    private var display: VirtualDisplay? = null
    private var consent: CountDownLatch? = null
    private var consentCode = 0
    private var consentData: Intent? = null
    /** Counts viewers: a new one takes over, and the one before notices and stops. */
    @Volatile private var viewer = 0
    /** Android's question is on the screen, waiting for "Start". */
    @Volatile var asking = false
        private set

    /** The screen's real size in pixels, as it is turned now. */
    fun screenSize(context: Context): Point {
        val size = Point()
        @Suppress("DEPRECATION")
        context.getSystemService(DisplayManager::class.java).getDisplay(Display.DEFAULT_DISPLAY).getRealSize(size)
        return size
    }

    /** Called by [CaptureActivity] with the owner's answer. */
    fun onConsent(code: Int, data: Intent?) {
        consentCode = code
        consentData = data
        asking = false
        consent?.countDown()
    }

    @Synchronized
    private fun obtain(service: LinkService): MediaProjection? {
        projection?.let { return it }
        val latch = CountDownLatch(1)
        consent = latch
        asking = true
        // From the background this only works while the accessibility service is on: Android lets such apps open a screen.
        runCatching { service.startActivity(Intent(service, CaptureActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) }
        latch.await(40, TimeUnit.SECONDS)
        asking = false
        val data = consentData?.takeIf { consentCode == Activity.RESULT_OK } ?: return null
        consentData = null
        // The service must be of the screen-capturing kind before the permission is used.
        service.show(sharing = true)
        val manager = service.getSystemService(MediaProjectionManager::class.java)
        val made = runCatching { manager.getMediaProjection(consentCode, data) }.getOrNull() ?: return null
        made.registerCallback(object : MediaProjection.Callback() {
            override fun onStop() = release()
        }, Handler(Looper.getMainLooper()))
        projection = made
        return made
    }

    /** Streams until the Mac hangs up, the screen is turned, or another viewer takes over. */
    fun serve(service: LinkService, client: Socket, longest: Int, bitRate: Int) {
        val output = client.getOutputStream()
        val projection = obtain(service)
        if (projection == null) {
            output.write("refused\n".toByteArray())
            service.show(sharing = false)
            return
        }
        val mine = synchronized(this) { ++viewer }
        val real = screenSize(service)
        // No bigger than asked, the same shape, and sizes every encoder takes.
        val scale = minOf(1f, longest.coerceIn(320, 4096).toFloat() / maxOf(real.x, real.y))
        val width = ((real.x * scale).toInt() / 8 * 8).coerceAtLeast(16)
        val height = ((real.y * scale).toInt() / 8 * 8).coerceAtLeast(16)
        val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, width, height).apply {
            setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
            setInteger(MediaFormat.KEY_BIT_RATE, bitRate.coerceIn(500_000, 20_000_000))
            setInteger(MediaFormat.KEY_FRAME_RATE, 60)
            setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 2)
            // A still screen keeps sending its last picture now and then, so a viewer is never left waiting.
            setLong(MediaFormat.KEY_REPEAT_PREVIOUS_FRAME_AFTER, 200_000)
        }
        val encoder = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
        try {
            encoder.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            val surface = encoder.createInputSurface()
            encoder.start()
            synchronized(this) {
                val density = service.resources.displayMetrics.densityDpi
                val shown = display
                if (shown == null) {
                    display = projection.createVirtualDisplay("Sideboard Link", width, height, density, DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR, surface, null, null)
                } else {
                    shown.resize(width, height, density)
                    shown.surface = surface
                }
            }
            service.show(sharing = true)
            output.write("video $width $height\n".toByteArray())
            output.flush()
            val info = MediaCodec.BufferInfo()
            val chunk = ByteArray(256 * 1024)
            val rotation = rotation(service)
            while (viewer == mine && this.projection != null && rotation(service) == rotation) {
                val index = encoder.dequeueOutputBuffer(info, 250_000)
                if (index < 0) continue
                val buffer = encoder.getOutputBuffer(index)
                if (buffer != null && info.size > 0) {
                    buffer.position(info.offset)
                    var left = info.size
                    while (left > 0) {
                        val count = minOf(left, chunk.size)
                        buffer.get(chunk, 0, count)
                        output.write(chunk, 0, count)
                        left -= count
                    }
                    output.flush()
                }
                encoder.releaseOutputBuffer(index, false)
                if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) break
            }
        } catch (_: Exception) {
            // The Mac hung up, or the encoder gave out: either way this viewer is done.
        } finally {
            synchronized(this) {
                if (viewer == mine) {
                    runCatching { display?.surface = null }
                    service.show(sharing = false)
                }
            }
            runCatching { encoder.stop() }
            runCatching { encoder.release() }
        }
    }

    private fun rotation(context: Context): Int {
        @Suppress("DEPRECATION")
        return context.getSystemService(WindowManager::class.java).defaultDisplay.rotation
    }

    /** Gives the permission back: the service is ending, or Android took it away. */
    @Synchronized
    fun release() {
        viewer++
        runCatching { display?.release() }
        display = null
        runCatching { projection?.stop() }
        projection = null
        LinkService.instance?.show(sharing = false)
    }
}
