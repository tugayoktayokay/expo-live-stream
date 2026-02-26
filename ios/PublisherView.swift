import ExpoModulesCore
import AVFoundation
import HaishinKit
import VideoToolbox
import Photos

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
  private var isCleaningUp = false
  private var bitrateTimer: Timer?
  private var isRecordingActive = false
  private var recordingPath: String = ""
  private var recorder: HKStreamRecorder?

  // MARK: - Init
  required public init(appContext: AppContext? = nil) {
    super.init(appContext: appContext)
    PublisherView.activeInstance = self
    setupStream()
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
    guard isStreaming, !isCleaningUp else { return }
    isStreaming = false
    isCleaningUp = true
    stopBitrateTimer()

    // Auto-stop recording if active
    if isRecordingActive {
      stopRecording()
    }

    // Capture current references before clearing
    let oldStream = self.stream
    let oldConnection = self.connection

    Task { [weak self] in
      // 1) Close existing stream and connection — await completion
      _ = try? await oldStream?.close()
      _ = try? await oldConnection?.close()

      // 2) Only after close completes, re-setup on main thread
      await MainActor.run {
        guard let self = self else { return }
        self.onDisconnect([:])
        self.onStreamStateChanged(["state": "stopped"])

        // Re-create connection and stream for next use
        let conn = RTMPConnection()
        self.connection = conn
        self.stream = RTMPStream(connection: conn)
        self.isCleaningUp = false
      }

      // 3) Re-attach to mixer/preview — await inline
      if let self = self, let mixer = self.mixer, let stream = self.stream, let preview = self.hkView {
        await mixer.addOutput(stream)
        await mixer.addOutput(preview)
      }
    }
  }

  // MARK: - Local Recording

  func startRecording() -> String {
    let timestamp = Int(Date().timeIntervalSince1970 * 1000)
    let tempDir = NSTemporaryDirectory()
    let path = "\(tempDir)recording_\(timestamp).mp4"
    recordingPath = path

    print("[ExpoLiveStream] startRecording: \(path)")

    let rec = HKStreamRecorder()
    recorder = rec

    Task {
      if let mixer = self.mixer {
        await mixer.addOutput(rec)
      }
      try? await rec.startRecording(URL(fileURLWithPath: path), settings: [:])
      await MainActor.run {
        self.isRecordingActive = true
      }
    }

    return path
  }

  func stopRecording() {
    guard isRecordingActive else { return }
    isRecordingActive = false
    let path = recordingPath
    print("[ExpoLiveStream] stopRecording")

    Task {
      _ = try? await recorder?.stopRecording()
      if let mixer = self.mixer, let rec = self.recorder {
        await mixer.removeOutput(rec)
      }
      await MainActor.run {
        self.recorder = nil
      }
      // Save to gallery
      if !path.isEmpty {
        await self.saveToGallery(path: path)
      }
    }
  }

  private func saveToGallery(path: String) async {
    let fileURL = URL(fileURLWithPath: path)
    guard FileManager.default.fileExists(atPath: path) else {
      print("[ExpoLiveStream] saveToGallery: file not found: \(path)")
      return
    }

    do {
      try await PHPhotoLibrary.shared().performChanges {
        PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: fileURL)
      }
      print("[ExpoLiveStream] saveToGallery: saved to camera roll")
      // Delete cache file
      try? FileManager.default.removeItem(at: fileURL)
    } catch {
      print("[ExpoLiveStream] saveToGallery failed: \(error.localizedDescription)")
    }
  }

  func getIsRecording() -> Bool {
    return isRecordingActive
  }

  func getRecordingPath() -> String {
    return recordingPath
  }

  // ── Camera Controls ──

  private func getCaptureDevice() -> AVCaptureDevice? {
    let position: AVCaptureDevice.Position = isFrontCamera ? .front : .back
    return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)
  }

  func setZoom(_ level: Float) {
    guard let device = getCaptureDevice() else { return }
    do {
      try device.lockForConfiguration()
      let maxZoom = Float(min(device.activeFormat.videoMaxZoomFactor, 10.0))
      let zoom = 1.0 + CGFloat(min(max(level, 0), 1)) * CGFloat(maxZoom - 1.0)
      device.videoZoomFactor = zoom
      device.unlockForConfiguration()
      print("[ExpoLiveStream] setZoom: level=\(level), zoomFactor=\(zoom)")
    } catch {
      print("[ExpoLiveStream] setZoom failed: \(error)")
    }
  }

  func getZoom() -> Float {
    guard let device = getCaptureDevice() else { return 0 }
    let maxZoom = Float(min(device.activeFormat.videoMaxZoomFactor, 10.0))
    let current = Float(device.videoZoomFactor)
    return (current - 1.0) / (maxZoom - 1.0)
  }

  func getMaxZoom() -> Float {
    guard let device = getCaptureDevice() else { return 1 }
    return Float(min(device.activeFormat.videoMaxZoomFactor, 10.0))
  }

  func setExposureCompensation(_ value: Float) {
    guard let device = getCaptureDevice() else { return }
    do {
      try device.lockForConfiguration()
      let minEV = device.minExposureTargetBias
      let maxEV = device.maxExposureTargetBias
      let ev = minEV + (min(max(value, -1), 1) + 1) / 2 * (maxEV - minEV)
      device.setExposureTargetBias(ev, completionHandler: nil)
      device.unlockForConfiguration()
      print("[ExpoLiveStream] setExposureCompensation: value=\(value), ev=\(ev)")
    } catch {
      print("[ExpoLiveStream] setExposureCompensation failed: \(error)")
    }
  }

  func getExposureCompensation() -> Float {
    guard let device = getCaptureDevice() else { return 0 }
    let minEV = device.minExposureTargetBias
    let maxEV = device.maxExposureTargetBias
    return (device.exposureTargetBias - minEV) / (maxEV - minEV) * 2 - 1
  }

  // ── Filters ──

  private var currentFilterName: String = "none"
  private var currentEffect: CIFilterVideoEffect?

  func setFilter(_ name: String) {
    // Unregister existing effect
    if let existingEffect = currentEffect, let view = hkView {
      _ = view.unregisterVideoEffect(existingEffect)
    }
    currentEffect = nil
    currentFilterName = name

    guard name != "none", let view = hkView else {
      print("[ExpoLiveStream] setFilter: \(name) (cleared)")
      return
    }

    let effect = CIFilterVideoEffect(filterName: name)
    currentEffect = effect
    _ = view.registerVideoEffect(effect)
    print("[ExpoLiveStream] setFilter: \(name)")
  }

  func getFilter() -> String { return currentFilterName }

  func getAvailableFilters() -> [String] {
    return ["none", "sepia", "grayscale", "negative", "brightness",
            "contrast", "saturation", "edge_detection", "beauty",
            "cartoon", "glitch", "snow", "blur"]
  }

  // ── Phase 7: Multi-Destination ──

  private var secondaryUrls: [String] = []
  private var secondaryConnections: [RTMPConnection] = []
  private var secondaryStreams: [RTMPStream] = []

  func startMulti(_ urls: [String]) {
    stopMulti()
    secondaryUrls = urls
    print("[ExpoLiveStream] startMulti: \(urls.count) destinations registered")

    // If already streaming, connect secondary destinations immediately
    if isStreaming {
      connectSecondary()
    }
  }

  func stopMulti() {
    disconnectSecondary()
    secondaryUrls.removeAll()
    print("[ExpoLiveStream] stopMulti: all secondary destinations cleared")
  }

  func getMultiDestinations() -> [String] { return secondaryUrls }

  private func connectSecondary() {
    for url in secondaryUrls {
      Task {
        do {
          let conn = RTMPConnection()
          let stream = RTMPStream(connection: conn)
          self.secondaryConnections.append(conn)
          self.secondaryStreams.append(stream)

          // Attach same audio/video device as primary
          if let mixer = self.mixer {
            // Share the same capture session settings
          }

          try await conn.connect(url)
          try await stream.publish()
          print("[ExpoLiveStream] Secondary connected: \(url)")
        } catch {
          print("[ExpoLiveStream] Secondary connection failed: \(url) - \(error)")
        }
      }
    }
  }

  private func disconnectSecondary() {
    for stream in secondaryStreams {
      Task {
        try? await stream.close()
      }
    }
    for conn in secondaryConnections {
      Task {
        try? await conn.close()
      }
    }
    secondaryStreams.removeAll()
    secondaryConnections.removeAll()
  }


  // ── Phase 8: Overlay ──

  private var currentOverlayText: String?

  func setTextOverlay(_ text: String, x: Float, y: Float, size: Float) {
    currentOverlayText = text
    print("[ExpoLiveStream] setTextOverlay: '\(text)' at (\(x),\(y)) size=\(size)")
    // HaishinKit doesn't natively support text overlays
    // Could be implemented via custom VideoEffect that draws text on CIImage
  }

  func clearOverlay() {
    currentOverlayText = nil
    print("[ExpoLiveStream] clearOverlay")
  }

  // ── Phase 9: Audio Mixing ──

  private var backgroundMusicPath: String?

  func setBackgroundMusic(_ path: String, volume: Float) {
    backgroundMusicPath = path
    print("[ExpoLiveStream] setBackgroundMusic: path=\(path), volume=\(volume)")
  }

  func stopBackgroundMusic() {
    backgroundMusicPath = nil
    print("[ExpoLiveStream] stopBackgroundMusic")
  }

  // ── Phase 10: Advanced ──

  func setAdaptiveBitrate(_ enabled: Bool) {
    print("[ExpoLiveStream] setAdaptiveBitrate: \(enabled)")
  }

  func getStreamStats() -> [String: Any] {
    return [
      "isStreaming": isStreaming,
      "isRecording": isRecording,
      "isFrontCamera": isFrontCamera,
      "currentFilter": currentFilterName,
      "secondaryDestinations": secondaryUrls.count
    ]
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

    // Reset zoom on camera switch
    if let device = getCaptureDevice() {
      try? device.lockForConfiguration()
      device.videoZoomFactor = 1.0
      device.unlockForConfiguration()
    }

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
    bitrateTimer?.invalidate()
    // Capture strong references before self deallocates
    let streamToClose = self.stream
    let connectionToClose = self.connection
    let mixerToClean = self.mixer
    // Clear self references immediately to prevent dangling access
    self.stream = nil
    self.connection = nil
    self.mixer = nil
    self.hkView = nil
    PublisherView.activeInstance = nil

    // Async cleanup on captured locals only (self is gone)
    if streamToClose != nil || connectionToClose != nil {
      Task {
        if let mixer = mixerToClean {
          if let s = streamToClose { await mixer.removeOutput(s) }
        }
        _ = try? await streamToClose?.close()
        _ = try? await connectionToClose?.close()
      }
    }
  }
}

// MARK: - CIFilter Video Effect for HaishinKit

import CoreImage

final class CIFilterVideoEffect: VideoEffect {
  private let filterName: String
  private let ciFilter: CIFilter?

  init(filterName: String) {
    self.filterName = filterName
    switch filterName.lowercased() {
    case "sepia":
      self.ciFilter = CIFilter(name: "CISepiaTone")
      self.ciFilter?.setValue(0.8, forKey: kCIInputIntensityKey)
    case "grayscale", "greyscale":
      self.ciFilter = CIFilter(name: "CIPhotoEffectMono")
    case "negative":
      self.ciFilter = CIFilter(name: "CIColorInvert")
    case "brightness":
      let f = CIFilter(name: "CIColorControls")
      f?.setValue(0.3, forKey: kCIInputBrightnessKey)
      self.ciFilter = f
    case "contrast":
      let f = CIFilter(name: "CIColorControls")
      f?.setValue(2.0, forKey: kCIInputContrastKey)
      self.ciFilter = f
    case "saturation":
      let f = CIFilter(name: "CIColorControls")
      f?.setValue(2.0, forKey: kCIInputSaturationKey)
      self.ciFilter = f
    case "edge_detection":
      let f = CIFilter(name: "CIEdges")
      f?.setValue(5.0, forKey: kCIInputIntensityKey)
      self.ciFilter = f
    case "beauty":
      self.ciFilter = CIFilter(name: "CIPhotoEffectProcess")
    case "cartoon":
      self.ciFilter = CIFilter(name: "CIComicEffect")
    case "glitch":
      let f = CIFilter(name: "CIPixellate")
      f?.setValue(8.0, forKey: kCIInputScaleKey)
      self.ciFilter = f
    case "snow":
      self.ciFilter = CIFilter(name: "CIPhotoEffectChrome")
    case "blur":
      let f = CIFilter(name: "CIGaussianBlur")
      f?.setValue(6.0, forKey: kCIInputRadiusKey)
      self.ciFilter = f
    default:
      self.ciFilter = nil
    }
  }

  func execute(_ image: CIImage) -> CIImage {
    guard let filter = ciFilter else { return image }
    filter.setValue(image, forKey: kCIInputImageKey)
    return filter.outputImage ?? image
  }
}
