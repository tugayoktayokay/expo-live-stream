import ExpoModulesCore
import AVFoundation
import HaishinKit
import VideoToolbox

class PublisherView: ExpoView {

  // MARK: - Active Instance tracking
  static weak var activeInstance: PublisherView?

  // MARK: - RTMP objects
  private var connection: RTMPConnection?
  private var stream: RTMPStream?
  private var mixer: MediaMixer?
  private var hkView: MTHKView?

  // MARK: - Props
  var url: String = ""
  var streamKey: String = ""
  var videoWidth: Int = 720
  var videoHeight: Int = 1280
  var videoBitrate: Int = 2_000_000
  var videoFps: Float64 = 30.0
  var audioBitrate: Int = 128_000
  var audioSampleRate: Double = 44100.0
  var isFrontCamera: Bool = true

  // MARK: - Event emitters
  let onConnectionSuccess = EventDispatcher()
  let onConnectionFailed = EventDispatcher()
  let onDisconnect = EventDispatcher()
  let onStreamStateChanged = EventDispatcher()
  let onBitrateUpdate = EventDispatcher()

  // MARK: - State
  private var isStreaming = false
  private var isPreviewStarted = false
  private var isMuted = false
  private var isFlashOn = false
  private var isSwitchingCamera = false
  private var bitrateTimer: Timer?
  private var wasStreamingBeforeBackground = false
  private var lastStreamUrl: String?

  // MARK: - Init
  required public init(appContext: AppContext? = nil) {
    super.init(appContext: appContext)
    PublisherView.activeInstance = self
    setupStream()
    setupLifecycleObservers()
  }

  override init(frame: CGRect) {
    super.init(frame: frame)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  // MARK: - Lifecycle
  override func layoutSubviews() {
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
    print("[ExpoLiveStream] App going to background")
    wasStreamingBeforeBackground = isStreaming
    if isStreaming {
      isStreaming = false
      stopBitrateTimer()
      Task {
        _ = try? await stream?.close()
        _ = try? await connection?.close()
      }
    }
    // Detach camera (iOS requires this in background)
    if let mixer = mixer {
      Task {
        try? await mixer.attachVideo(nil)
      }
    }
  }

  @objc private func appDidBecomeActive() {
    print("[ExpoLiveStream] App returning to foreground")
    // Reattach camera
    let position: AVCaptureDevice.Position = isFrontCamera ? .front : .back
    let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)

    if let mixer = mixer {
      Task {
        do {
          try await mixer.attachVideo(camera)
        } catch {
          print("[ExpoLiveStream] Camera reattach error: \(error)")
        }

        // Resume stream if it was active before background
        if self.wasStreamingBeforeBackground {
          self.wasStreamingBeforeBackground = false
          await MainActor.run {
            print("[ExpoLiveStream] Resuming stream after background")
            // Re-setup connection and stream
            let conn = RTMPConnection()
            self.connection = conn
            self.stream = RTMPStream(connection: conn)

            if let stream = self.stream, let preview = self.hkView {
              Task {
                await mixer.addOutput(stream)
                await mixer.addOutput(preview)
                // Small delay to let camera stabilize, then start
                try? await Task.sleep(nanoseconds: 300_000_000) // 300ms
                await MainActor.run {
                  self.start(urlOverride: self.lastStreamUrl)
                }
              }
            }
          }
        }
      }
    }
  }

  // MARK: - Mirror
  private func updateMirror() {
    if isFrontCamera {
      hkView?.transform = CGAffineTransform(scaleX: -1, y: 1)
    } else {
      hkView?.transform = .identity
    }
  }

  // MARK: - Setup
  private func setupStream() {
    let conn = RTMPConnection()
    connection = conn
    stream = RTMPStream(connection: conn)
    mixer = MediaMixer()

    let session = AVAudioSession.sharedInstance()
    do {
      try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
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

  // MARK: - Preview
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

  // MARK: - Public Methods
  func start(urlOverride: String?) {
    let targetUrl: String
    if let override = urlOverride, !override.isEmpty {
      targetUrl = override
    } else {
      targetUrl = url
    }

    guard !targetUrl.isEmpty else {
      onConnectionFailed(["msg": "URL is empty"])
      return
    }

    var connectUrl = targetUrl
    var publishKey = streamKey

    if publishKey.isEmpty {
      if let lastSlashRange = targetUrl.range(of: "/", options: .backwards) {
        let pathAfterLastSlash = String(targetUrl[lastSlashRange.upperBound...])
        if !pathAfterLastSlash.isEmpty {
          publishKey = pathAfterLastSlash
          connectUrl = String(targetUrl[..<lastSlashRange.lowerBound])
        }
      }
    }

    isStreaming = true
    lastStreamUrl = targetUrl
    onStreamStateChanged(["state": "connecting"])

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
          downmix: false  // Keep stereo for better ExoPlayer compatibility
        )
        await stream?.setVideoSettings(videoSettings)
        await stream?.setAudioSettings(audioSettings)
        await mixer?.setFrameRate(videoFps)

        _ = try await connection?.connect(connectUrl)
        _ = try await stream?.publish(publishKey)
        await MainActor.run {
          self.onConnectionSuccess([:])
          self.onStreamStateChanged(["state": "streaming"])
          self.startBitrateTimer()
        }
      } catch {
        await MainActor.run {
          self.isStreaming = false
          self.onConnectionFailed(["msg": error.localizedDescription])
          self.onStreamStateChanged(["state": "failed"])
        }
      }
    }
  }

  func stop() {
    guard isStreaming else { return }
    isStreaming = false
    stopBitrateTimer()

    Task {
      _ = try? await stream?.close()
      _ = try? await connection?.close()
      await MainActor.run {
        self.onDisconnect([:])
        self.onStreamStateChanged(["state": "stopped"])

        // Re-setup connection and stream for next use
        let conn = RTMPConnection()
        self.connection = conn
        self.stream = RTMPStream(connection: conn)

        // Re-attach stream to mixer/preview
        if let mixer = self.mixer, let stream = self.stream, let preview = self.hkView {
          Task {
            await mixer.addOutput(stream)
            await mixer.addOutput(preview)
          }
        }
      }
    }
  }

  func switchCamera() {
    guard !isSwitchingCamera else {
      print("[ExpoLiveStream] switchCamera: switch in progress, ignoring")
      return
    }
    isSwitchingCamera = true

    let newPosition: AVCaptureDevice.Position = isFrontCamera ? .back : .front
    isFrontCamera = !isFrontCamera
    updateMirror()

    // Flash auto-off for front camera
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
        // Unlock on main thread after attach completes
        await MainActor.run {
          self.isSwitchingCamera = false
        }
      }
    } else {
      isSwitchingCamera = false
    }
  }

  func toggleFlash() {
    guard !isFrontCamera else {
      print("[ExpoLiveStream] Flash not available on front camera")
      return
    }
    guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
          device.hasTorch else {
      print("[ExpoLiveStream] Torch not available")
      return
    }
    do {
      try device.lockForConfiguration()
      if isFlashOn {
        device.torchMode = .off
      } else {
        try device.setTorchModeOn(level: AVCaptureDevice.maxAvailableTorchLevel)
      }
      device.unlockForConfiguration()
      isFlashOn = !isFlashOn
      print("[ExpoLiveStream] Flash: \(isFlashOn)")
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
        print("[ExpoLiveStream] Muted: \(isMuted)")
      }
    }
  }

  // MARK: - Bitrate Reporting
  private func startBitrateTimer() {
    bitrateTimer?.invalidate()
    bitrateTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
      guard let self = self, let stream = self.stream else { return }
      Task {
        let info = await stream.info
        let bytesPerSecond = info.currentBytesPerSecond
        await MainActor.run {
          self.onBitrateUpdate(["bitrate": bytesPerSecond * 8])
        }
      }
    }
  }

  private func stopBitrateTimer() {
    bitrateTimer?.invalidate()
    bitrateTimer = nil
  }

  override func removeFromSuperview() {
    super.removeFromSuperview()
    if PublisherView.activeInstance === self {
      PublisherView.activeInstance = nil
    }
    stopBitrateTimer()
    if isStreaming {
      stop()
    }
  }

  // MARK: - Cleanup
  deinit {
    NotificationCenter.default.removeObserver(self)
    bitrateTimer?.invalidate()
    if isStreaming {
      let stream = self.stream
      let connection = self.connection
      Task {
        _ = try? await stream?.close()
        _ = try? await connection?.close()
      }
    }
  }
}
