import Foundation
import React
#if canImport(ExpoModulesCore)
import ExpoModulesCore

public class ExpoLiveStreamModule: Module {
  public func definition() -> ModuleDefinition {
    Name("ExpoLiveStream")

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
        view.frontCamera = front
      }
    }
  }
}
#endif

@objc(ExpoLiveStreamRNViewManager)
public class ExpoLiveStreamRNViewManager: RCTViewManager {
  public override static func requiresMainQueueSetup() -> Bool {
    return true
  }

  public override func view() -> UIView! {
    return PublisherView()
  }

  @objc public func start(_ url: String?) {
    DispatchQueue.main.async {
      PublisherView.activeInstance?.start(urlOverride: url)
    }
  }

  @objc public func stop() {
    DispatchQueue.main.async {
      PublisherView.activeInstance?.stop()
    }
  }

  @objc public func switchCamera() {
    DispatchQueue.main.async {
      PublisherView.activeInstance?.switchCamera()
    }
  }

  @objc public func toggleFlash() {
    DispatchQueue.main.async {
      PublisherView.activeInstance?.toggleFlash()
    }
  }

  @objc public func toggleMute() {
    DispatchQueue.main.async {
      PublisherView.activeInstance?.toggleMute()
    }
  }
}
