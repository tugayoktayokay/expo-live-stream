package expo.modules.livestream

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.util.Log

import androidx.core.content.ContextCompat
import com.pedro.common.ConnectChecker
import com.pedro.encoder.utils.CodecUtil
import com.pedro.library.rtmp.RtmpCamera2
import com.pedro.library.view.OpenGlView
import expo.modules.kotlin.AppContext
import expo.modules.kotlin.viewevent.EventDispatcher
import expo.modules.kotlin.views.ExpoView

class PublisherView(
  context: Context,
  appContext: AppContext
) : ExpoView(context, appContext), ConnectChecker {

  companion object {
    private const val TAG = "ExpoLiveStream"
    @JvmStatic
    var activeInstance: PublisherView? = null
      private set
  }

  // UI
  private var openGlView: OpenGlView? = null
  private var rtmpCamera: RtmpCamera2? = null

  // Props
  var url: String = ""
  var streamKey: String = ""
  var videoWidth: Int = 720
  var videoHeight: Int = 1280
  var videoBitrate: Int = 2_000_000
  var videoFps: Int = 30
  var audioBitrate: Int = 128_000
  var audioSampleRate: Int = 44100
  var isFrontCamera: Boolean = true

  // Events
  val onConnectionSuccess by EventDispatcher()
  val onConnectionFailed by EventDispatcher()
  val onDisconnect by EventDispatcher()
  val onStreamStateChanged by EventDispatcher()
  val onBitrateUpdate by EventDispatcher()

  // State
  private var isStreaming = false
  private var isMuted = false
  private var isFlashOn = false
  private var isSurfaceReady = false
  private var isCameraInitialized = false
  private var isSwitchingCamera = false
  private var lastStreamUrl: String? = null
  private var wasStreamingBeforeBackground = false

  init {
    activeInstance = this
    Log.d(TAG, "View created, activeInstance set")
    setupView()
  }

  override fun onWindowFocusChanged(hasWindowFocus: Boolean) {
    super.onWindowFocusChanged(hasWindowFocus)
    if (!hasWindowFocus) {
      Log.d(TAG, "Window lost focus (background)")
      wasStreamingBeforeBackground = isStreaming
      try {
        val camera = rtmpCamera ?: return
        if (isStreaming) { camera.stopStream(); isStreaming = false }
        camera.stopPreview()
        isCameraInitialized = false
      } catch (e: Exception) { Log.w(TAG, "Error on background", e) }
    } else {
      Log.d(TAG, "Window gained focus (foreground)")
      if (!isCameraInitialized && isSurfaceReady) {
        post { try { reinitCamera() } catch (e: Exception) { Log.e(TAG, "Error on foreground", e) } }
      }
      if (wasStreamingBeforeBackground) {
        wasStreamingBeforeBackground = false
        post {
          onStreamStateChanged(mapOf("state" to "stopped"))
          onDisconnect(emptyMap<String, Any>())
        }
      }
    }
  }

  private fun reinitCamera() {
    val camera = rtmpCamera ?: return
    val rotation = com.pedro.encoder.input.video.CameraHelper.getCameraOrientation(context)
    val lw = maxOf(videoWidth, videoHeight)
    val lh = minOf(videoWidth, videoHeight)
    camera.prepareVideo(lw, lh, videoFps, videoBitrate, rotation)
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
    }
    addView(openGlView)
    post { postDelayed({ isSurfaceReady = true; tryInitCamera() }, 500) }
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
      
      // Default hardware codec for fluid preview. 
      // iFrameInterval=1 and requestKeyFrame will handle VLC freezing.      
      rtmpCamera = camera

      val rotation = com.pedro.encoder.input.video.CameraHelper.getCameraOrientation(context)
      val lw = maxOf(videoWidth, videoHeight)
      val lh = minOf(videoWidth, videoHeight)
      
      Log.d(TAG, "prepareVideo: ${lw}x${lh} @ ${videoBitrate}bps, rotation=$rotation")
      // iFrameInterval=1 for quick keyframe recovery
      val videoPrepared = camera.prepareVideo(lw, lh, videoFps, videoBitrate, 1, rotation)
      val audioPrepared = camera.prepareAudio(audioBitrate, audioSampleRate, false)
      Log.d(TAG, "prepare: video=$videoPrepared, audio=$audioPrepared")

      val facing = if (isFrontCamera)
        com.pedro.encoder.input.video.CameraHelper.Facing.FRONT
      else
        com.pedro.encoder.input.video.CameraHelper.Facing.BACK
      camera.startPreview(facing)
      isCameraInitialized = true
      Log.d(TAG, "Camera initialized with SOFTWARE codec")
    } catch (e: Exception) {
      Log.e(TAG, "Failed to init camera", e)
      isCameraInitialized = false
    }
  }

  fun start(urlOverride: String?) {
    val camera = rtmpCamera
    if (camera == null || !isCameraInitialized) {
      Log.e(TAG, "start: camera not ready")
      onConnectionFailed(mapOf("msg" to "Camera not ready"))
      return
    }

    val targetUrl = if (!urlOverride.isNullOrEmpty()) urlOverride else url
    val fullUrl = if (streamKey.isNotEmpty() && !targetUrl.endsWith("/$streamKey")) {
      "$targetUrl/$streamKey"
    } else targetUrl

    if (fullUrl.isEmpty()) { onConnectionFailed(mapOf("msg" to "URL is empty")); return }

    // Re-prepare before stream
    val rotation = com.pedro.encoder.input.video.CameraHelper.getCameraOrientation(context)
    val lw = maxOf(videoWidth, videoHeight)
    val lh = minOf(videoWidth, videoHeight)
    camera.prepareVideo(lw, lh, videoFps, videoBitrate, 1, rotation)
    camera.prepareAudio(audioBitrate, audioSampleRate, false)

    post {
      try {
        Log.d(TAG, "startStream: $fullUrl")
        lastStreamUrl = fullUrl
        isStreaming = true
        onStreamStateChanged(mapOf("state" to "connecting"))
        camera.startStream(fullUrl)
        if (isMuted) { camera.disableAudio() }
      } catch (e: Exception) {
        Log.e(TAG, "startStream failed", e)
        isStreaming = false
        onConnectionFailed(mapOf("msg" to (e.message ?: "Unknown error")))
      }
    }
  }

  fun stop() {
    Log.d(TAG, "stop")
    try {
      if (isStreaming) { rtmpCamera?.stopStream(); isStreaming = false }
    } catch (e: Exception) { Log.e(TAG, "stop failed", e) }
    onDisconnect(emptyMap<String, Any>())
    onStreamStateChanged(mapOf("state" to "stopped"))
    // Restart preview
    try {
      val facing = if (isFrontCamera)
        com.pedro.encoder.input.video.CameraHelper.Facing.FRONT
      else
        com.pedro.encoder.input.video.CameraHelper.Facing.BACK
      rtmpCamera?.startPreview(facing)
    } catch (_: Exception) {}
  }

  fun switchCamera() {
    post {
      val camera = rtmpCamera ?: return@post
      if (isSwitchingCamera) { Log.d(TAG, "switchCamera: in progress"); return@post }
      isSwitchingCamera = true

      try {
        Log.d(TAG, "switchCamera: frontCamera=$isFrontCamera, streaming=$isStreaming")
        camera.switchCamera()
        isFrontCamera = !isFrontCamera

        if (isFrontCamera && isFlashOn) {
          try { camera.disableLantern() } catch (_: Exception) {}
          isFlashOn = false
        }

        // Force keyframes — software codec should honor this properly
        if (isStreaming) {
          postDelayed({
            try {
              camera.requestKeyFrame()
              Log.d(TAG, "switchCamera: keyframe requested at 200ms")
            } catch (e: Exception) { Log.w(TAG, "requestKeyFrame 200ms failed: ${e.message}") }
          }, 200)
          postDelayed({
            try {
              camera.requestKeyFrame()
              Log.d(TAG, "switchCamera: keyframe requested at 1s")
            } catch (e: Exception) { Log.w(TAG, "requestKeyFrame 1s failed: ${e.message}") }
          }, 1000)
        }

        Log.d(TAG, "switchCamera: success, frontCamera=$isFrontCamera")
      } catch (e: Exception) {
        Log.e(TAG, "switchCamera failed", e)
      }

      postDelayed({ isSwitchingCamera = false }, 1500)
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
        Log.d(TAG, "toggleMute: isMuted=$isMuted")
      } catch (e: Exception) { Log.e(TAG, "toggleMute failed", e) }
    }
  }

  // ConnectChecker callbacks
  override fun onConnectionStarted(url: String) {
    Log.d(TAG, "onConnectionStarted: $url")
    post { onStreamStateChanged(mapOf("state" to "connecting")) }
  }

  override fun onConnectionSuccess() {
    Log.d(TAG, "onConnectionSuccess")
    post {
      onConnectionSuccess(emptyMap<String, Any>())
      onStreamStateChanged(mapOf("state" to "streaming"))
    }
  }

  override fun onConnectionFailed(reason: String) {
    Log.e(TAG, "onConnectionFailed: $reason")
    post {
      isStreaming = false
      onConnectionFailed(mapOf("msg" to reason))
      onStreamStateChanged(mapOf("state" to "failed"))
    }
  }

  override fun onNewBitrate(bitrate: Long) {
    post { onBitrateUpdate(mapOf("bitrate" to bitrate)) }
  }

  override fun onDisconnect() {
    Log.d(TAG, "onDisconnect")
    post {
      isStreaming = false
      onDisconnect(emptyMap<String, Any>())
      onStreamStateChanged(mapOf("state" to "disconnected"))
    }
  }

  override fun onAuthError() {
    post { isStreaming = false; onConnectionFailed(mapOf("msg" to "Auth error")) }
  }

  override fun onAuthSuccess() { Log.d(TAG, "onAuthSuccess") }

  override fun onDetachedFromWindow() {
    super.onDetachedFromWindow()
    Log.d(TAG, "onDetachedFromWindow")
    try {
      if (isStreaming) rtmpCamera?.stopStream()
      rtmpCamera?.stopPreview()
    } catch (e: Exception) { Log.e(TAG, "cleanup failed", e) }
    rtmpCamera = null
    isCameraInitialized = false
    if (activeInstance == this) { activeInstance = null }
  }
}
