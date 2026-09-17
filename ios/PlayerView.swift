import ExpoModulesCore
import UIKit
import MobileVLCKit

class PlayerView: ExpoView, VLCMediaPlayerDelegate {

  // MARK: - Static Instance
  /// Singleton reference — only one player can be active at a time.
  /// The instance is set on init and cleared on cleanup.
  static weak var activeInstance: PlayerView?

  // MARK: - VLC Objects
  private var mediaPlayer: VLCMediaPlayer?
  private var videoView: UIView?

  // MARK: - Props
  var url: String = ""
  var streamName: String = ""

  // MARK: - Event emitters
  let onPlayerStateChanged = EventDispatcher()
  let onPlayerError = EventDispatcher()

  // MARK: - State (matches Android)
  private var isPlaying = false
  private var lastPlayRequestAt: TimeInterval = 0
  private var lastReportedState = ""

  // Auto-reconnect (up to 10 attempts ~35s tolerance for server/network glitches)
  private var reconnectAttempts = 0
  private let maxReconnectAttempts = 10
  private var reconnectTimer: Timer?

  // Silent stall watchdog — detects if video frames stop arriving for >8s
  private var lastFrameTime: TimeInterval = 0
  private var stallCheckTimer: Timer?

  // MARK: - Rotation (matches Android DisplayManager.DisplayListener)
  private var orientationObserver: NSObjectProtocol?

  // MARK: - Init
  required public init(appContext: AppContext? = nil) {
    super.init(appContext: appContext)
    PlayerView.activeInstance = self
    setupView()
    registerOrientationListener()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  // MARK: - Rotation Handling (matches Android DisplayManager.DisplayListener)
  private func registerOrientationListener() {
    orientationObserver = NotificationCenter.default.addObserver(
      forName: UIDevice.orientationDidChangeNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.forceRemeasure()
    }
  }

  // Matches Android forceRemeasure()
  private func forceRemeasure() {
    guard let videoView = videoView else { return }
    videoView.frame = bounds
  }

  // MARK: - Layout (matches Android onLayout + requestLayout)
  override func layoutSubviews() {
    super.layoutSubviews()
    forceRemeasure()
  }

  // MARK: - Setup (matches Android setupView)
  private func setupView() {
    let view = UIView(frame: bounds)
    view.backgroundColor = .black
    view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    addSubview(view)
    videoView = view

    let player = VLCMediaPlayer()
    player.delegate = self
    player.drawable = view
    mediaPlayer = player
  }

  // MARK: - Helpers

  private func buildConnectUrl() -> String {
    var connectUrl = url.trimmingCharacters(in: .whitespacesAndNewlines)
    let playName = streamName.trimmingCharacters(in: .whitespacesAndNewlines)
    if !playName.isEmpty && !connectUrl.hasSuffix("/\(playName)") {
      connectUrl = connectUrl.hasSuffix("/") ? "\(connectUrl)\(playName)" : "\(connectUrl)/\(playName)"
    }
    return connectUrl
  }

  private func createMedia(url mediaUrl: URL) -> VLCMedia {
    let media = VLCMedia(url: mediaUrl)
    media.addOption("--network-caching=1500")
    media.addOption("--rtmp-buffer=100")
    media.addOption("--live-caching=1500")
    media.addOption("--clock-jitter=0")
    media.addOption("--clock-synchro=0")
    media.addOption("--file-caching=300")
    media.addOption(":network-caching=1500")
    media.addOption(":rtmp-buffer=100")
    media.addOption(":live-caching=1500")
    media.addOption(":clock-jitter=0")
    media.addOption(":clock-synchro=0")
    media.addOption(":file-caching=300")
    media.addOption(":codec=all")
    return media
  }

  // MARK: - Public Methods

  // Matches Android play() — with 800ms duplicate throttle
  func play() {
    let now = Date().timeIntervalSince1970
    if now - lastPlayRequestAt < 0.8 {
      print("[ExpoLiveStreamPlayer] play: duplicate request ignored")
      return
    }
    lastPlayRequestAt = now

    if isPlaying {
      print("[ExpoLiveStreamPlayer] play: already active, ignoring")
      return
    }

    let connectUrl = buildConnectUrl()

    guard !connectUrl.isEmpty else {
      onPlayerError(["msg": "URL is empty"])
      return
    }

    print("[ExpoLiveStreamPlayer] play: url=\(connectUrl)")
    lastReportedState = "connecting"
    onPlayerStateChanged(["state": "connecting"])

    mediaPlayer?.stop()
    isPlaying = true

    guard let mediaUrl = URL(string: connectUrl) else {
      onPlayerError(["msg": "Invalid URL"])
      isPlaying = false
      return
    }

    mediaPlayer?.media = createMedia(url: mediaUrl)
    mediaPlayer?.play()
    startStallChecker()
  }

  // Matches Android stop()
  func stop() {
    guard isPlaying || mediaPlayer?.isPlaying == true else { return }
    isPlaying = false
    stopStallChecker()
    stopReconnectPoller()
    mediaPlayer?.stop()
    lastReportedState = "stopped"
    print("[ExpoLiveStreamPlayer] stop: success")
    onPlayerStateChanged(["state": "stopped"])
  }

  // Matches Android pause()
  func pause() {
    guard let player = mediaPlayer, player.isPlaying else { return }
    player.pause()
    onPlayerStateChanged(["state": "paused"])
  }

  // Matches Android resume() — creates fresh Media to jump to live edge
  func resume() {
    guard mediaPlayer != nil else { return }
    mediaPlayer?.stop()
    lastReportedState = "connecting"
    onPlayerStateChanged(["state": "connecting"])

    let connectUrl = buildConnectUrl()
    guard let mediaUrl = URL(string: connectUrl) else { return }

    mediaPlayer?.media = createMedia(url: mediaUrl)
    mediaPlayer?.play()
    isPlaying = true
    startStallChecker()
  }

  // MARK: - VLCMediaPlayerDelegate (matches Android Player.Listener)

  func mediaPlayerStateChanged(_ aNotification: Notification) {
    guard let player = mediaPlayer else { return }

    switch player.state {
    case .playing:
      lastFrameTime = Date().timeIntervalSince1970
      if lastReportedState != "playing" {
        lastReportedState = "playing"
        onPlayerStateChanged(["state": "playing"])
      }
      reconnectAttempts = 0
      stopReconnectPoller()

    case .buffering:
      if lastReportedState != "buffering" {
        lastReportedState = "buffering"
        onPlayerStateChanged(["state": "buffering"])
      }

    case .error:
      lastReportedState = "error"
      if isPlaying {
        startReconnectPoller()
      } else {
        onPlayerError(["msg": "VLC playback error"])
        onPlayerStateChanged(["state": "failed"])
      }

    case .ended, .stopped:
      lastReportedState = "stopped"
      if isPlaying {
        startReconnectPoller()
      }

    default:
      break
    }
  }

  // MARK: - Silent Stall Watchdog
  private func startStallChecker() {
    stopStallChecker()
    lastFrameTime = Date().timeIntervalSince1970
    stallCheckTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
      guard let self = self else { return }
      if self.isPlaying && self.lastReportedState == "playing" && self.lastFrameTime > 0 {
        let elapsed = Date().timeIntervalSince1970 - self.lastFrameTime
        if elapsed > 8.0 {
          print("[ExpoLiveStreamPlayer] Stream stalled (\(elapsed)s without frame), auto-reconnecting")
          self.lastFrameTime = 0
          self.startReconnectPoller()
        }
      }
    }
  }

  private func stopStallChecker() {
    stallCheckTimer?.invalidate()
    stallCheckTimer = nil
    lastFrameTime = 0
  }

  // MARK: - Smart Reconnect Poller
  // Polls every 3.5s up to 10 times (~35s tolerance) to recover from server dropouts
  private func startReconnectPoller() {
    guard reconnectTimer == nil else { return }
    reconnectAttempts = 0

    print("[ExpoLiveStreamPlayer] stream lost — starting reconnect poller")
    onPlayerStateChanged(["state": "buffering"])

    reconnectTimer = Timer.scheduledTimer(withTimeInterval: 3.5, repeats: true) { [weak self] timer in
      guard let self = self else { timer.invalidate(); return }

      self.reconnectAttempts += 1
      print("[ExpoLiveStreamPlayer] reconnect poll \(self.reconnectAttempts)/\(self.maxReconnectAttempts)")

      if self.reconnectAttempts >= self.maxReconnectAttempts {
        timer.invalidate()
        self.reconnectTimer = nil
        self.isPlaying = false
        self.reconnectAttempts = 0
        self.onPlayerError(["msg": "Stream lost — reconnect failed"])
        self.onPlayerStateChanged(["state": "failed"])
        return
      }

      self.mediaPlayer?.stop()

      let connectUrl = self.buildConnectUrl()
      guard let mediaUrl = URL(string: connectUrl) else { return }

      self.mediaPlayer?.media = self.createMedia(url: mediaUrl)
      self.mediaPlayer?.play()
    }
  }

  private func stopReconnectPoller() {
    reconnectTimer?.invalidate()
    reconnectTimer = nil
    reconnectAttempts = 0
  }

  func mediaPlayerTimeChanged(_ aNotification: Notification) {
    guard let player = mediaPlayer, player.isPlaying else { return }
    lastFrameTime = Date().timeIntervalSince1970
    if lastReportedState != "playing" {
      lastReportedState = "playing"
      onPlayerStateChanged(["state": "playing"])
    }
  }

  // MARK: - Cleanup (matches Android cleanup + onDetachedFromWindow)

  private func cleanup() {
    stopStallChecker()
    stopReconnectPoller()
    if let observer = orientationObserver {
      NotificationCenter.default.removeObserver(observer)
      orientationObserver = nil
    }
    isPlaying = false
    mediaPlayer?.stop()
    mediaPlayer?.delegate = nil
    mediaPlayer = nil
    if PlayerView.activeInstance === self {
      PlayerView.activeInstance = nil
    }
  }

  override func removeFromSuperview() {
    super.removeFromSuperview()
    cleanup()
  }

  deinit {
    cleanup()
  }
}
