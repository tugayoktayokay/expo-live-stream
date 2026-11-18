import AVFoundation
import CoreMedia
import HaishinKit
import QuartzCore
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

/// Plays decoded PCM buffers on a serial queue and exposes the exact RTMP
/// presentation timestamp (PTS) currently leaving the speaker so `VideoSyncPacer`
/// can lock video presentation to the hardware audio clock.
private final class AudioRenderer: @unchecked Sendable {
  private struct PendingChunk {
    let pcm: AVAudioPCMBuffer
    let pts: Double?
  }

  private struct ScheduledSegment {
    let startNodeSec: Double
    let endNodeSec: Double
    let startPTS: Double
  }

  /// Initial cushion (~128 ms at 48 kHz) before starting playback.
  private static let primeBufferCount = 6
  /// Smaller cushion (~85 ms) after a transient network starve.
  private static let reprimeBufferCount = 4
  /// Buffers kept inside `AVAudioPlayerNode` at any time so CoreAudio never
  /// underruns while keeping excess buffers trimmable in `pending` without
  /// calling `node.stop()` (which would click).
  private static let maxInFlightBuffers = 6
  /// Maximum jitter queue (~300 ms) before dropping stale buffers to stay on
  /// the live edge (total ceiling: ~425 ms).
  private static let maxPendingBuffers = 14

  private let queue = DispatchQueue(label: "expo.livestream.player.audio")
  private let audioGraphLock = NSLock()
  private let clockLock = NSLock()

  private let engine = AVAudioEngine()
  private let node = AVAudioPlayerNode()
  private var currentFormat: AVAudioFormat?
  private var pending: [PendingChunk] = []
  private var inFlight = 0
  private var hasPrimedOnce = false
  private var totalScheduledDurationSec: Double = 0
  private var lastKnownEndPTS: Double = 0
  private var generation: UInt64 = 0
  private var didReportFailure = false

  // Shared clock state read non-blockingly by the main-thread display link.
  private var _segments: [ScheduledSegment] = []
  private var _isNodePlaying = false
  private var _cachedOutputLatency: Double = 0.015

  // Diagnostic counters.
  private var statsEnqueued = 0
  private var statsStarves = 0
  private var statsDrops = 0
  private var statsLoggedAt: TimeInterval = 0

  init() {
    engine.attach(node)
  }

  func enqueue(_ buffer: AVAudioBuffer, when: AVAudioTime) {
    guard let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 else { return }
    let pts: Double? = when.isHostTimeValid
      ? AVAudioTime.seconds(forHostTime: when.hostTime)
      : nil
    queue.async { [weak self] in self?.render(pcm, pts: pts) }
  }

  /// Returns the stream PTS (in seconds) currently audible at the hardware
  /// output, or `nil` when audio is not actively rendering.
  func currentPlaybackPTS() -> Double? {
    clockLock.lock()
    let playing = _isNodePlaying
    let segments = _segments
    let outputLatency = _cachedOutputLatency
    clockLock.unlock()

    guard playing, !segments.isEmpty else { return nil }
    guard audioGraphLock.try() else { return nil }
    guard engine.isRunning,
          node.isPlaying,
          let nodeTime = node.lastRenderTime,
          nodeTime.isSampleTimeValid,
          let playerTime = node.playerTime(forNodeTime: nodeTime),
          playerTime.sampleRate > 0 else {
      audioGraphLock.unlock()
      return nil
    }
    audioGraphLock.unlock()

    let hostNow = mach_absolute_time()
    let elapsedSinceRender: Double
    if nodeTime.isHostTimeValid, hostNow > nodeTime.hostTime {
      elapsedSinceRender = min(AVAudioTime.seconds(forHostTime: hostNow - nodeTime.hostTime), 0.05)
    } else {
      elapsedSinceRender = 0
    }

    let rawPlayedSec = Double(max(0, playerTime.sampleTime)) / playerTime.sampleRate
    let effectivePlayedSec = max(0, rawPlayedSec + elapsedSinceRender - outputLatency)

    for seg in segments where effectivePlayedSec >= seg.startNodeSec && effectivePlayedSec <= seg.endNodeSec {
      return seg.startPTS + (effectivePlayedSec - seg.startNodeSec)
    }
    if let first = segments.first, effectivePlayedSec < first.startNodeSec {
      return first.startPTS - (first.startNodeSec - effectivePlayedSec)
    }
    if let last = segments.last {
      let extra = min(effectivePlayedSec - last.endNodeSec, 0.10)
      return last.startPTS + (last.endNodeSec - last.startNodeSec) + max(0, extra)
    }
    return nil
  }

  func stop() {
    queue.async { [weak self] in
      guard let self = self else { return }
      self.audioGraphLock.lock()
      self.resetLocked()
      if self.engine.isRunning { self.engine.stop() }
      self.audioGraphLock.unlock()
      self.currentFormat = nil
      self.didReportFailure = false
      self.statsEnqueued = 0
      self.statsStarves = 0
      self.statsDrops = 0
      self.statsLoggedAt = 0
    }
  }

  private func resetLocked() {
    generation &+= 1
    if node.isPlaying { node.stop() }
    node.reset()
    pending.removeAll(keepingCapacity: true)
    inFlight = 0
    hasPrimedOnce = false
    totalScheduledDurationSec = 0
    lastKnownEndPTS = 0
    clockLock.lock()
    _segments.removeAll(keepingCapacity: true)
    _isNodePlaying = false
    clockLock.unlock()
  }

  private func render(_ pcm: AVAudioPCMBuffer, pts: Double?) {
    if currentFormat != pcm.format || !engine.isRunning {
      if !rewire(to: pcm.format) { return }
    }
    guard engine.isRunning else { return }

    statsEnqueued += 1
    pending.append(PendingChunk(pcm: pcm, pts: pts))

    if pending.count > Self.maxPendingBuffers {
      let overflow = pending.count - Self.maxPendingBuffers
      pending.removeFirst(overflow)
      statsDrops += overflow
    }

    if node.isPlaying {
      drainPendingToNode()
    } else {
      let needed = hasPrimedOnce ? Self.reprimeBufferCount : Self.primeBufferCount
      if inFlight + pending.count >= needed {
        drainPendingToNode()
        audioGraphLock.lock()
        if engine.isRunning && !node.isPlaying {
          node.play()
        }
        let started = node.isPlaying
        audioGraphLock.unlock()
        if started {
          hasPrimedOnce = true
          clockLock.lock()
          _isNodePlaying = true
          clockLock.unlock()
        }
      }
    }

    logStatsIfDue()
  }

  private func drainPendingToNode() {
    while inFlight < Self.maxInFlightBuffers, !pending.isEmpty {
      let chunk = pending.removeFirst()
      let sampleRate = chunk.pcm.format.sampleRate
      guard sampleRate > 0 else { continue }
      let durationSec = Double(chunk.pcm.frameLength) / sampleRate
      let segStartSec = totalScheduledDurationSec
      let segEndSec = segStartSec + durationSec
      totalScheduledDurationSec = segEndSec

      let resolvedPTS: Double
      if let p = chunk.pts, p.isFinite {
        resolvedPTS = p
        lastKnownEndPTS = p + durationSec
      } else {
        resolvedPTS = lastKnownEndPTS
        lastKnownEndPTS += durationSec
      }

      clockLock.lock()
      _segments.append(ScheduledSegment(
        startNodeSec: segStartSec,
        endNodeSec: segEndSec,
        startPTS: resolvedPTS
      ))
      if _segments.count > 32 {
        _segments.removeFirst(_segments.count - 32)
      }
      clockLock.unlock()

      let gen = generation
      inFlight += 1
      node.scheduleBuffer(chunk.pcm) { [weak self] in
        self?.queue.async {
          guard let self = self, self.generation == gen else { return }
          self.inFlight = max(0, self.inFlight - 1)
          self.drainPendingToNode()
          if self.inFlight == 0, self.pending.isEmpty {
            self.audioGraphLock.lock()
            let wasPlaying = self.node.isPlaying
            if wasPlaying {
              self.node.pause()
            }
            self.audioGraphLock.unlock()
            if wasPlaying {
              self.statsStarves += 1
              self.clockLock.lock()
              self._isNodePlaying = false
              self.clockLock.unlock()
            }
          }
        }
      }
    }
  }

  private func logStatsIfDue() {
    let now = Date().timeIntervalSince1970
    guard now - statsLoggedAt >= 2.0 else { return }
    statsLoggedAt = now
    let outLatency = AVAudioSession.sharedInstance().outputLatency
    clockLock.lock()
    _cachedOutputLatency = max(0, min(outLatency, 0.5))
    clockLock.unlock()
    #if DEBUG
    let rate = engine.outputNode.outputFormat(forBus: 0).sampleRate
    print("[ExpoLiveStream] audio: inFlight=\(inFlight) pending=\(pending.count) enqueued=\(statsEnqueued) starves=\(statsStarves) drops=\(statsDrops) hwRate=\(Int(rate)) srcRate=\(Int(currentFormat?.sampleRate ?? 0)) outLatMs=\(Int(outLatency * 1000))")
    #endif
  }

  private func rewire(to format: AVAudioFormat) -> Bool {
    audioGraphLock.lock()
    resetLocked()
    if engine.isRunning { engine.stop() }
    let session = AVAudioSession.sharedInstance()
    try? session.setActive(true)
    let outLatency = session.outputLatency
    engine.disconnectNodeOutput(node)
    engine.connect(node, to: engine.mainMixerNode, format: format)
    let startError: Error?
    do {
      try engine.start()
      startError = nil
    } catch {
      startError = error
    }
    audioGraphLock.unlock()

    clockLock.lock()
    _cachedOutputLatency = max(0, min(outLatency, 0.5))
    clockLock.unlock()

    if let error = startError {
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

private final class DisplayLinkProxy: NSObject {
  weak var pacer: VideoSyncPacer?
  init(_ pacer: VideoSyncPacer) { self.pacer = pacer }
  @objc func onTick(_ link: CADisplayLink) {
    pacer?.tick()
  }
}

/// Hosts an `AVSampleBufferDisplayLayer`, which presents decoded frames on the
/// compositor at the exact vsync their PTS falls on (no main-thread drawing).
private final class SampleBufferView: UIView {
  override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
  var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }
}

/// Drives video presentation with a `CMTimebase` on the display layer and keeps
/// that timebase locked to `AudioRenderer.currentPlaybackPTS()`.
///
/// Frames are enqueued as soon as they are decoded; the layer itself shows each
/// one when the timebase reaches its PTS and drops only frames that are really
/// late. Lip-sync is held by nudging the timebase rate by a few percent (never
/// visible) and hard-resyncing only on large jumps, so the jittery audio clock
/// never turns into skipped or repeated frames. Video-only streams run the
/// timebase on the host clock.
private final class VideoSyncPacer: @unchecked Sendable {
  /// Drift beyond which the timebase jumps straight to the audio clock.
  private static let hardResyncSec: Double = 0.250
  /// Drift tolerated without any rate correction.
  private static let deadbandSec: Double = 0.015
  /// Rate correction per second of drift, capped by `maxRateDelta`.
  private static let rateGain: Double = 0.5
  private static let maxRateDelta: Double = 0.05
  /// Video-only: how far the timebase may run past the newest frame before it
  /// is pulled back (network stall).
  private static let starveResyncSec: Double = 0.300

  private let lock = NSLock()
  private let enqueueQueue = DispatchQueue(label: "expo.livestream.player.video")
  private var displayLayer: AVSampleBufferDisplayLayer?
  private var timebase: CMTimebase?
  private var hasStarted = false
  private var didResolveStreamOffset = false
  private var streamPTSOffset: Double = 0
  private var lastEnqueuedPTS: Double = 0
  private var currentRate: Double = 0
  private var generation: UInt64 = 0

  private let audioRenderer: AudioRenderer
  private weak var owner: PlayerView?
  private var displayLink: CADisplayLink?

  init(owner: PlayerView, audioRenderer: AudioRenderer) {
    self.owner = owner
    self.audioRenderer = audioRenderer
  }

  /// Binds the pacer to the view's display layer. Main thread only.
  func attach(_ layer: AVSampleBufferDisplayLayer) {
    var tb: CMTimebase?
    CMTimebaseCreateWithSourceClock(
      allocator: kCFAllocatorDefault,
      sourceClock: CMClockGetHostTimeClock(),
      timebaseOut: &tb
    )
    guard let tb else { return }
    CMTimebaseSetRate(tb, rate: 0)
    CMTimebaseSetTime(tb, time: .zero)
    layer.controlTimebase = tb
    lock.lock()
    displayLayer = layer
    timebase = tb
    lock.unlock()
  }

  func start() {
    stop()
    let proxy = DisplayLinkProxy(self)
    let link = CADisplayLink(target: proxy, selector: #selector(DisplayLinkProxy.onTick(_:)))
    if #available(iOS 15.0, *) {
      link.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
    }
    link.add(to: .main, forMode: .common)
    displayLink = link
  }

  func stop() {
    displayLink?.invalidate()
    displayLink = nil
    resetBuffer()
  }

  /// Drops queued frames but keeps the last picture on screen.
  func resetBuffer() {
    lock.lock()
    generation &+= 1
    hasStarted = false
    didResolveStreamOffset = false
    streamPTSOffset = 0
    lastEnqueuedPTS = 0
    let layer = displayLayer
    let tb = timebase
    lock.unlock()
    setRate(0)
    if let tb { CMTimebaseSetTime(tb, time: .zero) }
    enqueueQueue.async { layer?.flush() }
  }

  func enqueue(_ sampleBuffer: CMSampleBuffer) {
    let pts = sampleBuffer.presentationTimeStamp.seconds
    guard pts.isFinite else { return }
    lock.lock()
    let gen = generation
    lock.unlock()

    enqueueQueue.async { [weak self] in
      guard let self else { return }
      self.lock.lock()
      guard gen == self.generation, let layer = self.displayLayer, let tb = self.timebase else {
        self.lock.unlock()
        return
      }
      let firstFrame = !self.hasStarted
      if firstFrame {
        self.hasStarted = true
        CMTimebaseSetTime(tb, time: CMTime(seconds: pts, preferredTimescale: 90_000))
      }
      self.lastEnqueuedPTS = max(self.lastEnqueuedPTS, pts)
      self.lock.unlock()

      if firstFrame { self.setRate(1) }
      if layer.status == .failed || layer.requiresFlushToResumeDecoding {
        layer.flush()
      }
      layer.enqueue(sampleBuffer)
    }
  }

  func tick() {
    guard let view = owner else {
      stop()
      return
    }
    guard view.isRenderingActive else {
      setRate(0)
      return
    }

    let audioPTS = audioRenderer.currentPlaybackPTS()

    lock.lock()
    guard hasStarted, let tb = timebase else {
      lock.unlock()
      return
    }
    let tbNow = CMTimebaseGetTime(tb).seconds
    var newRate = 1.0
    var resyncTo: Double?

    if let aPTS = audioPTS {
      if !didResolveStreamOffset {
        let initialDiff = lastEnqueuedPTS - aPTS
        streamPTSOffset = abs(initialDiff) > 10.0 ? initialDiff : 0
        didResolveStreamOffset = true
      }
      let target = aPTS + streamPTSOffset
      let drift = tbNow - target
      if abs(drift) > Self.hardResyncSec {
        resyncTo = target
      } else if abs(drift) > Self.deadbandSec {
        let delta = max(-Self.maxRateDelta, min(Self.maxRateDelta, drift * Self.rateGain))
        newRate = 1.0 - delta
      }
    } else if lastEnqueuedPTS > 0, tbNow - lastEnqueuedPTS > Self.starveResyncSec {
      resyncTo = lastEnqueuedPTS - 0.05
    }
    lock.unlock()

    if let resyncTo {
      CMTimebaseSetTime(tb, time: CMTime(seconds: resyncTo, preferredTimescale: 90_000))
    }
    setRate(newRate)
  }

  private func setRate(_ rate: Double) {
    lock.lock()
    let tb = timebase
    let changed = abs(currentRate - rate) > 0.001
    if changed { currentRate = rate }
    lock.unlock()
    if changed, let tb { CMTimebaseSetRate(tb, rate: rate) }
  }
}

private final class FrameObserver: HKStreamOutput, @unchecked Sendable {
  private let lock = NSLock()
  private var _lastVideoFrameAt: TimeInterval = 0
  private var _lastAudioBufferAt: TimeInterval = 0
  /// HaishinKit detaches outputs asynchronously, so a torn-down stream can
  /// still deliver buffers; they must not restart the audio engine or move the
  /// video timebase of the stream that replaced it.
  private var _isActive = true
  private let renderer: AudioRenderer
  private let videoPacer: VideoSyncPacer

  init(renderer: AudioRenderer, videoPacer: VideoSyncPacer) {
    self.renderer = renderer
    self.videoPacer = videoPacer
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

  func deactivate() {
    lock.lock()
    _isActive = false
    lock.unlock()
  }

  func stream(_ stream: some HKStream, didOutput buffer: AVAudioBuffer, when: AVAudioTime) {
    let now = Date().timeIntervalSince1970
    lock.lock()
    guard _isActive else { lock.unlock(); return }
    _lastAudioBufferAt = now
    lock.unlock()
    renderer.enqueue(buffer, when: when)
  }

  func stream(_ stream: some HKStream, didOutput video: CMSampleBuffer) {
    let now = Date().timeIntervalSince1970
    lock.lock()
    guard _isActive else { lock.unlock(); return }
    _lastVideoFrameAt = now
    lock.unlock()
    videoPacer.enqueue(video)
  }
}

@objc(PlayerView)
public class PlayerView: PlayerBaseView {

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
  private lazy var videoPacer = VideoSyncPacer(owner: self, audioRenderer: audioRenderer)
  private var videoView: SampleBufferView?
  private var frameObserver: FrameObserver?

  fileprivate var isRenderingActive: Bool {
    isPlaying && !isPaused && stream != nil
  }
  private var statusTask: Task<Void, Never>?

  @objc public var url: String = ""
  @objc public var streamName: String = ""
  @objc public var resizeMode: String = "contain" {
    didSet {
      let gravity: AVLayerVideoGravity = resizeMode == "cover" ? .resizeAspectFill : .resizeAspect
      DispatchQueue.main.async { [weak self] in
        self?.videoView?.displayLayer.videoGravity = gravity
      }
    }
  }

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
  /// Delays grow from 3.5 s to 15 s, so ten attempts ride out about two
  /// minutes of a bad network or a restarting encoder (matches Android).
  private static let reconnectBaseDelay: TimeInterval = 3.5
  private static let reconnectMaxDelay: TimeInterval = 15.0
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
    videoView?.frame = bounds
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
    let view = SampleBufferView(frame: bounds)
    view.backgroundColor = .black
    view.displayLayer.videoGravity = resizeMode == "cover" ? .resizeAspectFill : .resizeAspect
    view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    addSubview(view)
    videoView = view
    videoPacer.attach(view.displayLayer)
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
    updateIdleTimer()
    startPlayback(target)
    startStallChecker()
  }

  /// A viewer watches without touching the screen, so auto-lock would cut the
  /// stream after the idle timeout. Holds the screen on only while some player
  /// in this process is actively playing.
  private func updateIdleTimer() {
    let keepAwake = (isPlaying && !isPaused) || PlayerView.isAnotherInstancePlaying(besides: self)
    if UIApplication.shared.isIdleTimerDisabled != keepAwake {
      UIApplication.shared.isIdleTimerDisabled = keepAwake
    }
  }

  private func startPlayback(_ target: (url: String, name: String)) {
    teardownStream()
    activateAudioSession()

    let conn = RTMPConnection()
    let newStream = RTMPStream(connection: conn)
    let observer = FrameObserver(renderer: audioRenderer, videoPacer: videoPacer)

    connection = conn
    stream = newStream
    frameObserver = observer

    videoPacer.start()
    observeStatus(of: newStream)

    // Video frames and decoded audio both route through `observer`: audio goes
    // to `AudioRenderer` and video goes to `VideoSyncPacer`, which presents on
    // `videoView` with a timebase locked to the hardware audio clock.
    Task { [weak self] in
      do {
        await newStream.addOutput(observer)
        _ = try await conn.connect(target.url)
        _ = try await newStream.play(target.name)
      } catch {
        await MainActor.run { [weak self] in
          // A failure of an attempt that has since been replaced says nothing
          // about the current stream.
          guard let self, self.stream === newStream else { return }
          self.handlePlaybackFailure(error.localizedDescription)
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
          // Closing a replaced or stopped stream reports Connect.Closed; it
          // must not trigger a reconnect or a "failed" for the current one.
          guard let self, self.stream === stream else { return }
          self.handleStatus(status)
        }
      }
    }
  }

  private func handleStatus(_ status: RTMPStatus) {
    switch status.code {
    case "NetStream.Play.Start":
      // nginx-rtmp answers Play.Start even when nobody is publishing, so only
      // a decoded frame (seen by the stall checker) counts as playing.
      // Reporting it here reset the reconnect budget on every attempt, so a
      // missing stream retried forever behind a "playing" state.
      break
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
    updateIdleTimer()
    stopStallChecker()
    stopReconnectPoller()
    teardownStream()
    releaseAudioSession()
    lastReportedState = "stopped"
    emitPlayerStateChanged(["state": "stopped"])
  }

  func pause() {
    guard isPlaying, !isPaused, stream != nil else { return }
    isPaused = true
    updateIdleTimer()
    stopReconnectPoller()
    // resume() reconnects at the live edge anyway, so a paused viewer does not
    // need to hold the connection; keeping it open let buffers already in
    // flight restart audio while paused.
    teardownStream()
    lastReportedState = "paused"
    emitPlayerStateChanged(["state": "paused"])
  }

  func resume() {
    guard isPlaying else {
      play()
      return
    }

    isPaused = false
    updateIdleTimer()
    // Resuming a live stream from where it was paused would replay stale
    // frames or stall if the server dropped the paused subscriber, so reconnect
    // at the live edge (matching Android).
    guard let target = connectTarget() else { return }
    // The stall clock is stale after a pause; restart it so the connecting
    // watchdog measures this attempt, not the pause.
    lastFrameTime = Date().timeIntervalSince1970
    lastReportedState = "connecting"
    emitPlayerStateChanged(["state": "connecting"])
    startPlayback(target)
  }

  private func startStallChecker() {
    stopStallChecker()
    lastFrameTime = Date().timeIntervalSince1970
    stallCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
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
          // Baseline at "now", not 0: the dead stream's observer still holds its
          // last frame time, and comparing against 0 would read that stale frame
          // as fresh, report "playing" and cancel the reconnect it just started.
          self.lastFrameTime = Date().timeIntervalSince1970
          self.startReconnectPoller()
        }
      } else if self.lastReportedState == "connecting", self.reconnectTimer == nil,
                self.lastFrameTime > 0,
                Date().timeIntervalSince1970 - self.lastFrameTime > 15.0 {
        // Connected but never received a frame (no publisher yet): without
        // this the view sat on "connecting" forever.
        self.lastFrameTime = 0
        self.startReconnectPoller()
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
    scheduleReconnectAttempt()
  }

  private func scheduleReconnectAttempt() {
    let delay = min(
      Self.reconnectBaseDelay * pow(1.5, Double(reconnectAttempts)),
      Self.reconnectMaxDelay
    )
    reconnectTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
      guard let self = self, self.reconnectTimer != nil else { return }

      self.reconnectAttempts += 1
      if self.reconnectAttempts >= self.maxReconnectAttempts {
        self.reconnectTimer = nil
        self.isPlaying = false
        self.reconnectAttempts = 0
        self.updateIdleTimer()
        self.teardownStream()
        self.emitPlayerError(["msg": "Stream lost — reconnect failed"])
        self.emitPlayerStateChanged(["state": "failed"])
        return
      }

      if let target = self.connectTarget() {
        self.startPlayback(target)
      }
      self.scheduleReconnectAttempt()
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
    videoPacer.stop()
    audioRenderer.stop()

    let oldStream = stream
    let oldConnection = connection
    let oldObserver = frameObserver
    oldObserver?.deactivate()
    stream = nil
    connection = nil
    frameObserver = nil

    guard oldStream != nil || oldConnection != nil else { return }

    Task {
      if let oldStream {
        if let oldObserver { await oldStream.removeOutput(oldObserver) }
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
    updateIdleTimer()
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
