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
