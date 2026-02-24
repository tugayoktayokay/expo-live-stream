package expo.modules.livestream

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.util.Log

import androidx.core.content.ContextCompat
import com.pedro.common.ConnectChecker
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
  var isFrontCamera: Boolean = false

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
  private var wasStreamingBeforeBackground = false

  init {
    activeInstance = this
    Log.d(TAG, "View created, activeInstance set")
    setupView()
  }

  // Lifecycle: handle background/foreground transitions
  override fun onWindowFocusChanged(hasWindowFocus: Boolean) {
    super.onWindowFocusChanged(hasWindowFocus)
    if (!hasWindowFocus) {
      // Going to background — stop everything safely
      Log.d(TAG, "Window lost focus (background), stopping camera")
      wasStreamingBeforeBackground = isStreaming
      try {
        val camera = rtmpCamera ?: return
        if (isStreaming) {
          camera.stopStream()
          isStreaming = false
        }
        camera.stopPreview()
        isCameraInitialized = false
      } catch (e: Exception) {
        Log.w(TAG, "Error stopping camera on background", e)
      }
    } else {
      // Coming to foreground — restart preview
      Log.d(TAG, "Window gained focus (foreground), restarting preview")
      if (!isCameraInitialized && isSurfaceReady) {
        post {
          try {
            reinitCamera()
          } catch (e: Exception) {
            Log.e(TAG, "Error restarting camera on foreground", e)
          }
        }
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
    val landscapeWidth = maxOf(videoWidth, videoHeight)
    val landscapeHeight = minOf(videoWidth, videoHeight)
    camera.prepareVideo(landscapeWidth, landscapeHeight, videoFps, videoBitrate, rotation)
    camera.prepareAudio(audioBitrate, audioSampleRate, false)

    val facing = if (isFrontCamera)
      com.pedro.encoder.input.video.CameraHelper.Facing.FRONT
    else
      com.pedro.encoder.input.video.CameraHelper.Facing.BACK

    camera.startPreview(facing)
    isCameraInitialized = true
    updateMirror()
    Log.d(TAG, "Camera reinitialized after foreground")
  }

  private fun setupView() {
    openGlView = OpenGlView(context).apply {
      layoutParams = LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT)
    }
    addView(openGlView)
    
    post {
      postDelayed({
        isSurfaceReady = true
        tryInitCamera()
      }, 500)
    }
  }

  private fun hasPermissions(): Boolean {
    val cam = ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA)
    val mic = ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO)
    val hasCam = cam == PackageManager.PERMISSION_GRANTED
    val hasMic = mic == PackageManager.PERMISSION_GRANTED
    Log.d(TAG, "Permissions - Camera: $hasCam, Mic: $hasMic")
    return hasCam && hasMic
  }

  private fun tryInitCamera() {
    if (!isSurfaceReady || isCameraInitialized) return

    if (!hasPermissions()) {
      Log.w(TAG, "tryInitCamera: missing permissions, skipping")
      return
    }

    val glView = openGlView ?: return
    try {
      Log.d(TAG, "Creating RtmpCamera2...")
      rtmpCamera = RtmpCamera2(glView, this)

      val camera = rtmpCamera!!

      val rotation = com.pedro.encoder.input.video.CameraHelper.getCameraOrientation(context)
      Log.d(TAG, "Camera orientation: $rotation")

      val landscapeWidth = maxOf(videoWidth, videoHeight)
      val landscapeHeight = minOf(videoWidth, videoHeight)

      Log.d(TAG, "prepareVideo: ${landscapeWidth}x${landscapeHeight} @ ${videoBitrate}bps, rotation=$rotation")
      val videoPrepared = camera.prepareVideo(landscapeWidth, landscapeHeight, videoFps, videoBitrate, rotation)
      Log.d(TAG, "prepareVideo result: $videoPrepared")

      Log.d(TAG, "prepareAudio: bitrate=$audioBitrate sampleRate=$audioSampleRate")
      val audioPrepared = camera.prepareAudio(audioBitrate, audioSampleRate, false)
      Log.d(TAG, "prepareAudio result: $audioPrepared")

      val facing = if (isFrontCamera)
        com.pedro.encoder.input.video.CameraHelper.Facing.FRONT
      else
        com.pedro.encoder.input.video.CameraHelper.Facing.BACK
      
      Log.d(TAG, "startPreview: facing=$facing")
      camera.startPreview(facing)

      isCameraInitialized = true
      updateMirror()
      Log.d(TAG, "Camera initialized successfully")
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
    } else {
      targetUrl
    }

    if (fullUrl.isEmpty()) {
      onConnectionFailed(mapOf("msg" to "URL is empty"))
      return
    }

    // Re-prepare encoders before starting stream
    val rotation = com.pedro.encoder.input.video.CameraHelper.getCameraOrientation(context)
    val landscapeWidth = maxOf(videoWidth, videoHeight)
    val landscapeHeight = minOf(videoWidth, videoHeight)
    
    val videoPrepared = camera.prepareVideo(landscapeWidth, landscapeHeight, videoFps, videoBitrate, rotation)
    val audioPrepared = camera.prepareAudio(audioBitrate, audioSampleRate, false)
    Log.d(TAG, "Re-prepare before stream: video=$videoPrepared, audio=$audioPrepared")

    if (!videoPrepared || !audioPrepared) {
      onConnectionFailed(mapOf("msg" to "Failed to prepare encoder"))
      return
    }

    post {
      try {
        Log.d(TAG, "startStream (main thread): $fullUrl")
        isStreaming = true
        onStreamStateChanged(mapOf("state" to "connecting"))
        camera.startStream(fullUrl)
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
      if (isStreaming) {
        rtmpCamera?.stopStream()
        isStreaming = false
      }
    } catch (e: Exception) {
      Log.e(TAG, "stop failed", e)
    }
    onDisconnect(emptyMap<String, Any>())
    onStreamStateChanged(mapOf("state" to "stopped"))

    // Restart preview after stopping stream
    try {
      val facing = if (isFrontCamera)
        com.pedro.encoder.input.video.CameraHelper.Facing.FRONT
      else
        com.pedro.encoder.input.video.CameraHelper.Facing.BACK
      rtmpCamera?.startPreview(facing)
      Log.d(TAG, "Preview restarted after stop")
    } catch (e: Exception) {
      Log.e(TAG, "Failed to restart preview after stop", e)
    }
  }

  fun switchCamera() {
    val camera = rtmpCamera
    if (camera == null) {
      Log.w(TAG, "switchCamera: camera is null")
      return
    }
    try {
      Log.d(TAG, "switchCamera: current frontCamera=$isFrontCamera")
      camera.switchCamera()
      isFrontCamera = !isFrontCamera
      updateMirror()
      Log.d(TAG, "switchCamera: success, now frontCamera=$isFrontCamera")
    } catch (e: Exception) {
      Log.e(TAG, "switchCamera failed", e)
    }
  }

  private fun updateMirror() {
    openGlView?.scaleX = if (isFrontCamera) -1f else 1f
  }

  fun toggleFlash() {
    val camera = rtmpCamera ?: return
    if (!isFrontCamera) {
      try {
        if (isFlashOn) {
          camera.disableLantern()
        } else {
          camera.enableLantern()
        }
        isFlashOn = !isFlashOn
        Log.d(TAG, "toggleFlash: isFlashOn=$isFlashOn")
      } catch (e: Exception) {
        Log.e(TAG, "toggleFlash failed", e)
      }
    } else {
      Log.w(TAG, "toggleFlash: flash not available on front camera")
    }
  }

  fun toggleMute() {
    val camera = rtmpCamera ?: return
    try {
      if (isMuted) {
        camera.enableAudio()
      } else {
        camera.disableAudio()
      }
      isMuted = !isMuted
      Log.d(TAG, "toggleMute: isMuted=$isMuted")
    } catch (e: Exception) {
      Log.e(TAG, "toggleMute failed", e)
    }
  }

  private fun cleanupCamera() {
    try {
      if (isStreaming) {
        rtmpCamera?.stopStream()
        isStreaming = false
      }
      rtmpCamera?.stopPreview()
    } catch (e: Exception) {
      Log.e(TAG, "cleanup failed", e)
    }
    isCameraInitialized = false
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
    post {
      onBitrateUpdate(mapOf("bitrate" to bitrate))
    }
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
    Log.e(TAG, "onAuthError")
    post {
      isStreaming = false
      onConnectionFailed(mapOf("msg" to "Authentication error"))
    }
  }

  override fun onAuthSuccess() {
    Log.d(TAG, "onAuthSuccess")
  }

  override fun onDetachedFromWindow() {
    super.onDetachedFromWindow()
    Log.d(TAG, "onDetachedFromWindow")
    cleanupCamera()
    rtmpCamera = null
    if (activeInstance == this) {
      Log.d(TAG, "activeInstance cleared")
      activeInstance = null
    }
  }
}
