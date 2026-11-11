import UIKit
import React
import AVFoundation
import HaishinKit
import VideoToolbox
#if canImport(ExpoModulesCore)
import ExpoModulesCore
public typealias PublisherBaseView = ExpoView
#else
public typealias PublisherBaseView = UIView
#endif

private final class WeakPublisherBox {
  weak var value: PublisherView?
  init(_ value: PublisherView) { self.value = value }
}

@objc(PublisherView)
public class PublisherView: PublisherBaseView {

  /// Commands arrive on the native module, not on a view, so they target
  /// "the" active view. Tracking every live view as a stack (most recently
  /// attached last) sends them to the one actually on screen, and a view
  /// going away hands the role back instead of dropping it.
  private static let instancesLock = NSLock()
  private static var liveInstances: [WeakPublisherBox] = []

  static var activeInstance: PublisherView? {
    instancesLock.lock()
    defer { instancesLock.unlock() }
    return liveInstances.compactMap { $0.value }.last
  }

  private static func register(_ view: PublisherView) {
    instancesLock.lock()
    defer { instancesLock.unlock() }
    liveInstances.removeAll { $0.value == nil || $0.value === view }
    liveInstances.append(WeakPublisherBox(view))
  }

  private static func unregister(_ view: PublisherView) {
    instancesLock.lock()
    defer { instancesLock.unlock() }
    liveInstances.removeAll { $0.value == nil || $0.value === view }
  }

  private var connection: RTMPConnection?
  private var stream: RTMPStream?
  private var mixer: MediaMixer?
  private var hkView: MTHKView?

  @objc public var url: String = ""
  @objc public var streamKey: String = ""
  @objc public var videoWidth: Int = 720
  @objc public var videoHeight: Int = 1280
  @objc public var videoBitrate: Int = 2_000_000
  @objc public var videoFps: Float64 = 30.0
  @objc public var audioBitrate: Int = 128_000
  @objc public var audioSampleRate: Double = 44100.0
  @objc public var frontCamera: Bool = true {
    didSet {
      isFrontCamera = frontCamera
      updateMirror()
    }
  }
  var isFrontCamera: Bool = true

  #if canImport(ExpoModulesCore)
  let onConnectionSuccess = EventDispatcher()
  let onConnectionFailed = EventDispatcher()
  let onDisconnect = EventDispatcher()
  let onStreamStateChanged = EventDispatcher()
  let onBitrateUpdate = EventDispatcher()

  private func emitConnectionSuccess(_ data: [String: Any] = [:]) { onConnectionSuccess(data) }
  private func emitConnectionFailed(_ data: [String: Any]) { onConnectionFailed(data) }
  private func emitDisconnect(_ data: [String: Any] = [:]) { onDisconnect(data) }
  private func emitStreamStateChanged(_ data: [String: Any]) { onStreamStateChanged(data) }
  private func emitBitrateUpdate(_ data: [String: Any]) { onBitrateUpdate(data) }
  #else
  @objc public var onConnectionSuccess: RCTDirectEventBlock?
  @objc public var onConnectionFailed: RCTDirectEventBlock?
  @objc public var onDisconnect: RCTDirectEventBlock?
  @objc public var onStreamStateChanged: RCTDirectEventBlock?
  @objc public var onBitrateUpdate: RCTDirectEventBlock?

  private func emitConnectionSuccess(_ data: [String: Any] = [:]) { onConnectionSuccess?(data) }
  private func emitConnectionFailed(_ data: [String: Any]) { onConnectionFailed?(data) }
  private func emitDisconnect(_ data: [String: Any] = [:]) { onDisconnect?(data) }
  private func emitStreamStateChanged(_ data: [String: Any]) { onStreamStateChanged?(data) }
  private func emitBitrateUpdate(_ data: [String: Any]) { onBitrateUpdate?(data) }
  #endif

  private var isStreaming = false
  private var isPreviewStarted = false
  private var isMuted = false
  private var isFlashOn = false
  private var isSwitchingCamera = false
  private var bitrateTimer: Timer?
  private var wasStreamingBeforeBackground = false
  private var lastStreamUrl: String?
  private var lastMirrorFront: Bool?

  #if canImport(ExpoModulesCore)
  required public init(appContext: AppContext? = nil) {
    super.init(appContext: appContext)
    PublisherView.register(self)
    setupStream()
    setupLifecycleObservers()
  }
  #else
  public override init(frame: CGRect) {
    super.init(frame: frame)
    PublisherView.register(self)
    setupStream()
    setupLifecycleObservers()
  }
  #endif

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  public override func didMoveToWindow() {
    super.didMoveToWindow()
    if window != nil { PublisherView.register(self) }
  }

  public override func layoutSubviews() {
    super.layoutSubviews()
    hkView?.frame = bounds
    if !isPreviewStarted && bounds.width > 0 && bounds.height > 0 {
      startPreview()
    }
    updateMirror()
  }

  private func setupLifecycleObservers() {
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(appWillResignActive),
      name: UIApplication.willResignActiveNotification,
      object: nil
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(appDidBecomeActive),
      name: UIApplication.didBecomeActiveNotification,
      object: nil
    )
  }

  @objc private func appWillResignActive() {
    wasStreamingBeforeBackground = isStreaming
    if isStreaming {
      isStreaming = false
      stopBitrateTimer()
      Task {
        _ = try? await stream?.close()
        _ = try? await connection?.close()
      }
    }
    if let mixer = mixer {
      Task {
        try? await mixer.attachVideo(nil)
      }
    }
  }

  @objc private func appDidBecomeActive() {
    guard isPreviewStarted, let mixer = mixer else { return }
    let position: AVCaptureDevice.Position = isFrontCamera ? .front : .back
    let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)
    let shouldResume = wasStreamingBeforeBackground
    wasStreamingBeforeBackground = false
    let oldStream = shouldResume ? self.stream : nil

    Task {
      if shouldResume {
        _ = try? await oldStream?.close()
        _ = try? await self.connection?.close()
        if let old = oldStream {
          await mixer.removeOutput(old)
        }
      }

      do {
        try await mixer.attachVideo(camera)
      } catch {
        print("[ExpoLiveStream] Camera reattach error: \(error)")
      }

      if shouldResume {
        let conn = RTMPConnection()
        let newStream = RTMPStream(connection: conn)
        await mixer.addOutput(newStream)
        await MainActor.run {
          self.connection = conn
          self.stream = newStream
        }
        try? await Task.sleep(nanoseconds: 300_000_000)
        await MainActor.run {
          guard UIApplication.shared.applicationState == .active, !self.isStreaming else { return }
          self.start(urlOverride: self.lastStreamUrl)
        }
      }
    }
  }

  private func updateMirror() {
    guard lastMirrorFront != isFrontCamera else { return }
    lastMirrorFront = isFrontCamera
    if isFrontCamera {
      hkView?.transform = CGAffineTransform(scaleX: -1, y: 1)
    } else {
      hkView?.transform = .identity
    }
  }

  private func setupStream() {
    let conn = RTMPConnection()
    connection = conn
    stream = RTMPStream(connection: conn)
    mixer = MediaMixer()

    // .allowBluetoothHFP is the current spelling; older SDKs only know
    // .allowBluetooth, so pick the one the toolchain actually has.
    var audioOptions: AVAudioSession.CategoryOptions = [.defaultToSpeaker]
    #if compiler(>=6.2)
    audioOptions.insert(.allowBluetoothHFP)
    #else
    audioOptions.insert(.allowBluetooth)
    #endif

    let session = AVAudioSession.sharedInstance()
    do {
      try session.setCategory(.playAndRecord, mode: .default, options: audioOptions)
      try session.setActive(true)
    } catch {
      print("[ExpoLiveStream] Audio session error: \(error)")
    }

    let preview = MTHKView(frame: bounds)
    preview.videoGravity = .resizeAspectFill
    preview.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    addSubview(preview)
    hkView = preview

    if let mixer = mixer, let stream = stream {
      Task {
        await mixer.addOutput(stream)
        await mixer.addOutput(preview)
      }
    }
  }

  private func startPreview() {
    guard !isPreviewStarted else { return }
    isPreviewStarted = true

    let position: AVCaptureDevice.Position = isFrontCamera ? .front : .back
    let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)
    let microphone = AVCaptureDevice.default(for: .audio)

    if let mixer = mixer {
      Task {
        do {
          await mixer.setVideoOrientation(.portrait)
          try await mixer.attachVideo(camera)
          try await mixer.attachAudio(microphone)
          await mixer.setFrameRate(videoFps)
        } catch {
          print("[ExpoLiveStream] Camera/mic attach error: \(error)")
        }
      }
    }
  }

  func start(urlOverride: String?) {
    let rawUrl: String
    if let override = urlOverride, !override.isEmpty {
      rawUrl = override
    } else {
      rawUrl = url
    }

    let trimmedUrl = rawUrl.trimmingCharacters(in: .whitespacesAndNewlines)
    let targetUrl = trimmedUrl.hasSuffix("/") ? String(trimmedUrl.dropLast()) : trimmedUrl

    guard !targetUrl.isEmpty else {
      emitConnectionFailed(["msg": "URL is empty"])
      emitStreamStateChanged(["state": "failed"])
      return
    }

    var connectUrl = targetUrl
    var publishKey = streamKey.trimmingCharacters(in: .whitespacesAndNewlines)

    if !publishKey.isEmpty {
      if connectUrl.hasSuffix("/\(publishKey)") {
        connectUrl = String(connectUrl.dropLast(publishKey.count + 1))
      }
    } else if let lastSlashRange = targetUrl.range(of: "/", options: .backwards) {
      let pathAfterLastSlash = String(targetUrl[lastSlashRange.upperBound...])
      if !pathAfterLastSlash.isEmpty {
        publishKey = pathAfterLastSlash
        connectUrl = String(targetUrl[..<lastSlashRange.lowerBound])
      }
    }

    isStreaming = true
    lastStreamUrl = targetUrl
    emitStreamStateChanged(["state": "connecting"])

    Task {
      do {
        let videoSettings = VideoCodecSettings(
          videoSize: CGSize(width: CGFloat(videoWidth), height: CGFloat(videoHeight)),
          bitRate: videoBitrate,
          maxKeyFrameIntervalDuration: 1,
          allowFrameReordering: false
        )
        let audioSettings = AudioCodecSettings(
          bitRate: audioBitrate,
          downmix: false
        )
        await stream?.setVideoSettings(videoSettings)
        await stream?.setAudioSettings(audioSettings)
        await mixer?.setFrameRate(videoFps)

        _ = try await connection?.connect(connectUrl)
        _ = try await stream?.publish(publishKey)
        await MainActor.run {
          guard self.isStreaming else { return }
          self.emitConnectionSuccess()
          self.emitStreamStateChanged(["state": "streaming"])
          self.startBitrateTimer()
        }
      } catch {
        await MainActor.run {
          self.isStreaming = false
          self.emitConnectionFailed(["msg": error.localizedDescription])
          self.emitStreamStateChanged(["state": "failed"])
        }
      }
    }
  }

  func stop() {
    guard isStreaming else { return }
    isStreaming = false
    stopBitrateTimer()

    let oldStream = self.stream

    Task {
      _ = try? await oldStream?.close()
      _ = try? await self.connection?.close()

      if let mixer = self.mixer, let old = oldStream {
        await mixer.removeOutput(old)
      }

      await MainActor.run {
        self.emitDisconnect()
        self.emitStreamStateChanged(["state": "stopped"])

        guard !self.isStreaming else { return }
        let conn = RTMPConnection()
        self.connection = conn
        self.stream = RTMPStream(connection: conn)

        if let mixer = self.mixer, let stream = self.stream {
          Task {
            await mixer.addOutput(stream)
          }
        }
      }
    }
  }

  func switchCamera() {
    guard !isSwitchingCamera else { return }
    isSwitchingCamera = true
    // Announce the transition so the JS layer can cover the preview while the
    // camera is swapped; the resolved state follows when it settles.
    emitStreamStateChanged(["state": "cameraSwitch"])

    let newPosition: AVCaptureDevice.Position = isFrontCamera ? .back : .front
    isFrontCamera = !isFrontCamera
    updateMirror()

    if isFrontCamera && isFlashOn {
      if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) {
        try? device.lockForConfiguration()
        device.torchMode = .off
        device.unlockForConfiguration()
      }
      isFlashOn = false
    }

    let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: newPosition)

    if let mixer = mixer {
      Task {
        do {
          try await mixer.attachVideo(camera)
        } catch {
          print("[ExpoLiveStream] Switch camera error: \(error)")
        }
        await MainActor.run {
          self.isSwitchingCamera = false
          self.emitStreamStateChanged([
            "state": self.isStreaming ? "streaming" : "idle"
          ])
        }
      }
    } else {
      isSwitchingCamera = false
      emitStreamStateChanged(["state": isStreaming ? "streaming" : "idle"])
    }
  }

  func toggleFlash() {
    guard !isFrontCamera else { return }
    guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
          device.hasTorch else { return }
    do {
      try device.lockForConfiguration()
      if isFlashOn {
        device.torchMode = .off
      } else {
        try device.setTorchModeOn(level: AVCaptureDevice.maxAvailableTorchLevel)
      }
      device.unlockForConfiguration()
      isFlashOn = !isFlashOn
    } catch {
      print("[ExpoLiveStream] Flash toggle error: \(error)")
    }
  }

  func toggleMute() {
    isMuted = !isMuted
    if let mixer = mixer {
      Task {
        var settings = await mixer.audioMixerSettings
        settings.isMuted = isMuted
        await mixer.setAudioMixerSettings(settings)
      }
    }
  }

  private func startBitrateTimer() {
    bitrateTimer?.invalidate()
    bitrateTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
      guard let self = self, let stream = self.stream else { return }
      Task {
        let info = await stream.info
        let bytesPerSecond = info.currentBytesPerSecond
        // RTMPConnection is an actor and publishes no disconnect callback, so
        // the beat that reports bitrate doubles as the drop detector. Android
        // gets this for free from ConnectChecker.onDisconnect().
        let isConnected = await self.connection?.connected ?? false
        await MainActor.run {
          self.emitBitrateUpdate(["bitrate": bytesPerSecond * 8])
          if self.isStreaming && !isConnected {
            self.isStreaming = false
            self.stopBitrateTimer()
            self.emitDisconnect()
            self.emitStreamStateChanged(["state": "disconnected"])
          }
        }
      }
    }
  }

  private func stopBitrateTimer() {
    bitrateTimer?.invalidate()
    bitrateTimer = nil
  }

  /// .playAndRecord is global to the process: leaving it active keeps routing
  /// every later playback through the publisher's configuration.
  private func releaseAudioSession() {
    guard PublisherView.activeInstance == nil else { return }
    if PlayerView.activeInstance != nil {
      try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [])
      return
    }
    do {
      try AVAudioSession.sharedInstance().setActive(
        false,
        options: [.notifyOthersOnDeactivation]
      )
    } catch {
      print("[ExpoLiveStream] Audio session deactivate error: \(error)")
    }
  }

  private func cleanup() {
    NotificationCenter.default.removeObserver(self)
    stopBitrateTimer()
    PublisherView.unregister(self)
    releaseAudioSession()
    isStreaming = false
    let stream = self.stream
    let connection = self.connection
    let mixer = self.mixer
    self.stream = nil
    self.connection = nil
    self.mixer = nil
    Task {
      _ = try? await stream?.close()
      _ = try? await connection?.close()
      try? await mixer?.attachVideo(nil)
      try? await mixer?.attachAudio(nil)
    }
  }

  public override func removeFromSuperview() {
    super.removeFromSuperview()
    cleanup()
  }

  deinit {
    cleanup()
  }
}
