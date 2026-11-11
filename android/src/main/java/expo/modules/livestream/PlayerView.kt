package expo.modules.livestream

import android.content.Context
import android.graphics.Matrix
import android.graphics.SurfaceTexture
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.TextureView
import android.view.ViewGroup
import android.widget.LinearLayout
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.VideoSize
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.rtmp.RtmpDataSource
import androidx.media3.exoplayer.DefaultLoadControl
import androidx.media3.exoplayer.ExoPlayer
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
    private const val MAX_LIVE_DRIFT_MS = 2500L
    private const val TARGET_LIVE_DRIFT_MS = 600L
    private const val EXTREME_LIVE_DRIFT_MS = 15000L
    /** How often the watchdog looks at drift and at the frame clock. */
    private const val TICK_MS = 1000L

    /** No rendered frame for this long while playing counts as a stall. */
    private const val STALL_TIMEOUT_MS = 8000L
  }

  private var player: ExoPlayer? = null
  private var textureView: TextureView? = null
  private var surfaceReady = false
  private var videoWidth = 0
  private var videoHeight = 0
  private var isSpeedAdjusted = false
  var url: String = ""
  var streamName: String = ""

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
  private fun setupView() {
    textureView = TextureView(context).apply {
      layoutParams = LayoutParams(
        ViewGroup.LayoutParams.MATCH_PARENT,
        ViewGroup.LayoutParams.MATCH_PARENT
      )
      surfaceTextureListener = object : TextureView.SurfaceTextureListener {
        override fun onSurfaceTextureAvailable(st: SurfaceTexture, width: Int, height: Int) {
          surfaceReady = true
          player?.setVideoTextureView(this@apply)
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
          player?.setVideoTextureView(null)
          return true
        }

        // Fires once per rendered frame, which is what the stall watchdog needs:
        // the player can sit in STATE_READY while the server has gone quiet.
        override fun onSurfaceTextureUpdated(st: SurfaceTexture) {
          lastFrameTime = System.currentTimeMillis()
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
      textureView?.layout(0, 0, w, h)
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
    if (videoRatio > viewRatio) {
      scaleX = videoRatio / viewRatio
      scaleY = 1f
    } else {
      scaleX = 1f
      scaleY = viewRatio / videoRatio
    }
    val matrix = Matrix()
    matrix.setScale(scaleX, scaleY, viewWidth / 2f, viewHeight / 2f)
    tv.setTransform(matrix)
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
      .setBufferDurationsMs(1_000, 60_000, 500, 1_000)
      .setPrioritizeTimeOverSizeThresholds(true)
      .setBackBuffer(0, false)
      .build()

    val exo = ExoPlayer.Builder(context)
      .setLoadControl(loadControl)
      .build()

    exo.addListener(object : Player.Listener {
      override fun onPlaybackStateChanged(playbackState: Int) {
        when (playbackState) {
          Player.STATE_BUFFERING -> post {
            if (lastReportedState != "buffering" && lastReportedState != "connecting") {
              lastReportedState = "buffering"
              onPlayerStateChanged(mapOf("state" to "buffering"))
            }
          }
          Player.STATE_READY -> post { reportPlaying() }
          Player.STATE_ENDED -> post {
            if (isPlaying) startReconnectPoller()
          }
          Player.STATE_IDLE -> {}
        }
      }

      override fun onVideoSizeChanged(videoSize: VideoSize) {
        if (videoSize.width > 0 && videoSize.height > 0) {
          videoWidth = videoSize.width
          videoHeight = videoSize.height
          post { updateTextureViewTransform() }
        }
      }

      override fun onRenderedFirstFrame() {
        lastFrameTime = System.currentTimeMillis()
        post {
          updateTextureViewTransform()
          reportPlaying()
        }
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
            stopStallChecker()
            stopReconnectPoller()
            lastReportedState = "failed"
            this@PlayerView.onPlayerError(mapOf("msg" to (error.message ?: error.errorCodeName)))
            onPlayerStateChanged(mapOf("state" to "failed"))
          }
        }
      }
    })

    textureView?.let { if (surfaceReady) exo.setVideoTextureView(it) }
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

  private fun reportPlaying() {
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
      startStallChecker()
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
        lastReportedState = "connecting"
        onPlayerStateChanged(mapOf("state" to "connecting"))
        startStallChecker()
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
        }
        stallCheckHandler?.postDelayed(this, TICK_MS)
      }
    }
    stallCheckHandler?.postDelayed(stallCheckRunnable!!, TICK_MS)
  }

  private fun trimLiveDrift() {
    val exo = player ?: return
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
      Log.d(TAG, "live drift ${drift}ms, nudging playback speed to 1.06x")
      isSpeedAdjusted = true
      exo.setPlaybackSpeed(1.06f)
    } else if (drift <= TARGET_LIVE_DRIFT_MS && isSpeedAdjusted) {
      isSpeedAdjusted = false
      exo.setPlaybackSpeed(1.0f)
    }
  }

  private fun stopStallChecker() {
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
          lastReportedState = "failed"
          onPlayerError(mapOf("msg" to "Stream lost — reconnect failed"))
          onPlayerStateChanged(mapOf("state" to "failed"))
          return
        }
        try {
          val exo = ensurePlayer()
          exo.stop()
          prepareAndPlay(exo, buildConnectUrl())
        } catch (e: Exception) {
          Log.e(TAG, "reconnect failed", e)
        }
        reconnectHandler?.postDelayed(this, 3500L)
      }
    }
    reconnectHandler?.postDelayed(reconnectRunnable!!, 3500L)
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
    // Each step is guarded on its own: one throwing call must not leave the
    // player or its surface behind.
    val exo = player
    player = null
    try { exo?.setVideoTextureView(null) } catch (e: Exception) { Log.w(TAG, "detach surface failed", e) }
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
