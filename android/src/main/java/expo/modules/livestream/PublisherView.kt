package expo.modules.livestream

import android.Manifest
import android.content.ContentValues
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.util.Log
import java.io.File
import java.io.FileInputStream

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
        // Connect secondary destinations if any
        if (secondaryUrls.isNotEmpty()) {
          postDelayed({ connectSecondary() }, 2000)
        }
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
      if (rtmpCamera?.isRecording == true) { rtmpCamera?.stopRecord(); Log.d(TAG, "Recording auto-stopped") }
      disconnectSecondary()
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

  // ── Local Recording ──

  fun startRecording(): String {
    val camera = rtmpCamera
    val timestamp = System.currentTimeMillis()
    val path = "${context.cacheDir}/recording_$timestamp.mp4"
    Log.d(TAG, "startRecording: path=$path, isStreaming=$isStreaming, camera=${camera != null}, camera.isStreaming=${camera?.isStreaming}, camera.isRecording=${camera?.isRecording}")

    if (camera == null) {
      Log.e(TAG, "startRecording: rtmpCamera is null!")
      return ""
    }

    try {
      camera.startRecord(path)
      lastRecordingPath = path
      Log.d(TAG, "startRecording: called startRecord, isRecording=${camera.isRecording}")
    } catch (e: Exception) {
      Log.e(TAG, "startRecording failed", e)
    }
    return path
  }

  private var lastRecordingPath: String? = null

  fun stopRecording() {
    val camera = rtmpCamera
    Log.d(TAG, "stopRecording: camera.isRecording=${camera?.isRecording}")
    try {
      camera?.stopRecord()
      Log.d(TAG, "stopRecording: done, isRecording=${camera?.isRecording}")
      // Save to gallery
      lastRecordingPath?.let { path ->
        saveToGallery(path)
      }
    } catch (e: Exception) {
      Log.e(TAG, "stopRecording failed", e)
    }
  }

  private fun saveToGallery(cachePath: String) {
    try {
      val file = File(cachePath)
      if (!file.exists() || file.length() == 0L) {
        Log.e(TAG, "saveToGallery: file doesn't exist or is empty: $cachePath")
        return
      }

      val resolver = context.contentResolver
      val contentValues = ContentValues().apply {
        put(MediaStore.Video.Media.DISPLAY_NAME, file.name)
        put(MediaStore.Video.Media.MIME_TYPE, "video/mp4")
        put(MediaStore.Video.Media.DATE_ADDED, System.currentTimeMillis() / 1000)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
          put(MediaStore.Video.Media.RELATIVE_PATH, Environment.DIRECTORY_MOVIES + "/LiveStream")
          put(MediaStore.Video.Media.IS_PENDING, 1)
        }
      }

      val uri = resolver.insert(MediaStore.Video.Media.EXTERNAL_CONTENT_URI, contentValues)
      if (uri == null) {
        Log.e(TAG, "saveToGallery: failed to create MediaStore entry")
        return
      }

      resolver.openOutputStream(uri)?.use { output ->
        FileInputStream(file).use { input ->
          input.copyTo(output)
        }
      }

      if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
        contentValues.clear()
        contentValues.put(MediaStore.Video.Media.IS_PENDING, 0)
        resolver.update(uri, contentValues, null, null)
      }

      Log.d(TAG, "saveToGallery: saved to gallery: $uri")
      // Delete cache file
      file.delete()
    } catch (e: Exception) {
      Log.e(TAG, "saveToGallery failed", e)
    }
  }

  fun isRecording(): Boolean = rtmpCamera?.isRecording ?: false

  // ── Camera Controls ──

  fun setZoom(level: Float) {
    val camera = rtmpCamera ?: return
    try {
      // Camera2Base.setZoom(Float) — normalized 0..1 mapped to zoom range
      val range = camera.zoomRange
      val zoomValue = range.lower + level.coerceIn(0f, 1f) * (range.upper - range.lower)
      camera.setZoom(zoomValue)
      Log.d(TAG, "setZoom: level=$level, zoomValue=$zoomValue, range=${range.lower}..${range.upper}")
    } catch (e: Exception) {
      Log.e(TAG, "setZoom failed", e)
    }
  }

  fun getZoom(): Float {
    val camera = rtmpCamera ?: return 0f
    try {
      val range = camera.zoomRange
      val span = range.upper - range.lower
      return if (span > 0) (camera.zoom - range.lower) / span else 0f
    } catch (e: Exception) {
      return 0f
    }
  }

  fun getMaxZoom(): Float {
    try {
      val range = rtmpCamera?.zoomRange ?: return 1f
      return range.upper
    } catch (e: Exception) {
      return 1f
    }
  }

  fun setExposureCompensation(value: Float) {
    val camera = rtmpCamera ?: return
    try {
      val cameraManager = context.getSystemService(Context.CAMERA_SERVICE) as android.hardware.camera2.CameraManager
      val facing = if (isFrontCamera) android.hardware.camera2.CameraCharacteristics.LENS_FACING_FRONT
                   else android.hardware.camera2.CameraCharacteristics.LENS_FACING_BACK
      var cameraId = cameraManager.cameraIdList.first()
      for (id in cameraManager.cameraIdList) {
        val chars = cameraManager.getCameraCharacteristics(id)
        if (chars.get(android.hardware.camera2.CameraCharacteristics.LENS_FACING) == facing) { cameraId = id; break }
      }
      val characteristics = cameraManager.getCameraCharacteristics(cameraId)
      val range = characteristics.get(android.hardware.camera2.CameraCharacteristics.CONTROL_AE_COMPENSATION_RANGE) ?: return
      val min = range.lower
      val max = range.upper
      val exposure = (min + (value.coerceIn(-1f, 1f) + 1f) / 2f * (max - min)).toInt()
      camera.setExposure(exposure)
      Log.d(TAG, "setExposureCompensation: value=$value, exposure=$exposure (range=$min..$max)")
    } catch (e: Exception) {
      Log.e(TAG, "setExposureCompensation failed", e)
    }
  }

  fun getExposureCompensation(): Float {
    val camera = rtmpCamera ?: return 0f
    try {
      val cameraManager = context.getSystemService(Context.CAMERA_SERVICE) as android.hardware.camera2.CameraManager
      val facing = if (isFrontCamera) android.hardware.camera2.CameraCharacteristics.LENS_FACING_FRONT
                   else android.hardware.camera2.CameraCharacteristics.LENS_FACING_BACK
      var cameraId = cameraManager.cameraIdList.first()
      for (id in cameraManager.cameraIdList) {
        val chars = cameraManager.getCameraCharacteristics(id)
        if (chars.get(android.hardware.camera2.CameraCharacteristics.LENS_FACING) == facing) { cameraId = id; break }
      }
      val characteristics = cameraManager.getCameraCharacteristics(cameraId)
      val range = characteristics.get(android.hardware.camera2.CameraCharacteristics.CONTROL_AE_COMPENSATION_RANGE) ?: return 0f
      val min = range.lower
      val max = range.upper
      return if (max > min) (camera.exposure.toFloat() - min) / (max - min) * 2f - 1f else 0f
    } catch (e: Exception) {
      return 0f
    }
  }

  // ── Filters ──

  private var currentFilter: String = "none"

  fun setFilter(name: String) {
    val camera = rtmpCamera ?: return
    val glView = openGlView ?: return
    try {
      currentFilter = name
      val filter = when (name.lowercase()) {
        "sepia" -> com.pedro.encoder.input.gl.render.filters.SepiaFilterRender()
        "grayscale", "greyscale" -> com.pedro.encoder.input.gl.render.filters.GreyScaleFilterRender()
        "negative" -> com.pedro.encoder.input.gl.render.filters.NegativeFilterRender()
        "brightness" -> com.pedro.encoder.input.gl.render.filters.BrightnessFilterRender()
        "contrast" -> com.pedro.encoder.input.gl.render.filters.ContrastFilterRender()
        "saturation" -> com.pedro.encoder.input.gl.render.filters.SaturationFilterRender()
        "edge_detection" -> com.pedro.encoder.input.gl.render.filters.EdgeDetectionFilterRender()
        "beauty" -> com.pedro.encoder.input.gl.render.filters.BeautyFilterRender()
        "cartoon" -> com.pedro.encoder.input.gl.render.filters.CartoonFilterRender()
        "glitch" -> com.pedro.encoder.input.gl.render.filters.GlitchFilterRender()
        "snow" -> com.pedro.encoder.input.gl.render.filters.SnowFilterRender()
        "blur" -> com.pedro.encoder.input.gl.render.filters.BlurFilterRender()
        else -> com.pedro.encoder.input.gl.render.filters.NoFilterRender()
      }
      glView.setFilter(filter)
      Log.d(TAG, "setFilter: $name")
    } catch (e: Exception) {
      Log.e(TAG, "setFilter failed", e)
    }
  }

  fun getFilter(): String = currentFilter

  fun getAvailableFilters(): List<String> = listOf(
    "none", "sepia", "grayscale", "negative", "brightness",
    "contrast", "saturation", "edge_detection", "beauty",
    "cartoon", "glitch", "snow", "blur"
  )

  // ── Phase 7: Multi-Destination ──

  private val secondaryUrls = mutableListOf<String>()
  private val secondaryClients = mutableListOf<com.pedro.rtmp.rtmp.RtmpClient>()

  fun startMulti(urls: List<String>) {
    stopMulti() // Clean up any existing
    secondaryUrls.clear()
    secondaryUrls.addAll(urls)
    Log.d(TAG, "startMulti: ${urls.size} destinations registered")

    // If already streaming, connect secondary destinations immediately
    if (isStreaming) {
      connectSecondary()
    }
  }

  fun stopMulti() {
    disconnectSecondary()
    secondaryUrls.clear()
    Log.d(TAG, "stopMulti: all secondary destinations cleared")
  }

  fun getMultiDestinations(): List<String> = secondaryUrls.toList()

  private fun connectSecondary() {
    val camera = rtmpCamera ?: return
    for (url in secondaryUrls) {
      try {
        val client = com.pedro.rtmp.rtmp.RtmpClient(object : com.pedro.common.ConnectChecker {
          override fun onConnectionStarted(url: String) {
            Log.d(TAG, "Secondary connected: $url")
          }
          override fun onConnectionSuccess() {
            Log.d(TAG, "Secondary connection success")
          }
          override fun onConnectionFailed(reason: String) {
            Log.e(TAG, "Secondary connection failed: $reason")
          }
          override fun onNewBitrate(bitrate: Long) {}
          override fun onDisconnect() {
            Log.d(TAG, "Secondary disconnected")
          }
          override fun onAuthError() {
            Log.e(TAG, "Secondary auth error")
          }
          override fun onAuthSuccess() {}
        })
        // Copy codec info from primary stream
        client.setVideoResolution(camera.getStreamWidth(), camera.getStreamHeight())
        client.setFps(videoFps)
        client.connect(url)
        secondaryClients.add(client)
        Log.d(TAG, "Secondary client connected to: $url")
      } catch (e: Exception) {
        Log.e(TAG, "Failed to connect secondary to $url", e)
      }
    }
  }

  private fun disconnectSecondary() {
    for (client in secondaryClients) {
      try {
        client.disconnect()
      } catch (e: Exception) {
        Log.w(TAG, "Secondary disconnect error", e)
      }
    }
    secondaryClients.clear()
  }

  // Forward encoded frames to secondary destinations
  fun forwardVideoFrame(buffer: java.nio.ByteBuffer, info: android.media.MediaCodec.BufferInfo) {
    for (client in secondaryClients) {
      try {
        if (client.isStreaming) {
          client.sendVideo(buffer.duplicate(), info)
        }
      } catch (e: Exception) {
        Log.w(TAG, "Failed to forward video to secondary", e)
      }
    }
  }

  fun forwardAudioFrame(buffer: java.nio.ByteBuffer, info: android.media.MediaCodec.BufferInfo) {
    for (client in secondaryClients) {
      try {
        if (client.isStreaming) {
          client.sendAudio(buffer.duplicate(), info)
        }
      } catch (e: Exception) {
        Log.w(TAG, "Failed to forward audio to secondary", e)
      }
    }
  }


  // ── Phase 8: Text Overlay ──

  private var overlayFilter: com.pedro.encoder.input.gl.render.filters.`object`.TextObjectFilterRender? = null

  fun setTextOverlay(text: String, x: Float, y: Float, size: Float) {
    val glView = openGlView ?: return
    try {
      if (overlayFilter != null) {
        // Remove previous overlay
        glView.setFilter(com.pedro.encoder.input.gl.render.filters.NoFilterRender())
      }
      val textFilter = com.pedro.encoder.input.gl.render.filters.`object`.TextObjectFilterRender()
      textFilter.setText(text, size, android.graphics.Color.WHITE)
      textFilter.setPosition(x, y)
      glView.setFilter(textFilter)
      overlayFilter = textFilter
      Log.d(TAG, "setTextOverlay: '$text' at ($x,$y) size=$size")
    } catch (e: Exception) {
      Log.e(TAG, "setTextOverlay failed", e)
    }
  }

  fun clearOverlay() {
    val glView = openGlView ?: return
    try {
      glView.setFilter(com.pedro.encoder.input.gl.render.filters.NoFilterRender())
      overlayFilter = null
      Log.d(TAG, "clearOverlay")
    } catch (e: Exception) {
      Log.e(TAG, "clearOverlay failed", e)
    }
  }

  // ── Phase 9: Audio Mixing ──

  private var backgroundMusicPath: String? = null

  fun setBackgroundMusic(path: String, volume: Float) {
    backgroundMusicPath = path
    Log.d(TAG, "setBackgroundMusic: path=$path, volume=$volume")
    // RootEncoder doesn't natively support audio mixing
    // This stores the path for potential MediaPlayer overlay
  }

  fun stopBackgroundMusic() {
    backgroundMusicPath = null
    Log.d(TAG, "stopBackgroundMusic")
  }

  // ── Phase 10: Advanced ──

  fun setAdaptiveBitrate(enabled: Boolean) {
    val camera = rtmpCamera ?: return
    // RootEncoder supports adaptive bitrate via BitrateAdapter
    Log.d(TAG, "setAdaptiveBitrate: $enabled")
  }

  fun getStreamStats(): Map<String, Any> {
    val camera = rtmpCamera ?: return emptyMap()
    return mapOf(
      "isStreaming" to isStreaming,
      "isRecording" to isRecording(),
      "isFrontCamera" to isFrontCamera,
      "currentFilter" to currentFilter,
      "secondaryDestinations" to secondaryUrls.size
    )
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
        // Reset zoom after camera switch
        try { camera.setZoom(camera.zoomRange.lower) } catch (_: Exception) {}
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
    Log.d(TAG, "onDetachedFromWindow — full cleanup")
    try {
      // Stop recording first
      if (rtmpCamera?.isRecording == true) {
        rtmpCamera?.stopRecord()
        Log.d(TAG, "cleanup: recording stopped")
      }
      // Disconnect secondary streams
      disconnectSecondary()
      // Stop primary stream
      if (isStreaming) {
        rtmpCamera?.stopStream()
        isStreaming = false
        Log.d(TAG, "cleanup: stream stopped")
      }
      // Stop preview
      rtmpCamera?.stopPreview()
    } catch (e: Exception) { Log.e(TAG, "cleanup failed", e) }
    rtmpCamera = null
    openGlView = null
    isCameraInitialized = false
    if (activeInstance == this) { activeInstance = null }
  }
}
