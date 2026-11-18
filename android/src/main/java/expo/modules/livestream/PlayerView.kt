package expo.modules.livestream

import android.content.Context
import android.graphics.Matrix
import android.graphics.SurfaceTexture
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.Surface
import android.view.TextureView
import android.view.ViewGroup
import android.widget.LinearLayout
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.VideoSize
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.rtmp.RtmpDataSource
import androidx.media3.exoplayer.DefaultLoadControl
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.audio.AudioSink
import androidx.media3.exoplayer.audio.DefaultAudioSink
import androidx.media3.exoplayer.audio.DefaultAudioTrackBufferSizeProvider
import androidx.media3.exoplayer.source.ProgressiveMediaSource
import java.util.concurrent.CopyOnWriteArrayList

@UnstableApi
class PlayerView(context: Context) : LinearLayout(context) {

  companion object {
    private const val TAG = "ExpoLiveStreamPlayer"

    /** See [PublisherView.activeInstance]: same stack, same reasoning. */
    private val liveInstances = CopyOnWriteArrayList<PlayerView>()

    @JvmStatic
    val activeInstance: PlayerView?
      get() = liveInstances.lastOrNull()

    /**
     * RTMP carries no seekable timeline, so ExoPlayer treats it as a
     * progressive stream and happily lets the playhead fall behind whatever it
     * has buffered. Left alone the lag grows for the whole session, which is
     * exactly what a live viewer must not see, so playback is nudged back to
     * the buffered edge once it drifts past this.
     */
    private const val MAX_LIVE_DRIFT_MS = 10000L
    private const val TARGET_LIVE_DRIFT_MS = 4000L
    private const val EXTREME_LIVE_DRIFT_MS = 20000L
    /** Delay before surfacing transient buffering state to JS UI. */
    private const val BUFFERING_REPORT_DELAY_MS = 800L
    /** How often the watchdog looks at drift and at the frame clock. */
    private const val TICK_MS = 1000L

    /** No rendered frame for this long while playing counts as a stall. */
    private const val STALL_TIMEOUT_MS = 8000L

    /**
     * Connecting or buffering this long without a frame and without a player
     * error (an RTMP socket that is open but silent) counts as a stall too;
     * otherwise the view waits on a spinner forever.
     */
    private const val NO_FRAME_TIMEOUT_MS = 15000L

    /**
     * Reconnect delays grow from 3.5 s to 15 s, so ten attempts ride out about
     * two minutes of a bad network or a restarting encoder instead of giving up
     * after 35 s, without hammering the server while it is down.
     */
    private const val RECONNECT_BASE_DELAY_MS = 3500L
    private const val RECONNECT_MAX_DELAY_MS = 15000L
  }

  private var player: ExoPlayer? = null
  private var textureView: TextureView? = null
  private var videoSurface: Surface? = null
  private var surfaceReady = false
  private var videoWidth = 0
  private var videoHeight = 0
  private var transformReady = false
  private var isSpeedAdjusted = false
  var url: String = ""
  var streamName: String = ""
  var resizeMode: String = "contain"
    set(value) {
      val normalized = if (value == "cover") "cover" else "contain"
      if (field != normalized) {
        field = normalized
        post { updateTextureViewTransform() }
      }
    }

  private fun onPlayerStateChanged(data: Map<String, Any?>) =
    emitViewEvent(this, "onPlayerStateChanged", data)
  private fun onPlayerError(data: Map<String, Any?>) =
    emitViewEvent(this, "onPlayerError", data)

  @Volatile private var isPlaying = false
  private var lastPlayRequestAt = 0L
  private var pendingPlay = false
  private var lastReportedState = ""

  private var reconnectAttempts = 0
  private val maxReconnectAttempts = 10
  private var reconnectHandler: Handler? = null
  private var reconnectRunnable: Runnable? = null
  private var bufferingHandler: Handler? = null
  private var bufferingRunnable: Runnable? = null

  @Volatile private var lastFrameTime = 0L
  private var stallCheckHandler: Handler? = null
  private var stallCheckRunnable: Runnable? = null

  init {
    liveInstances.add(this)
    setupView()
  }

  override fun onAttachedToWindow() {
    super.onAttachedToWindow()
    liveInstances.remove(this)
    liveInstances.add(this)
  }

  /**
   * A TextureView, not media3's own PlayerView: the latter renders into a
   * SurfaceView, which punches through the view hierarchy and misbehaves when
   * React Native reparents or animates the view.
   */
  private fun ensureVideoSurface(): Surface? {
    videoSurface?.let {
      if (it.isValid) return it
      try { it.release() } catch (_: Exception) {}
      videoSurface = null
    }
    val st = textureView?.surfaceTexture ?: return null
    return Surface(st).also { videoSurface = it }
  }

  private fun setupView() {
    textureView = TextureView(context).apply {
      // Until the stream's size is known a TextureView stretches the frame over
      // the whole view, so it stays hidden until the first correct transform.
      alpha = 0f
      layoutParams = LayoutParams(
        ViewGroup.LayoutParams.MATCH_PARENT,
        ViewGroup.LayoutParams.MATCH_PARENT
      )
      surfaceTextureListener = object : TextureView.SurfaceTextureListener {
        override fun onSurfaceTextureAvailable(st: SurfaceTexture, width: Int, height: Int) {
          surfaceReady = true
          ensureVideoSurface()?.let { player?.setVideoSurface(it) }
          if (pendingPlay) {
            pendingPlay = false
            doPlay()
          }
        }

        override fun onSurfaceTextureSizeChanged(st: SurfaceTexture, width: Int, height: Int) {
          updateTextureViewTransform()
        }

        override fun onSurfaceTextureDestroyed(st: SurfaceTexture): Boolean {
          surfaceReady = false
          player?.setVideoSurface(null)
          try { videoSurface?.release() } catch (_: Exception) {}
          videoSurface = null
          return true
        }

        // Fires once per rendered frame, which is what the stall watchdog needs:
        // the player can sit in STATE_READY while the server has gone quiet.
        override fun onSurfaceTextureUpdated(st: SurfaceTexture) {
          lastFrameTime = System.currentTimeMillis()
          // Reveal only on a frame drawn after the aspect transform is set.
          if (transformReady && textureView?.alpha != 1f) textureView?.alpha = 1f
        }
      }
    }
    addView(textureView)
  }

  override fun onLayout(changed: Boolean, l: Int, t: Int, r: Int, b: Int) {
    super.onLayout(changed, l, t, r, b)
    val w = r - l
    val h = b - t
    if (w > 0 && h > 0) {
      val tv = textureView
      if (tv != null && (tv.width != w || tv.height != h)) {
        // RN lays children out itself and skips measure, so the TextureView
        // is measured here too; otherwise its buffer keeps the old size.
        tv.measure(
          MeasureSpec.makeMeasureSpec(w, MeasureSpec.EXACTLY),
          MeasureSpec.makeMeasureSpec(h, MeasureSpec.EXACTLY)
        )
        tv.layout(0, 0, w, h)
      }
      updateTextureViewTransform()
    }
  }

  private fun updateTextureViewTransform() {
    val tv = textureView ?: return
    val viewWidth = tv.width.toFloat()
    val viewHeight = tv.height.toFloat()
    if (viewWidth <= 0f || viewHeight <= 0f || videoWidth <= 0 || videoHeight <= 0) return

    val viewRatio = viewWidth / viewHeight
    val videoRatio = videoWidth.toFloat() / videoHeight.toFloat()
    val scaleX: Float
    val scaleY: Float
    if (resizeMode == "cover") {
      if (videoRatio > viewRatio) {
        scaleX = videoRatio / viewRatio
        scaleY = 1f
      } else {
        scaleX = 1f
        scaleY = viewRatio / videoRatio
      }
    } else {
      if (videoRatio > viewRatio) {
        scaleX = 1f
        scaleY = viewRatio / videoRatio
      } else {
        scaleX = videoRatio / viewRatio
        scaleY = 1f
      }
    }
    val matrix = Matrix()
    matrix.setScale(scaleX, scaleY, viewWidth / 2f, viewHeight / 2f)
    tv.setTransform(matrix)
    transformReady = true
  }

  private fun buildConnectUrl(): String {
    var connectUrl = url.trim()
    val name = streamName.trim()
    if (name.isNotEmpty() && !connectUrl.endsWith("/$name")) {
      connectUrl = if (connectUrl.endsWith("/")) "$connectUrl$name" else "$connectUrl/$name"
    }
    return connectUrl
  }

  private fun createPlayer(): ExoPlayer {
    // The buffer has to be *large*, and the playhead kept at its edge. The
    // obvious setting - a 2 s cap, so the viewer stays close to live - is a
    // trap on RTMP: once the buffer is full ExoPlayer stops reading the
    // socket, the TCP window closes, and the server's per-subscriber send
    // queue overflows. nginx-rtmp answers that by dropping the subscriber
    // ("client too slow"), which the viewer sees as a frozen picture that
    // reconnects every few seconds. A publisher sending above the viewer's
    // drain rate hits it within seconds.
    //
    // So: read greedily, never stall the socket, and let [trimLiveDrift] pull
    // the playhead back to the live edge instead. Start playing from half a
    // second of data so joining stays fast, and let the time thresholds win
    // over the byte thresholds so a high-bitrate stream does not re-introduce
    // the same back-pressure through the size cap.
    val loadControl = DefaultLoadControl.Builder()
      .setBufferDurationsMs(4_000, 30_000, 1_200, 2_500)
      .setTargetBufferBytes(32 * 1024 * 1024)
      .setPrioritizeTimeOverSizeThresholds(true)
      .setBackBuffer(0, false)
      .build()

    // Media3 1.8+ surfaces AudioTrack PCM underruns immediately as STATE_BUFFERING.
    // A 2s target PCM buffer prevents micro-stutters and false rebuffer loops on live RTMP.
    val audioBufferSizeProvider = DefaultAudioTrackBufferSizeProvider.Builder()
      .setTargetPcmBufferDurationUs(2_000_000)
      .build()

    val renderersFactory = object : DefaultRenderersFactory(context) {
      override fun buildAudioSink(
        context: Context,
        enableFloatOutput: Boolean,
        enableAudioTrackPlaybackParams: Boolean
      ): AudioSink {
        return DefaultAudioSink.Builder(context)
          .setEnableFloatOutput(enableFloatOutput)
          .setEnableAudioTrackPlaybackParams(enableAudioTrackPlaybackParams)
          .setAudioTrackBufferSizeProvider(audioBufferSizeProvider)
          .build()
      }
    }.setEnableDecoderFallback(true)

    val audioAttributes = AudioAttributes.Builder()
      .setUsage(C.USAGE_MEDIA)
      .setContentType(C.AUDIO_CONTENT_TYPE_MOVIE)
      .build()

    val exo = ExoPlayer.Builder(context, renderersFactory)
      .setLoadControl(loadControl)
      .setAudioAttributes(audioAttributes, true)
      .build()
    exo.volume = 1.0f

    exo.addListener(object : Player.Listener {
      override fun onPlaybackStateChanged(playbackState: Int) {
        when (playbackState) {
          Player.STATE_BUFFERING -> post {
            scheduleBufferingReport()
          }
          Player.STATE_READY -> post {
            cancelBufferingReport()
            reportPlaying()
          }
          Player.STATE_ENDED -> post {
            if (isPlaying) startReconnectPoller()
          }
          Player.STATE_IDLE -> {}
        }
      }

      override fun onVideoSizeChanged(videoSize: VideoSize) {
        // ExoPlayer calls back on the main looper, so the transform is applied
        // synchronously, before the first frame of the new size is drawn.
        val width = (videoSize.width * videoSize.pixelWidthHeightRatio).toInt()
        if (width > 0 && videoSize.height > 0 &&
          (width != videoWidth || videoSize.height != videoHeight)
        ) {
          videoWidth = width
          videoHeight = videoSize.height
          updateTextureViewTransform()
        }
      }

      override fun onRenderedFirstFrame() {
        lastFrameTime = System.currentTimeMillis()
        updateTextureViewTransform()
        post { reportPlaying() }
      }

      override fun onPlayerError(error: PlaybackException) {
        Log.e(TAG, "player error: ${error.errorCodeName}", error)
        post {
          if (isPlaying && !isFatal(error)) {
            startReconnectPoller()
          } else {
            // A stream this device cannot parse or decode will not become
            // playable by reconnecting; retrying it on a timer only produces a
            // stutter loop, so these fail immediately instead.
            isPlaying = false
            keepScreenOn = false
            stopStallChecker()
            stopReconnectPoller()
            lastReportedState = "failed"
            this@PlayerView.onPlayerError(mapOf("msg" to (error.message ?: error.errorCodeName)))
            onPlayerStateChanged(mapOf("state" to "failed"))
          }
        }
      }
    })

    exo.setVideoFrameMetadataListener { _, _, _, _ ->
      lastFrameTime = System.currentTimeMillis()
    }
    if (surfaceReady) {
      ensureVideoSurface()?.let { exo.setVideoSurface(it) }
    }
    player = exo
    return exo
  }

  /**
   * Errors that mean "this stream cannot be played here" rather than "the
   * network hiccuped". Reconnecting fixes the latter and never the former.
   */
  private fun isFatal(error: PlaybackException): Boolean = when (error.errorCode) {
    PlaybackException.ERROR_CODE_PARSING_CONTAINER_UNSUPPORTED,
    PlaybackException.ERROR_CODE_PARSING_MANIFEST_UNSUPPORTED,
    PlaybackException.ERROR_CODE_DECODING_FORMAT_UNSUPPORTED,
    PlaybackException.ERROR_CODE_DECODER_INIT_FAILED -> true
    else -> false
  }

  private fun scheduleBufferingReport() {
    if (lastReportedState == "buffering" || lastReportedState == "connecting") return
    if (bufferingRunnable != null) return
    val handler = bufferingHandler ?: Handler(Looper.getMainLooper()).also { bufferingHandler = it }
    val runnable = Runnable {
      bufferingRunnable = null
      if (isPlaying && player?.playbackState == Player.STATE_BUFFERING &&
        lastReportedState != "buffering" && lastReportedState != "connecting"
      ) {
        lastReportedState = "buffering"
        onPlayerStateChanged(mapOf("state" to "buffering"))
      }
    }
    bufferingRunnable = runnable
    handler.postDelayed(runnable, BUFFERING_REPORT_DELAY_MS)
  }

  private fun cancelBufferingReport() {
    bufferingRunnable?.let { bufferingHandler?.removeCallbacks(it) }
    bufferingRunnable = null
  }

  private fun reportPlaying() {
    cancelBufferingReport()
    if (!isPlaying || lastReportedState == "playing") return
    lastReportedState = "playing"
    onPlayerStateChanged(mapOf("state" to "playing"))
    reconnectAttempts = 0
    stopReconnectPoller()
  }

  private fun ensurePlayer(): ExoPlayer = player ?: createPlayer()

  private fun prepareAndPlay(exo: ExoPlayer, connectUrl: String) {
    val source = ProgressiveMediaSource.Factory(RtmpDataSource.Factory())
      .createMediaSource(MediaItem.fromUri(connectUrl))
    exo.setMediaSource(source)
    exo.prepare()
    exo.playWhenReady = true
  }

  fun play() {
    post {
      val now = System.currentTimeMillis()
      if (now - lastPlayRequestAt < 800L) return@post
      lastPlayRequestAt = now

      if (isPlaying && player?.isPlaying == true) return@post

      if (!surfaceReady) {
        pendingPlay = true
        onPlayerStateChanged(mapOf("state" to "connecting"))
        return@post
      }

      doPlay()
    }
  }

  private fun doPlay() {
    val connectUrl = buildConnectUrl()
    if (connectUrl.isEmpty()) {
      isPlaying = false
      lastReportedState = "failed"
      onPlayerError(mapOf("msg" to "URL is empty"))
      onPlayerStateChanged(mapOf("state" to "failed"))
      return
    }

    lastReportedState = "connecting"
    onPlayerStateChanged(mapOf("state" to "connecting"))

    try {
      prepareAndPlay(ensurePlayer(), connectUrl)
      isPlaying = true
      keepScreenOn = true
      startStallChecker()
      lastFrameTime = System.currentTimeMillis()
    } catch (e: Exception) {
      Log.e(TAG, "play failed", e)
      onPlayerError(mapOf("msg" to (e.message ?: "Unknown error")))
      onPlayerStateChanged(mapOf("state" to "failed"))
    }
  }

  fun stop() {
    post {
      if (!isPlaying && player == null && !pendingPlay) return@post
      pendingPlay = false
      isPlaying = false
      keepScreenOn = false
      lastPlayRequestAt = 0L
      stopStallChecker()
      stopReconnectPoller()
      lastReportedState = "stopped"
      try {
        player?.stop()
        onPlayerStateChanged(mapOf("state" to "stopped"))
      } catch (e: Exception) {
        Log.e(TAG, "stop failed", e)
      }
    }
  }

  fun pause() {
    post {
      val exo = player ?: return@post
      if (!isPlaying) return@post
      exo.playWhenReady = false
      // Stop the watchdogs: they look at isPlaying/lastReportedState and would
      // treat the absence of frames as a stall and silently restart playback.
      isPlaying = false
      keepScreenOn = false
      stopStallChecker()
      stopReconnectPoller()
      lastReportedState = "paused"
      onPlayerStateChanged(mapOf("state" to "paused"))
    }
  }

  fun resume() {
    post {
      // Resuming a live stream from where it was paused would replay stale
      // frames, so the stream is re-prepared at the live edge instead.
      val connectUrl = buildConnectUrl()
      if (connectUrl.isEmpty()) return@post
      try {
        val exo = ensurePlayer()
        exo.stop()
        prepareAndPlay(exo, connectUrl)
        isPlaying = true
        keepScreenOn = true
        lastReportedState = "connecting"
        onPlayerStateChanged(mapOf("state" to "connecting"))
        startStallChecker()
        lastFrameTime = System.currentTimeMillis()
      } catch (e: Exception) {
        Log.e(TAG, "resume failed", e)
      }
    }
  }

  private fun startStallChecker() {
    if (stallCheckHandler != null) return
    lastFrameTime = System.currentTimeMillis()
    stallCheckHandler = Handler(Looper.getMainLooper())
    stallCheckRunnable = object : Runnable {
      override fun run() {
        if (isPlaying && lastReportedState == "playing" && lastFrameTime > 0L) {
          val elapsed = System.currentTimeMillis() - lastFrameTime
          if (elapsed > STALL_TIMEOUT_MS) {
            lastFrameTime = 0L
            startReconnectPoller()
          } else {
            trimLiveDrift()
          }
        } else if (isPlaying && reconnectHandler == null && lastFrameTime > 0L &&
          (lastReportedState == "connecting" || lastReportedState == "buffering") &&
          System.currentTimeMillis() - lastFrameTime > NO_FRAME_TIMEOUT_MS
        ) {
          lastFrameTime = 0L
          startReconnectPoller()
        }
        stallCheckHandler?.postDelayed(this, TICK_MS)
      }
    }
    stallCheckHandler?.postDelayed(stallCheckRunnable!!, TICK_MS)
  }

  private fun trimLiveDrift() {
    val exo = player ?: return
    if (exo.playbackState != Player.STATE_READY) return
    val buffered = exo.bufferedPosition
    val current = exo.currentPosition
    if (buffered <= 0L || current < 0L) return
    val drift = buffered - current
    // FlvExtractor reports SeekMap.Unseekable, so ProgressiveMediaPeriod clamps
    // any exo.seekTo(...) target to 0 (seeking backward to the start or
    // cancelling the RtmpDataSource loader). Catch up with a gentle playback
    // rate nudge instead, and only re-prepare if lag has grown extreme.
    if (drift > EXTREME_LIVE_DRIFT_MS) {
      Log.d(TAG, "extreme live drift ${drift}ms, re-preparing at live edge")
      isSpeedAdjusted = false
      // Restart the frame clock so the stall watchdog does not read the
      // re-prepare gap as a second, independent stall.
      lastFrameTime = System.currentTimeMillis()
      try {
        exo.setPlaybackSpeed(1.0f)
        exo.stop()
        prepareAndPlay(exo, buildConnectUrl())
      } catch (e: Exception) {
        Log.e(TAG, "live edge re-prepare failed", e)
      }
    } else if (drift > MAX_LIVE_DRIFT_MS && !isSpeedAdjusted) {
      Log.d(TAG, "live drift ${drift}ms, nudging playback speed to 1.03x")
      isSpeedAdjusted = true
      exo.setPlaybackSpeed(1.03f)
    } else if (drift <= TARGET_LIVE_DRIFT_MS && isSpeedAdjusted) {
      isSpeedAdjusted = false
      exo.setPlaybackSpeed(1.0f)
    }
  }

  private fun stopStallChecker() {
    cancelBufferingReport()
    stallCheckRunnable?.let { stallCheckHandler?.removeCallbacks(it) }
    stallCheckHandler = null
    stallCheckRunnable = null
    lastFrameTime = 0L
    if (isSpeedAdjusted) {
      isSpeedAdjusted = false
      try { player?.setPlaybackSpeed(1.0f) } catch (_: Exception) {}
    }
  }

  private fun startReconnectPoller() {
    if (reconnectHandler != null) return
    reconnectAttempts = 0
    reconnectHandler = Handler(Looper.getMainLooper())
    lastReportedState = "buffering"
    onPlayerStateChanged(mapOf("state" to "buffering"))
    reconnectRunnable = object : Runnable {
      override fun run() {
        reconnectAttempts++
        if (reconnectAttempts >= maxReconnectAttempts) {
          stopReconnectPoller()
          stopStallChecker()
          isPlaying = false
          keepScreenOn = false
          lastReportedState = "failed"
          onPlayerError(mapOf("msg" to "Stream lost — reconnect failed"))
          onPlayerStateChanged(mapOf("state" to "failed"))
          return
        }
        try {
          val exo = ensurePlayer()
          if (isSpeedAdjusted) {
            isSpeedAdjusted = false
            exo.setPlaybackSpeed(1.0f)
          }
          exo.stop()
          prepareAndPlay(exo, buildConnectUrl())
        } catch (e: Exception) {
          Log.e(TAG, "reconnect failed", e)
        }
        reconnectHandler?.postDelayed(this, reconnectDelayMs(reconnectAttempts))
      }
    }
    reconnectHandler?.postDelayed(reconnectRunnable!!, reconnectDelayMs(0))
  }

  private fun reconnectDelayMs(attempt: Int): Long {
    var delay = RECONNECT_BASE_DELAY_MS.toDouble()
    repeat(attempt) { delay *= 1.5 }
    return delay.toLong().coerceAtMost(RECONNECT_MAX_DELAY_MS)
  }

  private fun stopReconnectPoller() {
    reconnectRunnable?.let { reconnectHandler?.removeCallbacks(it) }
    reconnectHandler = null
    reconnectRunnable = null
    reconnectAttempts = 0
  }

  private fun cleanup() {
    stopStallChecker()
    stopReconnectPoller()
    pendingPlay = false
    isPlaying = false
    keepScreenOn = false
    // Each step is guarded on its own: one throwing call must not leave the
    // player or its surface behind.
    val exo = player
    player = null
    try { exo?.setVideoSurface(null) } catch (e: Exception) { Log.w(TAG, "detach surface failed", e) }
    try { videoSurface?.release() } catch (_: Exception) {}
    videoSurface = null
    try { exo?.stop() } catch (e: Exception) { Log.w(TAG, "player stop failed", e) }
    try { exo?.release() } catch (e: Exception) { Log.w(TAG, "player release failed", e) }
    surfaceReady = textureView?.isAvailable == true
    liveInstances.remove(this)
  }

  override fun onDetachedFromWindow() {
    super.onDetachedFromWindow()
    cleanup()
  }
}
