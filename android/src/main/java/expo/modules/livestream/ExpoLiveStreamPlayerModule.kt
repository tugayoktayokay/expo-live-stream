package expo.modules.livestream

import expo.modules.kotlin.modules.Module
import expo.modules.kotlin.modules.ModuleDefinition

class ExpoLiveStreamPlayerModule : Module() {
  override fun definition() = ModuleDefinition {
    Name("ExpoLiveStreamPlayer")

    // ======== Player Functions ========
    AsyncFunction("playerPlay") {
      PlayerView.activeInstance?.let { view -> view.post { view.play() } }
    }

    AsyncFunction("playerStop") {
      PlayerView.activeInstance?.let { view -> view.post { view.stop() } }
    }

    AsyncFunction("playerPause") {
      PlayerView.activeInstance?.let { view -> view.post { view.pause() } }
    }

    AsyncFunction("playerResume") {
      PlayerView.activeInstance?.let { view -> view.post { view.resume() } }
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
