package expo.modules.livestream

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.util.Log
import android.view.SurfaceHolder
import android.widget.LinearLayout
import androidx.core.content.ContextCompat
import java.util.concurrent.CopyOnWriteArrayList
import com.pedro.common.ConnectChecker
import com.pedro.library.rtmp.RtmpCamera2
import com.pedro.library.view.OpenGlView

class PublisherView(context: Context) : LinearLayout(context), ConnectChecker {

  companion object {
    private const val TAG = "ExpoLiveStream"

    /**
     * Commands arrive on the native module, not on a view, so they target "the"
     * publisher. Tracking every live view as a stack (most recently attached
     * last) sends them to the one actually on screen, and a view going away
     * hands the role back to the previous one instead of dropping it.
     */
    private val liveInstances = CopyOnWriteArrayList<PublisherView>()

    @JvmStatic
    val activeInstance: PublisherView?
      get() = liveInstances.lastOrNull()
  }

  private var openGlView: OpenGlView? = null
  private var rtmpCamera: RtmpCamera2? = null

  var url: String = ""
  var streamKey: String = ""
  var videoWidth: Int = 720
  var videoHeight: Int = 1280
  var videoBitrate: Int = 2_000_000
  var videoFps: Int = 30
  var audioBitrate: Int = 128_000
  var audioSampleRate: Int = 44100
  var isFrontCamera: Boolean = true

  // Named emit* on purpose: a zero-arg `onConnectionSuccess()` / `onDisconnect()`
  // would resolve to the ConnectChecker override rather than to these helpers
  // (Kotlin prefers the candidate without default arguments), which made the
  // overrides call themselves and flood the main looper.
  private fun emitConnectionSuccess(data: Map<String, Any?> = emptyMap()) =
    emitViewEvent(this, "onConnectionSuccess", data)
  private fun emitConnectionFailed(data: Map<String, Any?>) =
    emitViewEvent(this, "onConnectionFailed", data)
  private fun emitDisconnect(data: Map<String, Any?> = emptyMap()) =
    emitViewEvent(this, "onDisconnect", data)
  private fun emitStreamStateChanged(data: Map<String, Any?>) =
    emitViewEvent(this, "onStreamStateChanged", data)
  private fun emitBitrateUpdate(data: Map<String, Any?>) =
    emitViewEvent(this, "onBitrateUpdate", data)

  @Volatile private var isStreaming = false
  @Volatile private var isMuted = false
  @Volatile private var isFlashOn = false
  @Volatile private var isSurfaceReady = false
  @Volatile private var isCameraInitialized = false
  @Volatile private var isSwitchingCamera = false
  @Volatile private var isBackgrounding = false
  @Volatile private var isStoppingIntentionally = false
  private var lastStreamUrl: String? = null
  @Volatile private var wasStreamingBeforeBackground = false

  init {
    liveInstances.add(this)
    Log.d(TAG, "View created, registered as active publisher")
    setupView()
  }

  override fun onAttachedToWindow() {
    super.onAttachedToWindow()
    // Promote to the front: the view being attached is the one on screen.
    liveInstances.remove(this)
    liveInstances.add(this)
  }

  override fun onLayout(changed: Boolean, l: Int, t: Int, r: Int, b: Int) {
    super.onLayout(changed, l, t, r, b)
    val w = r - l
    val h = b - t
    if (w > 0 && h > 0) {
      openGlView?.layout(0, 0, w, h)
    }
  }

  override fun onWindowFocusChanged(hasWindowFocus: Boolean) {
    super.onWindowFocusChanged(hasWindowFocus)
    if (hasWindowFocus && isSurfaceReady && !isCameraInitialized) {
      post { tryInitCamera() }
    }
  }

  override fun onWindowVisibilityChanged(visibility: Int) {
    super.onWindowVisibilityChanged(visibility)
    if (visibility != VISIBLE) {
      Log.d(TAG, "Window not visible (background)")
      wasStreamingBeforeBackground = isStreaming
      isBackgrounding = true
      try {
        val camera = rtmpCamera ?: return
        if (isStreaming) { camera.stopStream(); isStreaming = false }
        if (camera.isOnPreview) { camera.stopPreview() }
        isCameraInitialized = false
      } catch (e: Exception) { Log.w(TAG, "Error on background", e) }
    } else {
      Log.d(TAG, "Window visible (foreground)")
      isBackgrounding = false
      val shouldResume = wasStreamingBeforeBackground
      wasStreamingBeforeBackground = false

      if (!isCameraInitialized && isSurfaceReady) {
        post {
          try {
            reinitCamera()
            if (shouldResume && !lastStreamUrl.isNullOrEmpty()) {
              Log.d(TAG, "Resuming stream after background return")
              postDelayed({
                start(lastStreamUrl)
              }, 300)
            }
          } catch (e: Exception) {
            Log.e(TAG, "Error on foreground", e)
            if (shouldResume) {
              emitStreamStateChanged(mapOf("state" to "failed"))
              emitConnectionFailed(mapOf("msg" to "Failed to resume after background"))
            }
          }
        }
      } else if (shouldResume && !lastStreamUrl.isNullOrEmpty()) {
        post {
          Log.d(TAG, "Resuming stream (camera already ready)")
          start(lastStreamUrl)
        }
      }
    }
  }

  private fun reinitCamera() {
    val camera = rtmpCamera ?: return
    val rotation = com.pedro.encoder.input.video.CameraHelper.getCameraOrientation(context)
    val lw = maxOf(videoWidth, videoHeight)
    val lh = minOf(videoWidth, videoHeight)
    camera.prepareVideo(lw, lh, videoFps, videoBitrate, 1, rotation)
    camera.prepareAudio(audioBitrate, audioSampleRate, false)
    val facing = if (isFrontCamera)
      com.pedro.encoder.input.video.CameraHelper.Facing.FRONT
    else
      com.pedro.encoder.input.video.CameraHelper.Facing.BACK
    camera.startPreview(facing)
    isCameraInitialized = true
    Log.d(TAG, "Camera reinitialized")
  }

  private fun setupView() {
    openGlView = OpenGlView(context).apply {
      layoutParams = LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT)
      holder.addCallback(object : SurfaceHolder.Callback {
        override fun surfaceCreated(holder: SurfaceHolder) {
          Log.d(TAG, "OpenGL surface created")
          isSurfaceReady = true
          post { tryInitCamera() }
        }
        override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {}
        override fun surfaceDestroyed(holder: SurfaceHolder) {
          Log.d(TAG, "OpenGL surface destroyed")
          isSurfaceReady = false
        }
      })
    }
    addView(openGlView)
  }

  private fun hasPermissions(): Boolean {
    val cam = ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA)
    val mic = ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO)
    return cam == PackageManager.PERMISSION_GRANTED && mic == PackageManager.PERMISSION_GRANTED
  }

  private fun tryInitCamera() {
    if (!isSurfaceReady || isCameraInitialized) return
    if (!hasPermissions()) { Log.w(TAG, "Missing permissions"); return }

    val glView = openGlView ?: return
    try {
      Log.d(TAG, "Creating RtmpCamera2...")
      val camera = RtmpCamera2(glView, this)
      rtmpCamera = camera

      val rotation = com.pedro.encoder.input.video.CameraHelper.getCameraOrientation(context)
      val lw = maxOf(videoWidth, videoHeight)
      val lh = minOf(videoWidth, videoHeight)

      val videoPrepared = camera.prepareVideo(lw, lh, videoFps, videoBitrate, 1, rotation)
      val audioPrepared = camera.prepareAudio(audioBitrate, audioSampleRate, false)
      if (!videoPrepared || !audioPrepared) {
        Log.e(TAG, "Video or audio encoder preparation failed")
        isCameraInitialized = false
        return
      }

      val facing = if (isFrontCamera)
        com.pedro.encoder.input.video.CameraHelper.Facing.FRONT
      else
        com.pedro.encoder.input.video.CameraHelper.Facing.BACK
      camera.startPreview(facing)
      isCameraInitialized = true
      Log.d(TAG, "Camera initialized")
    } catch (e: Exception) {
      Log.e(TAG, "Failed to init camera", e)
      isCameraInitialized = false
    }
  }

  fun start(urlOverride: String?) {
    if (!isCameraInitialized && isSurfaceReady) {
      tryInitCamera()
    }
    val camera = rtmpCamera
    if (camera == null || !isCameraInitialized) {
      Log.e(TAG, "start: camera not ready")
      emitConnectionFailed(mapOf("msg" to "Camera not ready"))
      emitStreamStateChanged(mapOf("state" to "failed"))
      return
    }

    val targetUrl = (if (!urlOverride.isNullOrEmpty()) urlOverride else url).trim().trimEnd('/')
    val key = streamKey.trim()
    val fullUrl = if (key.isNotEmpty() && !targetUrl.endsWith("/$key")) {
      "$targetUrl/$key"
    } else targetUrl

    if (fullUrl.isEmpty()) {
      emitConnectionFailed(mapOf("msg" to "URL is empty"))
      emitStreamStateChanged(mapOf("state" to "failed"))
      return
    }
    isStoppingIntentionally = false
    post {
      try {
        val rotation = com.pedro.encoder.input.video.CameraHelper.getCameraOrientation(context)
        val lw = maxOf(videoWidth, videoHeight)
        val lh = minOf(videoWidth, videoHeight)
        val videoPrepared = camera.prepareVideo(lw, lh, videoFps, videoBitrate, 1, rotation)
        val audioPrepared = camera.prepareAudio(audioBitrate, audioSampleRate, false)
        if (!videoPrepared || !audioPrepared) {
          isStreaming = false
          emitConnectionFailed(mapOf("msg" to "Failed to prepare encoder"))
          emitStreamStateChanged(mapOf("state" to "failed"))
          return@post
        }
        if (!camera.isOnPreview) {
          val facing = if (isFrontCamera)
            com.pedro.encoder.input.video.CameraHelper.Facing.FRONT
          else
            com.pedro.encoder.input.video.CameraHelper.Facing.BACK
          camera.startPreview(facing)
        }

        Log.d(TAG, "startStream: $fullUrl")
        lastStreamUrl = fullUrl
        isStreaming = true
        emitStreamStateChanged(mapOf("state" to "connecting"))
        camera.startStream(fullUrl)
        if (isMuted) { camera.disableAudio() }
      } catch (e: Exception) {
        Log.e(TAG, "startStream failed", e)
        isStreaming = false
        emitConnectionFailed(mapOf("msg" to (e.message ?: "Unknown error")))
        emitStreamStateChanged(mapOf("state" to "failed"))
      }
    }
  }

  fun stop() {
    if (!isStreaming) return
    Log.d(TAG, "stop")
    // RootEncoder reports onDisconnect() after stopStream(); swallow that one so
    // JS does not see a "disconnected" right after the deliberate "stopped".
    isStoppingIntentionally = true
    isStreaming = false
    try {
      rtmpCamera?.stopStream()
    } catch (e: Exception) { Log.e(TAG, "stop failed", e) }
    emitDisconnect()
    emitStreamStateChanged(mapOf("state" to "stopped"))
    try {
      val camera = rtmpCamera
      if (camera != null && !camera.isOnPreview) {
        val facing = if (isFrontCamera)
          com.pedro.encoder.input.video.CameraHelper.Facing.FRONT
        else
          com.pedro.encoder.input.video.CameraHelper.Facing.BACK
        camera.startPreview(facing)
      }
    } catch (_: Exception) {}
  }

  /**
   * Swaps the camera without touching the RTMP session.
   *
   * This used to stop and restart the stream on Samsung and Xiaomi when
   * switching back to the front camera, to work around RootEncoder freezing
   * the encoder output on camera reopen. That workaround cost more than the
   * bug: dropping the connection unpublishes the stream, so every viewer is
   * disconnected and has to find the stream again - which is the freeze the
   * viewers were actually seeing.
   *
   * RootEncoder fixed the underlying freeze in 2.8.0 (PR #2105): the dynamic
   * FPS-range adaptation that broke the reopened capture session is now off by
   * default, and `Camera2ApiManager.dynamicFps` is only consulted when it is
   * explicitly turned on. Switching in place is therefore enough.
   */
  fun switchCamera() {
    post {
      val camera = rtmpCamera ?: return@post
      if (isSwitchingCamera) return@post
      isSwitchingCamera = true
      emitStreamStateChanged(mapOf("state" to "cameraSwitch"))

      try {
        camera.switchCamera()
        isFrontCamera = !isFrontCamera

        if (isFrontCamera && isFlashOn) {
          try { camera.disableLantern() } catch (_: Exception) {}
          isFlashOn = false
        }

        if (isStreaming) {
          // The first frames from the new camera are inter frames that still
          // reference the old camera's GOP, so viewers sit on a frozen picture
          // until the next scheduled keyframe. Asking for one right away cuts
          // that from up to a full keyframe interval down to a frame or two.
          postDelayed({ try { camera.requestKeyFrame() } catch (_: Exception) {} }, 150)
          postDelayed({ try { camera.requestKeyFrame() } catch (_: Exception) {} }, 450)
        }

        postDelayed({
          isSwitchingCamera = false
          emitStreamStateChanged(
            mapOf("state" to if (isStreaming) "streaming" else "idle")
          )
        }, 600)
      } catch (e: Exception) {
        Log.e(TAG, "switchCamera failed", e)
        postDelayed({
          isSwitchingCamera = false
          emitStreamStateChanged(mapOf("state" to "failed"))
        }, 1500)
      }
    }
  }

  fun toggleFlash() {
    post {
      val camera = rtmpCamera ?: return@post
      if (!isFrontCamera) {
        try {
          if (isFlashOn) camera.disableLantern() else camera.enableLantern()
          isFlashOn = !isFlashOn
        } catch (e: Exception) { Log.e(TAG, "toggleFlash failed", e) }
      }
    }
  }

  fun toggleMute() {
    post {
      val camera = rtmpCamera ?: return@post
      try {
        if (isMuted) camera.enableAudio() else camera.disableAudio()
        isMuted = !isMuted
      } catch (e: Exception) { Log.e(TAG, "toggleMute failed", e) }
    }
  }

  override fun onConnectionStarted(url: String) {
    post { emitStreamStateChanged(mapOf("state" to "connecting")) }
  }

  override fun onConnectionSuccess() {
    post {
      emitConnectionSuccess()
      emitStreamStateChanged(mapOf("state" to "streaming"))
    }
  }

  override fun onConnectionFailed(reason: String) {
    post {
      isStreaming = false
      emitConnectionFailed(mapOf("msg" to reason))
      emitStreamStateChanged(mapOf("state" to "failed"))
    }
  }

  override fun onNewBitrate(bitrate: Long) {
    post { emitBitrateUpdate(mapOf("bitrate" to bitrate)) }
  }

  override fun onDisconnect() {
    if (isStoppingIntentionally) {
      isStoppingIntentionally = false
      return
    }
    if (isBackgrounding) return
    post {
      isStreaming = false
      emitDisconnect()
      emitStreamStateChanged(mapOf("state" to "disconnected"))
    }
  }

  override fun onAuthError() {
    post {
      isStreaming = false
      emitConnectionFailed(mapOf("msg" to "Auth error"))
      emitStreamStateChanged(mapOf("state" to "auth_error"))
    }
  }

  override fun onAuthSuccess() {}

  override fun onDetachedFromWindow() {
    super.onDetachedFromWindow()
    try {
      if (isStreaming) rtmpCamera?.stopStream()
      rtmpCamera?.stopPreview()
    } catch (e: Exception) { Log.e(TAG, "cleanup failed", e) }
    rtmpCamera = null
    isCameraInitialized = false
    liveInstances.remove(this)
  }
}
