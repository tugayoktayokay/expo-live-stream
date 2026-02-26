package expo.modules.livestream

import expo.modules.kotlin.modules.Module
import expo.modules.kotlin.modules.ModuleDefinition

class ExpoLiveStreamModule : Module() {
  override fun definition() = ModuleDefinition {
    Name("ExpoLiveStream")

    // ======== Publisher Functions ========
    AsyncFunction("start") { url: String? ->
      PublisherView.activeInstance?.start(url)
    }

    AsyncFunction("stop") {
      PublisherView.activeInstance?.stop()
    }

    AsyncFunction("switchCamera") {
      PublisherView.activeInstance?.switchCamera()
    }

    AsyncFunction("toggleFlash") {
      PublisherView.activeInstance?.toggleFlash()
    }

    AsyncFunction("toggleMute") {
      PublisherView.activeInstance?.toggleMute()
    }

    // ======== Player Functions ========
    AsyncFunction("playerPlay") {
      PlayerView.activeInstance?.play()
    }

    AsyncFunction("playerStop") {
      PlayerView.activeInstance?.stop()
    }

    AsyncFunction("playerPause") {
      PlayerView.activeInstance?.pause()
    }

    AsyncFunction("playerResume") {
      PlayerView.activeInstance?.resume()
    }

    AsyncFunction("playerSetVolume") { volume: Double ->
      PlayerView.activeInstance?.setVolume(volume)
    }

    AsyncFunction("playerSetMuted") { muted: Boolean ->
      PlayerView.activeInstance?.setMuted(muted)
    }

    AsyncFunction("playerSeekTo") { positionMs: Long ->
      PlayerView.activeInstance?.seekTo(positionMs)
    }

    AsyncFunction("playerGetPosition") {
      PlayerView.activeInstance?.getPosition() ?: 0L
    }

    AsyncFunction("playerGetDuration") {
      PlayerView.activeInstance?.getDuration() ?: 0L
    }

    AsyncFunction("playerSetRate") { rate: Float ->
      PlayerView.activeInstance?.setRate(rate)
    }

    // ── Recording ──
    AsyncFunction("publisherStartRecording") {
      PublisherView.activeInstance?.startRecording() ?: ""
    }

    AsyncFunction("publisherStopRecording") {
      PublisherView.activeInstance?.stopRecording()
    }

    AsyncFunction("publisherIsRecording") {
      PublisherView.activeInstance?.isRecording() ?: false
    }

    // ── Camera Controls ──
    AsyncFunction("publisherSetZoom") { level: Float ->
      PublisherView.activeInstance?.setZoom(level)
    }

    AsyncFunction("publisherGetZoom") {
      PublisherView.activeInstance?.getZoom() ?: 0f
    }

    AsyncFunction("publisherGetMaxZoom") {
      PublisherView.activeInstance?.getMaxZoom() ?: 1f
    }

    AsyncFunction("publisherSetExposure") { value: Float ->
      PublisherView.activeInstance?.setExposureCompensation(value)
    }

    AsyncFunction("publisherGetExposure") {
      PublisherView.activeInstance?.getExposureCompensation() ?: 0f
    }

    // ── Filters ──
    AsyncFunction("publisherSetFilter") { name: String ->
      PublisherView.activeInstance?.setFilter(name)
    }

    AsyncFunction("publisherGetFilter") {
      PublisherView.activeInstance?.getFilter() ?: "none"
    }

    AsyncFunction("publisherGetAvailableFilters") {
      PublisherView.activeInstance?.getAvailableFilters() ?: emptyList<String>()
    }

    // ── Phase 7: Multi-Destination ──
    AsyncFunction("publisherStartMulti") { urls: List<String> ->
      PublisherView.activeInstance?.startMulti(urls)
    }

    AsyncFunction("publisherStopMulti") {
      PublisherView.activeInstance?.stopMulti()
    }

    AsyncFunction("publisherGetMultiDestinations") {
      PublisherView.activeInstance?.getMultiDestinations() ?: emptyList<String>()
    }

    // ── Phase 8: Overlay ──
    AsyncFunction("publisherSetTextOverlay") { text: String, x: Float, y: Float, size: Float ->
      PublisherView.activeInstance?.setTextOverlay(text, x, y, size)
    }

    AsyncFunction("publisherClearOverlay") {
      PublisherView.activeInstance?.clearOverlay()
    }

    // ── Phase 9: Audio ──
    AsyncFunction("publisherSetBackgroundMusic") { path: String, volume: Float ->
      PublisherView.activeInstance?.setBackgroundMusic(path, volume)
    }

    AsyncFunction("publisherStopBackgroundMusic") {
      PublisherView.activeInstance?.stopBackgroundMusic()
    }

    // ── Phase 10: Advanced ──
    AsyncFunction("publisherSetAdaptiveBitrate") { enabled: Boolean ->
      PublisherView.activeInstance?.setAdaptiveBitrate(enabled)
    }

    AsyncFunction("publisherGetStreamStats") {
      PublisherView.activeInstance?.getStreamStats() ?: emptyMap<String, Any>()
    }

    // ======== Publisher View ========
    View(PublisherView::class) {
      Events(
        "onConnectionSuccess",
        "onConnectionFailed",
        "onDisconnect",
        "onStreamStateChanged",
        "onBitrateUpdate"
      )

      Prop("url") { view: PublisherView, url: String ->
        view.url = url
      }
      Prop("streamKey") { view: PublisherView, key: String ->
        view.streamKey = key
      }
      Prop("videoWidth") { view: PublisherView, width: Int ->
        view.videoWidth = width
      }
      Prop("videoHeight") { view: PublisherView, height: Int ->
        view.videoHeight = height
      }
      Prop("videoBitrate") { view: PublisherView, bitrate: Int ->
        view.videoBitrate = bitrate
      }
      Prop("videoFps") { view: PublisherView, fps: Int ->
        view.videoFps = fps
      }
      Prop("audioBitrate") { view: PublisherView, bitrate: Int ->
        view.audioBitrate = bitrate
      }
      Prop("audioSampleRate") { view: PublisherView, rate: Int ->
        view.audioSampleRate = rate
      }
      Prop("frontCamera") { view: PublisherView, front: Boolean ->
        view.isFrontCamera = front
      }
    }

    // ======== Player View ========
    View(PlayerView::class) {
      Events(
        "onPlayerStateChanged",
        "onPlayerError"
      )

      Prop("url") { view: PlayerView, url: String ->
        view.url = url
      }
      Prop("streamName") { view: PlayerView, name: String ->
        view.streamName = name
      }
    }
  }
}
