package expo.modules.livestream

import expo.modules.kotlin.modules.Module
import expo.modules.kotlin.modules.ModuleDefinition

class ExpoLiveStreamPlayerModule : Module() {
  override fun definition() = ModuleDefinition {
    Name("ExpoLiveStreamPlayer")

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
