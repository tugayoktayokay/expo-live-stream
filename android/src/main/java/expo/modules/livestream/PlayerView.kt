package expo.modules.livestream

import android.content.Context
import android.graphics.SurfaceTexture
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.Surface
import android.view.TextureView
import android.view.ViewGroup
import android.widget.LinearLayout
import expo.modules.kotlin.AppContext
import expo.modules.kotlin.views.ExpoView
import expo.modules.kotlin.viewevent.EventDispatcher
import org.videolan.libvlc.LibVLC
import org.videolan.libvlc.Media
import org.videolan.libvlc.MediaPlayer

class PlayerView(context: Context, appContext: AppContext) : ExpoView(context, appContext) {

  companion object {
    private const val TAG = "ExpoLiveStreamPlayer"
    var activeInstance: PlayerView? = null
      private set
  }

  // VLC
  private var libVLC: LibVLC? = null
  private var mediaPlayer: MediaPlayer? = null
  private var textureView: TextureView? = null
  private var surface: Surface? = null
  private var surfaceReady = false

  // Props
  var url: String = ""
  var streamName: String = ""

  // Events
  val onPlayerStateChanged by EventDispatcher()
  val onPlayerError by EventDispatcher()

  // State (matches iOS)
  private var isPlaying = false
  private var lastPlayRequestAt = 0L
  private var pendingPlay = false
  private var lastReportedState = ""

  // Auto-reconnect (matches iOS — 3 attempts)
  private var reconnectAttempts = 0
  private val maxReconnectAttempts = 3
  private var reconnectHandler: Handler? = null
  private var reconnectRunnable: Runnable? = null

  init {
    activeInstance = this
    Log.d(TAG, "View created, activeInstance set")
    setupView()
  }

  private fun setupView() {
    textureView = TextureView(context).apply {
      layoutParams = LinearLayout.LayoutParams(
        ViewGroup.LayoutParams.MATCH_PARENT,
        ViewGroup.LayoutParams.MATCH_PARENT
      )
      surfaceTextureListener = object : TextureView.SurfaceTextureListener {
        override fun onSurfaceTextureAvailable(st: SurfaceTexture, width: Int, height: Int) {
          Log.d(TAG, "TextureView surface available: ${width}x${height}")
          surface = Surface(st)
          surfaceReady = true
          if (pendingPlay) {
            pendingPlay = false
            doPlay()
          }
        }
        override fun onSurfaceTextureSizeChanged(st: SurfaceTexture, width: Int, height: Int) {
          Log.d(TAG, "TextureView size changed: ${width}x${height}")
          // Update VLC with actual surface dimensions (more precise than onLayout)
          mediaPlayer?.let { player ->
            player.vlcVout.setWindowSize(width, height)
            player.videoScale = MediaPlayer.ScaleType.SURFACE_FILL
          }
        }
        override fun onSurfaceTextureDestroyed(st: SurfaceTexture): Boolean {
          // Keep surface alive across rotation
          return false
        }
        override fun onSurfaceTextureUpdated(st: SurfaceTexture) {}
      }
    }
    addView(textureView)
  }

  // Layout change (rotation) — just update VLC window size, surface stays alive
  // (configChanges in AndroidManifest prevents Activity recreation)
  override fun onLayout(changed: Boolean, l: Int, t: Int, r: Int, b: Int) {
    super.onLayout(changed, l, t, r, b)
    if (changed) {
      val w = r - l
      val h = b - t
      if (w > 0 && h > 0) {
        Log.d(TAG, "onLayout: ${w}x${h}")
        mediaPlayer?.let { player ->
          player.vlcVout.setWindowSize(w, h)
          player.videoScale = MediaPlayer.ScaleType.SURFACE_FILL
        }
      }
    }
  }

  private fun buildConnectUrl(): String {
    var connectUrl = url
    if (streamName.isNotEmpty() && !connectUrl.endsWith("/$streamName")) {
      connectUrl = "$connectUrl/$streamName"
    }
    return connectUrl
  }

  private fun ensureVLC(): LibVLC {
    libVLC?.let { return it }
    val options = arrayListOf(
      "--network-caching=100",
      "--live-caching=100",
      "--clock-jitter=0",
      "--clock-synchro=0",
      "--file-caching=0",
      "--drop-late-frames",
      "--skip-frames"
    )
    val vlc = LibVLC(context, options)
    libVLC = vlc
    return vlc
  }

  // Creates a new MediaPlayer, attaches the TextureView surface, sets FILL scale
  private fun createAndAttachPlayer(): MediaPlayer {
    val vlc = ensureVLC()
    val player = MediaPlayer(vlc)

    player.setEventListener { event ->
      when (event.type) {
        MediaPlayer.Event.Playing -> {
          post {
            if (lastReportedState != "playing") {
              Log.d(TAG, "VLC: Playing")
              lastReportedState = "playing"
              onPlayerStateChanged(mapOf("state" to "playing"))
            }
            reconnectAttempts = 0
            stopReconnectPoller()
          }
        }
        MediaPlayer.Event.Buffering -> {
          post {
            if (lastReportedState != "buffering") {
              lastReportedState = "buffering"
              onPlayerStateChanged(mapOf("state" to "buffering"))
            }
          }
        }
        MediaPlayer.Event.EncounteredError -> {
          post {
            Log.e(TAG, "VLC: Error encountered")
            if (isPlaying) startReconnectPoller()
            else {
              onPlayerError(mapOf("msg" to "VLC playback error"))
              onPlayerStateChanged(mapOf("state" to "failed"))
            }
          }
        }
        MediaPlayer.Event.EndReached, MediaPlayer.Event.Stopped -> {
          post {
            Log.d(TAG, "VLC: EndReached/Stopped")
            if (isPlaying) startReconnectPoller()
          }
        }
        // TimeChanged fires every frame — only emit if we haven't reported "playing" yet
        MediaPlayer.Event.TimeChanged -> {
          if (player.isPlaying && lastReportedState != "playing") {
            post {
              lastReportedState = "playing"
              onPlayerStateChanged(mapOf("state" to "playing"))
            }
          }
        }
      }
    }

    // Attach surface BEFORE play — set window size first for correct initial render
    if (surfaceReady && surface != null) {
      val vout = player.vlcVout
      if (!vout.areViewsAttached()) {
        vout.setVideoSurface(surface, null)
        val w = this.width
        val h = this.height
        if (w > 0 && h > 0) vout.setWindowSize(w, h)
        vout.attachViews()
        Log.d(TAG, "VLC surface attached: ${w}x${h}")
      }
    }

    // Set FILL immediately — no delay
    player.videoScale = MediaPlayer.ScaleType.SURFACE_FILL

    mediaPlayer = player
    return player
  }

  private fun ensureMediaPlayer(): MediaPlayer {
    mediaPlayer?.let { return it }
    return createAndAttachPlayer()
  }

  // Matches iOS play()
  fun play() {
    post {
      val now = System.currentTimeMillis()
      if (now - lastPlayRequestAt < 800L) return@post
      lastPlayRequestAt = now

      if (isPlaying && mediaPlayer?.isPlaying == true) return@post

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
      onPlayerError(mapOf("msg" to "URL is empty"))
      return
    }

    Log.d(TAG, "play: url=$connectUrl")
    lastReportedState = "connecting"
    onPlayerStateChanged(mapOf("state" to "connecting"))

    try {
      val player = ensureMediaPlayer()
      val vlc = ensureVLC()
      val media = Media(vlc, Uri.parse(connectUrl))
      media.setHWDecoderEnabled(true, false)
      player.media = media
      media.release()
      player.play()
      isPlaying = true
    } catch (e: Exception) {
      Log.e(TAG, "play failed", e)
      onPlayerError(mapOf("msg" to (e.message ?: "Unknown error")))
      onPlayerStateChanged(mapOf("state" to "failed"))
    }
  }

  fun stop() {
    post {
      if (!isPlaying && mediaPlayer == null) return@post
      isPlaying = false
      stopReconnectPoller()
      try {
        mediaPlayer?.stop()
        onPlayerStateChanged(mapOf("state" to "stopped"))
      } catch (e: Exception) {
        Log.e(TAG, "stop failed", e)
      }
    }
  }

  fun pause() {
    post {
      val player = mediaPlayer ?: return@post
      if (!player.isPlaying) return@post
      player.pause()
      onPlayerStateChanged(mapOf("state" to "paused"))
    }
  }

  // Matches iOS resume() — stop + re-play to jump to live edge
  fun resume() {
    post {
      mediaPlayer?.stop()
      val connectUrl = buildConnectUrl()
      try {
        val player = ensureMediaPlayer()
        val vlc = ensureVLC()
        val media = Media(vlc, Uri.parse(connectUrl))
        media.setHWDecoderEnabled(true, false)
        player.media = media
        media.release()
        player.play()
        isPlaying = true
        onPlayerStateChanged(mapOf("state" to "playing"))
      } catch (e: Exception) {
        Log.e(TAG, "resume failed", e)
      }
    }
  }

  // Volume & Seek

  fun setVolume(volume: Double) {
    val vlcVolume = (volume.coerceIn(0.0, 1.0) * 100).toInt()
    mediaPlayer?.volume = vlcVolume
  }

  fun setMuted(muted: Boolean) {
    mediaPlayer?.volume = if (muted) 0 else 100
  }

  fun seekTo(positionMs: Long) {
    mediaPlayer?.time = positionMs
  }

  fun getPosition(): Long {
    return mediaPlayer?.time ?: 0L
  }

  fun getDuration(): Long {
    return mediaPlayer?.length ?: 0L
  }

  fun setRate(rate: Float) {
    mediaPlayer?.rate = rate
  }

  // Smart Reconnect (matches iOS — 5s interval, 3 max)
  private fun startReconnectPoller() {
    if (reconnectHandler != null) return
    reconnectAttempts = 0
    reconnectHandler = Handler(Looper.getMainLooper())
    onPlayerStateChanged(mapOf("state" to "buffering"))
    reconnectRunnable = object : Runnable {
      override fun run() {
        reconnectAttempts++
        if (reconnectAttempts >= maxReconnectAttempts) {
          stopReconnectPoller()
          isPlaying = false
          onPlayerError(mapOf("msg" to "Stream lost — reconnect failed"))
          onPlayerStateChanged(mapOf("state" to "failed"))
          return
        }
        try {
          mediaPlayer?.stop()
          val vlc = ensureVLC()
          val media = Media(vlc, Uri.parse(buildConnectUrl()))
          media.setHWDecoderEnabled(true, false)
          mediaPlayer?.media = media
          media.release()
          mediaPlayer?.play()
        } catch (e: Exception) {
          Log.e(TAG, "reconnect failed", e)
        }
        reconnectHandler?.postDelayed(this, 5000)
      }
    }
    reconnectHandler?.postDelayed(reconnectRunnable!!, 5000)
  }

  private fun stopReconnectPoller() {
    reconnectRunnable?.let { reconnectHandler?.removeCallbacks(it) }
    reconnectHandler = null
    reconnectRunnable = null
    reconnectAttempts = 0
  }

  fun cleanup() {
    stopReconnectPoller()
    try {
      mediaPlayer?.stop()
      mediaPlayer?.vlcVout?.detachViews()
      mediaPlayer?.release()
      mediaPlayer = null
      surface?.release()
      surface = null
      libVLC?.release()
      libVLC = null
    } catch (e: Exception) {
      Log.e(TAG, "cleanup failed", e)
    }
    if (activeInstance == this) activeInstance = null
  }

  override fun onDetachedFromWindow() {
    super.onDetachedFromWindow()
    cleanup()
  }
}
