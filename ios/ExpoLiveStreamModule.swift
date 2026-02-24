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
