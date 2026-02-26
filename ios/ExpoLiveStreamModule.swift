import ExpoModulesCore

public class ExpoLiveStreamModule: Module {
  public func definition() -> ModuleDefinition {
    Name("ExpoLiveStream")

    // ======== Publisher Functions ========
    AsyncFunction("start") { (url: String?) in
      await MainActor.run {
        PublisherView.activeInstance?.start(urlOverride: url)
      }
    }

    AsyncFunction("stop") {
      await MainActor.run {
        PublisherView.activeInstance?.stop()
      }
    }

    AsyncFunction("switchCamera") {
      await MainActor.run {
        PublisherView.activeInstance?.switchCamera()
      }
    }

    AsyncFunction("toggleFlash") {
      await MainActor.run {
        PublisherView.activeInstance?.toggleFlash()
      }
    }

    AsyncFunction("toggleMute") {
      await MainActor.run {
        PublisherView.activeInstance?.toggleMute()
      }
    }

    // ======== Player Functions ========
    AsyncFunction("playerPlay") {
      await MainActor.run {
        PlayerView.activeInstance?.play()
      }
    }

    AsyncFunction("playerStop") {
      await MainActor.run {
        PlayerView.activeInstance?.stop()
      }
    }

    AsyncFunction("playerPause") {
      await MainActor.run {
        PlayerView.activeInstance?.pause()
      }
    }

    AsyncFunction("playerResume") {
      await MainActor.run {
        PlayerView.activeInstance?.resume()
      }
    }

    AsyncFunction("playerSetVolume") { (volume: Double) in
      await MainActor.run {
        PlayerView.activeInstance?.setVolume(volume)
      }
    }

    AsyncFunction("playerSetMuted") { (muted: Bool) in
      await MainActor.run {
        PlayerView.activeInstance?.setMuted(muted)
      }
    }

    AsyncFunction("playerSeekTo") { (positionMs: Int) in
      await MainActor.run {
        PlayerView.activeInstance?.seekTo(positionMs)
      }
    }

    AsyncFunction("playerGetPosition") { () -> Int in
      await MainActor.run {
        return PlayerView.activeInstance?.getPosition() ?? 0
      }
    }

    AsyncFunction("playerGetDuration") { () -> Int in
      await MainActor.run {
        return PlayerView.activeInstance?.getDuration() ?? 0
      }
    }

    AsyncFunction("playerSetRate") { (rate: Float) in
      await MainActor.run {
        PlayerView.activeInstance?.setRate(rate)
      }
    }

    // ── Recording ──
    AsyncFunction("publisherStartRecording") { () -> String in
      await MainActor.run {
        return PublisherView.activeInstance?.startRecording() ?? ""
      }
    }

    AsyncFunction("publisherStopRecording") {
      await MainActor.run {
        PublisherView.activeInstance?.stopRecording()
      }
    }

    AsyncFunction("publisherIsRecording") { () -> Bool in
      await MainActor.run {
        return PublisherView.activeInstance?.getIsRecording() ?? false
      }
    }

    // ── Camera Controls ──
    AsyncFunction("publisherSetZoom") { (level: Float) in
      await MainActor.run {
        PublisherView.activeInstance?.setZoom(level)
      }
    }

    AsyncFunction("publisherGetZoom") { () -> Float in
      await MainActor.run {
        return PublisherView.activeInstance?.getZoom() ?? 0
      }
    }

    AsyncFunction("publisherGetMaxZoom") { () -> Float in
      await MainActor.run {
        return PublisherView.activeInstance?.getMaxZoom() ?? 1
      }
    }

    AsyncFunction("publisherSetExposure") { (value: Float) in
      await MainActor.run {
        PublisherView.activeInstance?.setExposureCompensation(value)
      }
    }

    AsyncFunction("publisherGetExposure") { () -> Float in
      await MainActor.run {
        return PublisherView.activeInstance?.getExposureCompensation() ?? 0
      }
    }

    // ── Filters ──
    AsyncFunction("publisherSetFilter") { (name: String) in
      await MainActor.run {
        PublisherView.activeInstance?.setFilter(name)
      }
    }

    AsyncFunction("publisherGetFilter") { () -> String in
      await MainActor.run {
        return PublisherView.activeInstance?.getFilter() ?? "none"
      }
    }

    AsyncFunction("publisherGetAvailableFilters") { () -> [String] in
      await MainActor.run {
        return PublisherView.activeInstance?.getAvailableFilters() ?? []
      }
    }

    // ── Phase 7: Multi-Destination ──
    AsyncFunction("publisherStartMulti") { (urls: [String]) in
      await MainActor.run { PublisherView.activeInstance?.startMulti(urls) }
    }

    AsyncFunction("publisherStopMulti") { () in
      await MainActor.run { PublisherView.activeInstance?.stopMulti() }
    }

    AsyncFunction("publisherGetMultiDestinations") { () -> [String] in
      await MainActor.run { return PublisherView.activeInstance?.getMultiDestinations() ?? [] }
    }

    // ── Phase 8: Overlay ──
    AsyncFunction("publisherSetTextOverlay") { (text: String, x: Float, y: Float, size: Float) in
      await MainActor.run { PublisherView.activeInstance?.setTextOverlay(text, x: x, y: y, size: size) }
    }

    AsyncFunction("publisherClearOverlay") { () in
      await MainActor.run { PublisherView.activeInstance?.clearOverlay() }
    }

    // ── Phase 9: Audio ──
    AsyncFunction("publisherSetBackgroundMusic") { (path: String, volume: Float) in
      await MainActor.run { PublisherView.activeInstance?.setBackgroundMusic(path, volume: volume) }
    }

    AsyncFunction("publisherStopBackgroundMusic") { () in
      await MainActor.run { PublisherView.activeInstance?.stopBackgroundMusic() }
    }

    // ── Phase 10: Advanced ──
    AsyncFunction("publisherSetAdaptiveBitrate") { (enabled: Bool) in
      await MainActor.run { PublisherView.activeInstance?.setAdaptiveBitrate(enabled) }
    }

    AsyncFunction("publisherGetStreamStats") { () -> [String: Any] in
      await MainActor.run { return PublisherView.activeInstance?.getStreamStats() ?? [:] }
    }

    // ======== Publisher View ========
    View(PublisherView.self) {
      Events(
        "onConnectionSuccess",
        "onConnectionFailed",
        "onDisconnect",
        "onStreamStateChanged",
        "onBitrateUpdate"
      )

      Prop("url") { (view: PublisherView, url: String) in
        view.url = url
      }
      Prop("streamKey") { (view: PublisherView, key: String) in
        view.streamKey = key
      }
      Prop("videoWidth") { (view: PublisherView, width: Int) in
        view.videoWidth = width
      }
      Prop("videoHeight") { (view: PublisherView, height: Int) in
        view.videoHeight = height
      }
      Prop("videoBitrate") { (view: PublisherView, bitrate: Int) in
        view.videoBitrate = bitrate
      }
      Prop("videoFps") { (view: PublisherView, fps: Double) in
        view.videoFps = fps
      }
      Prop("audioBitrate") { (view: PublisherView, bitrate: Int) in
        view.audioBitrate = bitrate
      }
      Prop("audioSampleRate") { (view: PublisherView, rate: Double) in
        view.audioSampleRate = rate
      }
      Prop("frontCamera") { (view: PublisherView, front: Bool) in
        view.isFrontCamera = front
      }
    }

    // ======== Player View ========
    View(PlayerView.self) {
      Events(
        "onPlayerStateChanged",
        "onPlayerError"
      )

      Prop("url") { (view: PlayerView, url: String) in
        view.url = url
      }
      Prop("streamName") { (view: PlayerView, name: String) in
        view.streamName = name
      }
    }
  }
}
