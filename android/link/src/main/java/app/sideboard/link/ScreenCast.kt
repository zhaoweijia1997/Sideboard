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
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.Display
import android.view.WindowManager
import java.io.OutputStream
import java.net.Socket
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * The screen as an H.264 stream. Android asks the owner before an app may capture the screen
 * ([CaptureActivity] brings that question up; with the accessibility service on, [TouchService]
 * answers it, so nobody has to be at the device). The permission is kept for as long as the
 * app lives.
 *
 * There is one encoder, and everybody watching gets what it produces: a Mac and a phone can
 * look at the same time. Somebody joining is given the stream's parameters and then waits for
 * the next whole picture, which is asked for at once. The first to arrive decides the size.
 * When the screen is turned the stream ends for everybody, and they ask again.
 */
object ScreenCast {
    private class Viewer(val output: OutputStream) {
        /** Has been sent a whole picture, so what follows makes sense to it. */
        var started = false
        @Volatile var gone = false
    }

    private var projection: MediaProjection? = null
    private var display: VirtualDisplay? = null
    private var consent: CountDownLatch? = null
    private var consentCode = 0
    private var consentData: Intent? = null
    private val viewers = CopyOnWriteArrayList<Viewer>()
    /** The running encoder, its size, and a number that changes whenever a new one starts. */
    private var encoder: MediaCodec? = null
    private var width = 0
    private var height = 0
    @Volatile private var round = 0
    /** The stream's parameter sets, for whoever joins later. */
    @Volatile private var parameters: ByteArray? = null
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

    /** Streams to [client] until it hangs up or the screen is turned. */
    fun serve(service: LinkService, client: Socket, longest: Int, bitRate: Int) {
        val output = client.getOutputStream()
        val projection = obtain(service)
        if (projection == null) {
            output.write("refused\n".toByteArray())
            if (viewers.isEmpty()) service.show(sharing = false)
            return
        }
        val viewer = Viewer(output)
        val mine: Int
        synchronized(this) {
            if (encoder == null && !start(service, projection, longest, bitRate)) {
                output.write("refused\n".toByteArray())
                return
            }
            mine = round
            output.write("video $width $height\n".toByteArray())
            output.flush()
            viewers.add(viewer)
            // A whole picture for the newcomer, now.
            runCatching { encoder?.setParameters(Bundle().apply { putInt(MediaCodec.PARAMETER_KEY_REQUEST_SYNC_FRAME, 0) }) }
        }
        service.show(sharing = true)
        // The encoder's thread does the sending; this one only waits for the end.
        while (!viewer.gone && round == mine) Thread.sleep(100)
        viewers.remove(viewer)
    }

    /** Starts the encoder and the thread that hands out its pictures. Call with the lock held. */
    private fun start(service: LinkService, projection: MediaProjection, longest: Int, bitRate: Int): Boolean {
        val real = screenSize(service)
        // No bigger than asked, the same shape, and sizes every encoder takes.
        val scale = minOf(1f, longest.coerceIn(320, 4096).toFloat() / maxOf(real.x, real.y))
        val w = ((real.x * scale).toInt() / 8 * 8).coerceAtLeast(16)
        val h = ((real.y * scale).toInt() / 8 * 8).coerceAtLeast(16)
        val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, w, h).apply {
            setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
            setInteger(MediaFormat.KEY_BIT_RATE, bitRate.coerceIn(500_000, 20_000_000))
            setInteger(MediaFormat.KEY_FRAME_RATE, 60)
            setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 2)
            // A still screen keeps sending its last picture now and then, so nobody is left waiting.
            setLong(MediaFormat.KEY_REPEAT_PREVIOUS_FRAME_AFTER, 200_000)
        }
        val made = runCatching { MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC) }.getOrNull() ?: return false
        try {
            made.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            val surface = made.createInputSurface()
            made.start()
            val density = service.resources.displayMetrics.densityDpi
            val shown = display
            if (shown == null) {
                display = projection.createVirtualDisplay("Sideboard Link", w, h, density, DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR, surface, null, null)
            } else {
                shown.resize(w, h, density)
                shown.surface = surface
            }
        } catch (_: Exception) {
            runCatching { made.release() }
            return false
        }
        encoder = made
        width = w
        height = h
        parameters = null
        val mine = ++round
        val most = bitRate.coerceIn(500_000, 20_000_000)
        Thread({ pump(service, made, mine, most) }, "link-encoder").start()
        return true
    }

    /** Takes the encoder's pictures and sends them to everybody watching, until nobody is, or the screen is turned. */
    private fun pump(service: LinkService, encoder: MediaCodec, mine: Int, most: Int) {
        val info = MediaCodec.BufferInfo()
        val rotation = rotation(service)
        var alone = 0L
        // The quality follows the network: when sending holds things up, fewer bits per second
        // (pictures get softer but keep up); when it has gone smoothly for a while, more again.
        var rate = most
        var windowStart = System.nanoTime()
        var sending = 0L
        var smooth = 0
        try {
            while (round == mine && projection != null && rotation(service) == rotation) {
                if (viewers.isEmpty()) {
                    // Give a viewer that is on its way back a moment before stopping.
                    if (alone == 0L) alone = System.currentTimeMillis()
                    if (System.currentTimeMillis() - alone > 3_000) break
                } else {
                    alone = 0L
                }
                val index = encoder.dequeueOutputBuffer(info, 250_000)
                if (index < 0) continue
                val buffer = encoder.getOutputBuffer(index)
                if (buffer != null && info.size > 0) {
                    val bytes = ByteArray(info.size)
                    buffer.position(info.offset)
                    buffer.get(bytes)
                    val isParameters = info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0
                    val isWhole = info.flags and MediaCodec.BUFFER_FLAG_KEY_FRAME != 0
                    if (isParameters) parameters = bytes
                    val before = System.nanoTime()
                    for (viewer in viewers) {
                        if (viewer.gone) continue
                        try {
                            if (!viewer.started) {
                                // Parameters, then nothing until a whole picture.
                                if (isParameters) continue
                                if (!isWhole) continue
                                parameters?.let { viewer.output.write(it) }
                                viewer.started = true
                            } else if (isParameters) {
                                viewer.output.write(bytes)
                                continue
                            }
                            viewer.output.write(bytes)
                            viewer.output.flush()
                        } catch (_: Exception) {
                            viewer.gone = true
                        }
                    }
                    sending += System.nanoTime() - before
                }
                encoder.releaseOutputBuffer(index, false)
                val now = System.nanoTime()
                if (now - windowStart >= 1_000_000_000L) {
                    val busy = sending * 100 / (now - windowStart)
                    val next = when {
                        busy > 35 -> {
                            smooth = 0
                            (rate * 7L / 10).toInt().coerceAtLeast(LEAST_RATE)
                        }
                        busy < 5 && ++smooth >= 4 -> {
                            smooth = 0
                            (rate * 5L / 4).toInt().coerceAtMost(most)
                        }
                        else -> rate
                    }
                    if (next != rate) {
                        rate = next
                        runCatching { encoder.setParameters(Bundle().apply { putInt(MediaCodec.PARAMETER_KEY_VIDEO_BITRATE, rate) }) }
                    }
                    windowStart = now
                    sending = 0
                }
                if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) break
            }
        } catch (_: Exception) {
            // The encoder gave out: everybody asks again.
        } finally {
            synchronized(this) {
                if (round == mine) {
                    round++
                    this.encoder = null
                    runCatching { display?.surface = null }
                    service.show(sharing = false)
                }
            }
            runCatching { encoder.stop() }
            runCatching { encoder.release() }
        }
    }

    /** The fewest bits per second the quality drops to on a slow network. */
    private const val LEAST_RATE = 600_000

    private fun rotation(context: Context): Int {
        @Suppress("DEPRECATION")
        return context.getSystemService(WindowManager::class.java).defaultDisplay.rotation
    }

    /** Gives the permission back: the service is ending, or Android took it away. */
    @Synchronized
    fun release() {
        round++
        encoder = null
        runCatching { display?.release() }
        display = null
        runCatching { projection?.stop() }
        projection = null
        LinkService.instance?.show(sharing = false)
    }
}
