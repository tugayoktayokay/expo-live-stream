import Foundation
import React
#if canImport(ExpoModulesCore)
import ExpoModulesCore

public class ExpoLiveStreamPlayerModule: Module {
  public func definition() -> ModuleDefinition {
    Name("ExpoLiveStreamPlayer")

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
      Prop("resizeMode") { (view: PlayerView, mode: String) in
        view.resizeMode = mode
      }
    }
  }
}
#endif

@objc(ExpoLiveStreamPlayerRNViewManager)
public class ExpoLiveStreamPlayerRNViewManager: RCTViewManager {
  public override static func requiresMainQueueSetup() -> Bool {
    return true
  }

  public override func view() -> UIView! {
    return PlayerView()
  }

  @objc public func playerPlay() {
    DispatchQueue.main.async {
      PlayerView.activeInstance?.play()
    }
  }

  @objc public func playerStop() {
    DispatchQueue.main.async {
      PlayerView.activeInstance?.stop()
    }
  }

  @objc public func playerPause() {
    DispatchQueue.main.async {
      PlayerView.activeInstance?.pause()
    }
  }

  @objc public func playerResume() {
    DispatchQueue.main.async {
      PlayerView.activeInstance?.resume()
    }
  }
}
