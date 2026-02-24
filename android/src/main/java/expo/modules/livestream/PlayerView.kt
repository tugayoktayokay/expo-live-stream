package expo.modules.livestream

import android.content.Context
import android.util.Log
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.datasource.rtmp.RtmpDataSource
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.MediaSource
import androidx.media3.exoplayer.source.ProgressiveMediaSource
import androidx.media3.ui.PlayerView as ExoPlayerView
import expo.modules.kotlin.AppContext
import expo.modules.kotlin.views.ExpoView
import expo.modules.kotlin.viewevent.EventDispatcher

@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
class PlayerView(context: Context, appContext: AppContext) : ExpoView(context, appContext) {

  companion object {
    private const val TAG = "ExpoLiveStreamPlayer"
    var activeInstance: PlayerView? = null
      private set
  }

  // UI
  private var playerView: ExoPlayerView? = null
  private var exoPlayer: ExoPlayer? = null

  // Props
  var url: String = ""
  var streamName: String = ""

  // Events
  val onPlayerStateChanged by EventDispatcher()
  val onPlayerError by EventDispatcher()

  // State
  private var isPlaying = false

  init {
    activeInstance = this
    Log.d(TAG, "View created, activeInstance set")
    setupView()
  }

  private fun setupView() {
    val pv = ExoPlayerView(context).apply {
      layoutParams = LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT)
      useController = false
      resizeMode = androidx.media3.ui.AspectRatioFrameLayout.RESIZE_MODE_FIT
    }
    addView(pv)
    playerView = pv
  }

  fun play() {
    post {
      var connectUrl = url
      var playStreamName = streamName

      if (playStreamName.isNotEmpty() && !connectUrl.endsWith("/$playStreamName")) {
        connectUrl = "$connectUrl/$playStreamName"
      }

      if (connectUrl.isEmpty()) {
        onPlayerError(mapOf("msg" to "URL is empty"))
        return@post
      }

      // Release previous player if exists
      try {
        exoPlayer?.stop()
        exoPlayer?.release()
        exoPlayer = null
      } catch (e: Exception) {
        Log.w(TAG, "Failed to release previous player", e)
      }

      // Recreate PlayerView to fully reset aspect ratio
      playerView?.let { removeView(it) }
      val freshPv = ExoPlayerView(context).apply {
        layoutParams = LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT)
        useController = false
        resizeMode = androidx.media3.ui.AspectRatioFrameLayout.RESIZE_MODE_FIT
      }
      addView(freshPv)
      playerView = freshPv

      Log.d(TAG, "play: url=$connectUrl")
      onPlayerStateChanged(mapOf("state" to "connecting"))

      try {
        // Low-latency buffer for live RTMP streaming
        val loadControl = androidx.media3.exoplayer.DefaultLoadControl.Builder()
          .setBufferDurationsMs(
            500,   // minBufferMs (default 50000)
            2000,  // maxBufferMs (default 50000) 
            500,   // bufferForPlaybackMs (default 2500)
            500    // bufferForPlaybackAfterRebufferMs (default 5000)
          )
          .build()

        val player = ExoPlayer.Builder(context)
          .setLoadControl(loadControl)
          .build()
        exoPlayer = player
        freshPv.player = player

        val rtmpDataSourceFactory = RtmpDataSource.Factory()
        val mediaSource: MediaSource = ProgressiveMediaSource.Factory(rtmpDataSourceFactory)
          .createMediaSource(MediaItem.fromUri(connectUrl))

        player.setMediaSource(mediaSource)

        player.addListener(object : Player.Listener {
          override fun onPlaybackStateChanged(playbackState: Int) {
            when (playbackState) {
              Player.STATE_BUFFERING -> {
                post { onPlayerStateChanged(mapOf("state" to "buffering")) }
              }
              Player.STATE_READY -> {
                post { onPlayerStateChanged(mapOf("state" to "playing")) }
              }
              Player.STATE_ENDED -> {
                post {
                  isPlaying = false
                  onPlayerStateChanged(mapOf("state" to "stopped"))
                }
              }
              Player.STATE_IDLE -> {}
            }
          }

          override fun onPlayerError(error: PlaybackException) {
            Log.e(TAG, "Player error: ${error.message}")
            post {
              isPlaying = false
              this@PlayerView.onPlayerError(mapOf("msg" to (error.message ?: "Unknown error")))
              onPlayerStateChanged(mapOf("state" to "failed"))
            }
          }
        })

        player.prepare()
        player.playWhenReady = true
        isPlaying = true
      } catch (e: Exception) {
        Log.e(TAG, "play failed", e)
        onPlayerError(mapOf("msg" to (e.message ?: "Unknown error")))
        onPlayerStateChanged(mapOf("state" to "failed"))
      }
    }
  }

  fun stop() {
    post {
      if (!isPlaying && exoPlayer == null) return@post
      isPlaying = false

      try {
        exoPlayer?.stop()
        exoPlayer?.release()
        exoPlayer = null
        playerView?.player = null
        Log.d(TAG, "stop: success")
        onPlayerStateChanged(mapOf("state" to "stopped"))
      } catch (e: Exception) {
        Log.e(TAG, "stop failed", e)
      }
    }
  }

  fun pause() {
    post {
      exoPlayer?.playWhenReady = false
      onPlayerStateChanged(mapOf("state" to "paused"))
    }
  }

  fun resume() {
    post {
      exoPlayer?.playWhenReady = true
      onPlayerStateChanged(mapOf("state" to "playing"))
    }
  }

  fun cleanup() {
    stop()
    if (activeInstance === this) {
      activeInstance = null
    }
  }

  override fun onDetachedFromWindow() {
    super.onDetachedFromWindow()
    cleanup()
  }
}
