import ExpoModulesCore

public class ExpoLiveStreamPlayerModule: Module {
  public func definition() -> ModuleDefinition {
    Name("ExpoLiveStreamPlayer")

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
