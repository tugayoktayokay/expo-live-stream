import AVFoundation
import HaishinKit
import React
import UIKit
#if canImport(ExpoModulesCore)
import ExpoModulesCore
public typealias PlayerBaseView = ExpoView
#else
public typealias PlayerBaseView = UIView
#endif

private final class WeakPlayerBox {
  weak var value: PlayerView?
  init(_ value: PlayerView) { self.value = value }
}

/// Plays the decoded audio of an incoming stream.
///
/// HaishinKit ships `AudioPlayer` for exactly this, and it is not usable as of
/// 2.0.9: `AudioPlayerNode.enqueue` advances a running sample counter and reads
/// the resulting absolute `AVAudioTime` *inside an unstructured `Task`*, one
/// task per buffer. Those tasks are not ordered against each other, so buffers
/// reach `scheduleBuffer(_:at:)` carrying one another's timestamps and play
/// back out of order - the metallic, robotic voice. `MediaLink` then paces
/// video off that same clock (`audioPlayer?.currentTime`), which is why the
/// picture stutters along with the sound.
///
/// Handing the buffers over back to back with no explicit time avoids all of
/// it: `AVAudioPlayerNode` plays a queue in the order it was given, and a
/// single serial queue is what makes that order well defined. Video then paces
/// off `MediaLink`'s own display-link clock instead, which runs at real time.

private final class AudioRenderer: @unchecked Sendable {
  /// Buffers to hold before playback starts, and again after a starve.
  ///
  /// HaishinKit decodes AAC in frames of 1024 samples - about 23 ms each - so
  /// this is roughly 280 ms of slack. The first version of this used four
  /// buffers (~90 ms), which is less than ordinary Wi-Fi jitter: the node ran
  /// dry several times a second, and every starve cost a pause/resume. That
  /// chopping is itself what a listener calls robotic, so the cushion has to be
  /// comfortably larger than the jitter it is there to absorb.
  private static let primeBufferCount = 12

  /// Queued audio above this is latency nobody asked for - it means the sender
  /// has been outrunning the receiver's clock. Far enough above the cushion
  /// that jitter alone never reaches it.
  private static let maxQueuedBuffers = 64

  private let queue = DispatchQueue(label: "expo.livestream.player.audio")
  private let engine = AVAudioEngine()
  private let node = AVAudioPlayerNode()
  private var currentFormat: AVAudioFormat?
  private var scheduled = 0
  private var generation: UInt64 = 0
  private var didReportFailure = false

  // Counters for the periodic diagnostic below.
  private var statsEnqueued = 0
  private var statsStarves = 0
  private var statsResets = 0
  private var statsLoggedAt: TimeInterval = 0

  init() {
    engine.attach(node)
  }

  func enqueue(_ buffer: AVAudioBuffer) {
    guard let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 else { return }
    queue.async { [weak self] in self?.render(pcm) }
  }

  func stop() {
    queue.async { [weak self] in
      guard let self = self else { return }
      self.reset()
      if self.engine.isRunning { self.engine.stop() }
      self.currentFormat = nil
      self.didReportFailure = false
      self.statsEnqueued = 0
      self.statsStarves = 0
      self.statsResets = 0
      self.statsLoggedAt = 0
    }
  }

  private func reset() {
    generation &+= 1
    if node.isPlaying { node.stop() }
    node.reset()
    scheduled = 0
  }

  private func render(_ pcm: AVAudioPCMBuffer) {
    if currentFormat != pcm.format, !rewire(to: pcm.format) { return }
    guard engine.isRunning else { return }

    // Latency that has run away cannot be trimmed out of the node's queue -
    // AVAudioPlayerNode has no way to drop what is already scheduled - so the
    // queue is emptied and re-primed. One audible seam beats a viewer who is
    // permanently a second behind.
    if scheduled >= Self.maxQueuedBuffers {
      statsResets += 1
      reset()
    }

    let currentGen = generation
    scheduled += 1
    statsEnqueued += 1
    node.scheduleBuffer(pcm) { [weak self] in
      guard let self = self else { return }
      self.queue.async {
        guard self.generation == currentGen else { return }
        self.scheduled = max(0, self.scheduled - 1)
        // Out of audio: stop rather than let the node render on into silence,
        // so the next burst rebuilds a full cushion before playing again.
        if self.scheduled == 0, self.node.isPlaying {
          self.statsStarves += 1
          self.node.pause()
        }
      }
    }
    if !node.isPlaying, scheduled >= Self.primeBufferCount { node.play() }

    logStatsIfDue()
  }

  /// Debug-only heartbeat. A healthy live stream shows `queued` hovering near
  /// the cushion with `starves` flat; starves climbing means the cushion is too
  /// small for this network, and resets climbing means the sender's clock is
  /// running ahead of ours.
  private func logStatsIfDue() {
    #if DEBUG
    let now = Date().timeIntervalSince1970
    guard now - statsLoggedAt >= 2.0 else { return }
    statsLoggedAt = now
    let rate = engine.outputNode.outputFormat(forBus: 0).sampleRate
    print("[ExpoLiveStream] audio: queued=\(scheduled) enqueued=\(statsEnqueued) starves=\(statsStarves) resets=\(statsResets) hwRate=\(Int(rate)) srcRate=\(Int(currentFormat?.sampleRate ?? 0))")
    #endif
  }

  /// Rebuilds the graph for a new input format. The node goes through the main
  /// mixer rather than straight to the output node, because the mixer is what
  /// resamples the stream's rate to whatever the hardware happens to run at.
  private func rewire(to format: AVAudioFormat) -> Bool {
    reset()
    if engine.isRunning { engine.stop() }
    engine.disconnectNodeOutput(node)
    engine.connect(node, to: engine.mainMixerNode, format: format)
    do {
      try engine.start()
    } catch {
      // One line per failure, not one per buffer.
      if !didReportFailure {
        didReportFailure = true
        print("[ExpoLiveStream] Audio engine start failed: \(error)")
      }
      currentFormat = nil
      return false
    }
    didReportFailure = false
    currentFormat = format
    return true
  }
}

/// Receives decoded frames so the view can tell a live stream from a stalled
/// one, and forwards the audio to `AudioRenderer`. It is a separate object
/// because `HKStreamOutput` is `Sendable` and its callbacks are `nonisolated`,
/// while the view is main-actor bound.
///
/// The video callback only stamps a time behind a lock. Hopping to the main
/// actor per frame - which is what a `Task { @MainActor ... }` in here would do
/// - floods the main queue at frame rate and stalls the whole UI; the watchdog
/// timer reads this stamp on its own schedule instead.
private final class FrameObserver: HKStreamOutput, @unchecked Sendable {
  private let lock = NSLock()
  private var _lastVideoFrameAt: TimeInterval = 0
  private var _lastAudioBufferAt: TimeInterval = 0
  private let renderer: AudioRenderer

  init(renderer: AudioRenderer) {
    self.renderer = renderer
  }

  var lastVideoFrameAt: TimeInterval {
    lock.lock()
    defer { lock.unlock() }
    return _lastVideoFrameAt
  }

  var lastAudioBufferAt: TimeInterval {
    lock.lock()
    defer { lock.unlock() }
    return _lastAudioBufferAt
  }

  func stream(_ stream: some HKStream, didOutput buffer: AVAudioBuffer, when: AVAudioTime) {
    let now = Date().timeIntervalSince1970
    lock.lock()
    _lastAudioBufferAt = now
    lock.unlock()
    renderer.enqueue(buffer)
  }

  func stream(_ stream: some HKStream, didOutput video: CMSampleBuffer) {
    let now = Date().timeIntervalSince1970
    lock.lock()
    _lastVideoFrameAt = now
    lock.unlock()
  }
}

@objc(PlayerView)
public class PlayerView: PlayerBaseView {

  /// Commands arrive on the native module, not on a view, so they target
  /// "the" active view. Tracking every live view as a stack (most recently
  /// attached last) sends them to the one actually on screen, and a view
  /// going away hands the role back instead of dropping it.
  private static let instancesLock = NSLock()
  private static var liveInstances: [WeakPlayerBox] = []

  static var activeInstance: PlayerView? {
    instancesLock.lock()
    defer { instancesLock.unlock() }
    return liveInstances.compactMap { $0.value }.last
  }

  private static func register(_ view: PlayerView) {
    instancesLock.lock()
    defer { instancesLock.unlock() }
    liveInstances.removeAll { $0.value == nil || $0.value === view }
    liveInstances.append(WeakPlayerBox(view))
  }

  private static func unregister(_ view: PlayerView) {
    instancesLock.lock()
    defer { instancesLock.unlock() }
    liveInstances.removeAll { $0.value == nil || $0.value === view }
  }

  /// A mounted view is not necessarily playing, so "is anything else using the
  /// audio session" has to look at playback state, not at registration.
  private static func isAnotherInstancePlaying(besides view: PlayerView) -> Bool {
    instancesLock.lock()
    defer { instancesLock.unlock() }
    return liveInstances.contains {
      guard let other = $0.value, other !== view else { return false }
      return other.isPlaying
    }
  }

  private var connection: RTMPConnection?
  private var stream: RTMPStream?
  private let audioRenderer = AudioRenderer()
  private var hkView: MTHKView?
  private var frameObserver: FrameObserver?
  private var statusTask: Task<Void, Never>?

  @objc public var url: String = ""
  @objc public var streamName: String = ""

  #if canImport(ExpoModulesCore)
  let onPlayerStateChanged = EventDispatcher()
  let onPlayerError = EventDispatcher()

  private func emitPlayerStateChanged(_ data: [String: Any]) { onPlayerStateChanged(data) }
  private func emitPlayerError(_ data: [String: Any]) { onPlayerError(data) }
  #else
  @objc public var onPlayerStateChanged: RCTDirectEventBlock?
  @objc public var onPlayerError: RCTDirectEventBlock?

  private func emitPlayerStateChanged(_ data: [String: Any]) { onPlayerStateChanged?(data) }
  private func emitPlayerError(_ data: [String: Any]) { onPlayerError?(data) }
  #endif

  private var isPlaying = false
  private var isPaused = false
  private var lastPlayRequestAt: TimeInterval = 0
  private var lastReportedState = ""

  private var reconnectAttempts = 0
  private let maxReconnectAttempts = 10
  private var reconnectTimer: Timer?

  private var lastFrameTime: TimeInterval = 0
  private var stallCheckTimer: Timer?
  private var didWarnAboutSilence = false

  private var orientationObserver: NSObjectProtocol?

  #if canImport(ExpoModulesCore)
  required public init(appContext: AppContext? = nil) {
    super.init(appContext: appContext)
    PlayerView.register(self)
    setupView()
    registerOrientationListener()
  }
  #else
  public override init(frame: CGRect) {
    super.init(frame: frame)
    PlayerView.register(self)
    setupView()
    registerOrientationListener()
  }
  #endif

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func registerOrientationListener() {
    orientationObserver = NotificationCenter.default.addObserver(
      forName: UIDevice.orientationDidChangeNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.forceRemeasure()
    }
  }

  private func forceRemeasure() {
    hkView?.frame = bounds
  }

  public override func didMoveToWindow() {
    super.didMoveToWindow()
    if window != nil { PlayerView.register(self) }
  }

  public override func layoutSubviews() {
    super.layoutSubviews()
    forceRemeasure()
  }

  private func setupView() {
    let view = MTHKView(frame: bounds)
    view.backgroundColor = .black
    view.videoGravity = .resizeAspectFill
    view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    addSubview(view)
    hkView = view
  }

  /// RTMP needs the connect URL and the stream name apart: the server accepts
  /// the application URL on connect and the stream name on play. Callers may
  /// pass either `url` + `streamName`, or a single URL with the name as its
  /// last path component, so the name is split back off when it is not given.
  private func connectTarget() -> (url: String, name: String)? {
    let base = url.trimmingCharacters(in: .whitespacesAndNewlines)
    let name = streamName.trimmingCharacters(in: .whitespacesAndNewlines)

    guard !base.isEmpty else { return nil }

    if !name.isEmpty {
      let trimmedBase = base.hasSuffix("/") ? String(base.dropLast()) : base
      if trimmedBase.hasSuffix("/\(name)") {
        let withoutName = String(trimmedBase.dropLast(name.count + 1))
        return withoutName.isEmpty ? nil : (withoutName, name)
      }
      return (trimmedBase, name)
    }

    let trimmedBase = base.hasSuffix("/") ? String(base.dropLast()) : base
    guard let separator = trimmedBase.range(of: "/", options: .backwards) else { return nil }
    let derivedName = String(trimmedBase[separator.upperBound...])
    let derivedUrl = String(trimmedBase[..<separator.lowerBound])
    guard !derivedName.isEmpty, !derivedUrl.isEmpty else { return nil }
    return (derivedUrl, derivedName)
  }

  func play() {
    let now = Date().timeIntervalSince1970
    if now - lastPlayRequestAt < 0.8 { return }
    lastPlayRequestAt = now

    if isPlaying { return }

    guard let target = connectTarget() else {
      lastReportedState = "failed"
      emitPlayerError(["msg": "URL is empty"])
      emitPlayerStateChanged(["state": "failed"])
      return
    }

    lastReportedState = "connecting"
    emitPlayerStateChanged(["state": "connecting"])

    isPlaying = true
    isPaused = false
    didWarnAboutSilence = false
    startPlayback(target)
    startStallChecker()
  }

  private func startPlayback(_ target: (url: String, name: String)) {
    teardownStream()
    activateAudioSession()

    let conn = RTMPConnection()
    let newStream = RTMPStream(connection: conn)
    let observer = FrameObserver(renderer: audioRenderer)

    connection = conn
    stream = newStream
    frameObserver = observer

    observeStatus(of: newStream)

    // No `attachAudioPlayer` on purpose - see `AudioRenderer`. The decoded
    // audio reaches the output observer instead, which the stream dispatches
    // as long as the server grants audio sample access (every RTMP server in
    // practice does; HaishinKit also defaults to granted).
    Task { [weak self] in
      do {
        if let hkView = self?.hkView {
          await newStream.addOutput(hkView)
        }
        await newStream.addOutput(observer)
        _ = try await conn.connect(target.url)
        _ = try await newStream.play(target.name)
      } catch {
        await MainActor.run { [weak self] in
          self?.handlePlaybackFailure(error.localizedDescription)
        }
      }
    }
  }

  /// A viewer wants plain playback unless a publisher is also active in this
  /// process. Overwriting `.playAndRecord` with `.playback` while publishing
  /// would route the stream away and cut off the publisher's microphone.
  private func activateAudioSession() {
    let session = AVAudioSession.sharedInstance()
    if PublisherView.activeInstance != nil, session.category == .playAndRecord {
      try? session.setActive(true)
      return
    }
    do {
      // `.default`, not `.moviePlayback`: the movie mode asks the OS for
      // cinema-oriented signal processing, which is not what a live camera
      // feed wants applied to speech.
      try session.setCategory(.playback, mode: .default, options: [])
      try session.setActive(true)
    } catch {
      print("[ExpoLiveStream] Player audio session error: \(error)")
    }
  }

  /// Only hands the session back if nothing else has claimed it since, so
  /// stopping a player cannot silence a publisher or a sibling player that is
  /// still playing. A sibling that is merely mounted does not count.
  private func releaseAudioSession() {
    guard PublisherView.activeInstance == nil,
          !PlayerView.isAnotherInstancePlaying(besides: self) else { return }
    let session = AVAudioSession.sharedInstance()
    guard session.category == .playback else { return }
    try? session.setActive(false, options: [.notifyOthersOnDeactivation])
  }

  /// `NetStream.Play.*` is the server's own account of what happened, so it is
  /// a better source of truth than guessing from the absence of frames.
  private func observeStatus(of stream: RTMPStream) {
    statusTask?.cancel()
    statusTask = Task { [weak self] in
      for await status in await stream.status {
        if Task.isCancelled { return }
        await MainActor.run { [weak self] in
          self?.handleStatus(status)
        }
      }
    }
  }

  private func handleStatus(_ status: RTMPStatus) {
    switch status.code {
    case "NetStream.Play.Start", "NetStream.Unpause.Notify":
      lastFrameTime = Date().timeIntervalSince1970
      reportPlaying()
    case "NetStream.Play.Stop", "NetStream.Play.Complete":
      if isPlaying { startReconnectPoller() }

    case "NetStream.Play.StreamNotFound", "NetStream.Play.Failed",
         "NetConnection.Connect.Failed", "NetConnection.Connect.Rejected",
         "NetConnection.Connect.Closed":
      if isPlaying {
        startReconnectPoller()
      } else {
        emitPlayerError(["msg": status.description.isEmpty ? status.code : status.description])
        emitPlayerStateChanged(["state": "failed"])
      }

    default:
      if status.level == "error", isPlaying {
        startReconnectPoller()
      }
    }
  }

  private func reportPlaying() {
    guard isPlaying, !isPaused, lastReportedState != "playing" else { return }
    lastReportedState = "playing"
    emitPlayerStateChanged(["state": "playing"])
    reconnectAttempts = 0
    stopReconnectPoller()
  }

  private func handlePlaybackFailure(_ message: String) {
    if isPlaying {
      startReconnectPoller()
    } else {
      emitPlayerError(["msg": message])
      emitPlayerStateChanged(["state": "failed"])
    }
  }

  func stop() {
    guard isPlaying else { return }
    isPlaying = false
    isPaused = false
    stopStallChecker()
    stopReconnectPoller()
    teardownStream()
    releaseAudioSession()
    lastReportedState = "stopped"
    emitPlayerStateChanged(["state": "stopped"])
  }

  func pause() {
    guard isPlaying, !isPaused, let stream else { return }
    isPaused = true
    audioRenderer.stop()
    Task {
      _ = try? await stream.pause(true)
    }
    lastReportedState = "paused"
    emitPlayerStateChanged(["state": "paused"])
  }

  func resume() {
    guard isPlaying else {
      play()
      return
    }

    isPaused = false
    // Resuming a live stream from where it was paused would replay stale
    // frames or stall if the server dropped the paused subscriber, so reconnect
    // at the live edge (matching Android).
    guard let target = connectTarget() else { return }
    lastReportedState = "connecting"
    emitPlayerStateChanged(["state": "connecting"])
    startPlayback(target)
  }

  private func startStallChecker() {
    stopStallChecker()
    lastFrameTime = Date().timeIntervalSince1970
    stallCheckTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
      guard let self = self else { return }
      guard self.isPlaying, !self.isPaused else { return }

      // Frames arriving is the proof that playback is alive; the status code
      // alone can claim success while nothing is being decoded.
      let frameAt = self.frameObserver?.lastVideoFrameAt ?? 0
      if frameAt > self.lastFrameTime {
        self.lastFrameTime = frameAt
        self.reportPlaying()
      }

      if self.lastReportedState == "playing" && self.lastFrameTime > 0 {
        let elapsed = Date().timeIntervalSince1970 - self.lastFrameTime
        if elapsed > 8.0 {
          self.lastFrameTime = 0
          self.startReconnectPoller()
        }
      }

      // Pictures but never a single audio buffer means the server refused
      // audio sample access, which is the one way this playback path can go
      // silent without anything else looking wrong. Say so once.
      if !self.didWarnAboutSilence, frameAt > 0,
         self.frameObserver?.lastAudioBufferAt == 0,
         Date().timeIntervalSince1970 - frameAt < 1.0,
         frameAt - self.lastPlayRequestAt > 5.0 {
        self.didWarnAboutSilence = true
        print("[ExpoLiveStream] Video is playing but no audio arrived - the server is withholding audio sample access")
      }
    }
  }

  private func stopStallChecker() {
    stallCheckTimer?.invalidate()
    stallCheckTimer = nil
    lastFrameTime = 0
  }

  private func startReconnectPoller() {
    guard reconnectTimer == nil else { return }
    reconnectAttempts = 0
    lastReportedState = "buffering"
    emitPlayerStateChanged(["state": "buffering"])

    reconnectTimer = Timer.scheduledTimer(withTimeInterval: 3.5, repeats: true) { [weak self] timer in
      guard let self = self else { timer.invalidate(); return }

      self.reconnectAttempts += 1
      if self.reconnectAttempts >= self.maxReconnectAttempts {
        timer.invalidate()
        self.reconnectTimer = nil
        self.isPlaying = false
        self.reconnectAttempts = 0
        self.teardownStream()
        self.emitPlayerError(["msg": "Stream lost — reconnect failed"])
        self.emitPlayerStateChanged(["state": "failed"])
        return
      }

      guard let target = self.connectTarget() else { return }
      self.startPlayback(target)
    }
  }

  private func stopReconnectPoller() {
    reconnectTimer?.invalidate()
    reconnectTimer = nil
    reconnectAttempts = 0
  }

  private func teardownStream() {
    statusTask?.cancel()
    statusTask = nil
    audioRenderer.stop()

    let oldStream = stream
    let oldConnection = connection
    let oldObserver = frameObserver
    stream = nil
    connection = nil
    frameObserver = nil

    guard oldStream != nil || oldConnection != nil else { return }

    Task { [weak hkView] in
      if let oldStream {
        if let oldObserver { await oldStream.removeOutput(oldObserver) }
        if let hkView {
          await oldStream.removeOutput(hkView)
        }
        _ = try? await oldStream.close()
      }
      _ = try? await oldConnection?.close()
    }
  }

  private func cleanup() {
    stopStallChecker()
    stopReconnectPoller()
    if let observer = orientationObserver {
      NotificationCenter.default.removeObserver(observer)
      orientationObserver = nil
    }
    isPlaying = false
    isPaused = false
    teardownStream()
    PlayerView.unregister(self)
    releaseAudioSession()
  }

  public override func removeFromSuperview() {
    super.removeFromSuperview()
    cleanup()
  }

  deinit {
    cleanup()
  }
}
