import ExpoModulesCore
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

  // MARK: - Events
  let onPlayerStateChanged = EventDispatcher()
  let onPlayerError = EventDispatcher()

  // MARK: - State (exactly matches Android PlayerView.kt)
  private var isPlaying = false
  private var lastPlayRequestAt: TimeInterval = 0
  // Auto-reconnect (matches ExoPlayer's built-in retry)
  private var reconnectAttempts = 0
  private let maxReconnectAttempts = 3
  private var reconnectTimer: Timer?

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
    var connectUrl = url
    let playName = streamName
    if !playName.isEmpty && !connectUrl.hasSuffix("/\(playName)") {
      connectUrl = "\(connectUrl)/\(playName)"
    }
    return connectUrl
  }

  private func createMedia(url mediaUrl: URL) -> VLCMedia {
    let media = VLCMedia(url: mediaUrl)
    media.addOption("--network-caching=100")
    media.addOption("--rtmp-buffer=0")
    media.addOption("--live-caching=100")
    media.addOption("--clock-jitter=0")
    media.addOption("--clock-synchro=0")
    media.addOption("--file-caching=0")
    media.addOption("--drop-late-frames")
    media.addOption("--skip-frames")
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
  }

  // Matches Android stop()
  func stop() {
    guard isPlaying || mediaPlayer?.isPlaying == true else { return }
    isPlaying = false
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
  }

  // MARK: - VLCMediaPlayerDelegate (matches Android Player.Listener)

  func mediaPlayerStateChanged(_ aNotification: Notification) {
    guard let player = mediaPlayer else { return }

    switch player.state {
    case .playing:
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

  // MARK: - Smart Reconnect Poller
  // Polls every 5 seconds to see if stream is back online (publisher restarted)
  // Doesn't interfere with normal playback — only activates after stream actually dies
  private func startReconnectPoller() {
    // Don't start multiple pollers
    guard reconnectTimer == nil else { return }
    reconnectAttempts = 0

    print("[ExpoLiveStreamPlayer] stream lost — starting reconnect poller")
    onPlayerStateChanged(["state": "buffering"])

    reconnectTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] timer in
      guard let self = self else { timer.invalidate(); return }

      self.reconnectAttempts += 1
      print("[ExpoLiveStreamPlayer] reconnect poll \(self.reconnectAttempts)/\(self.maxReconnectAttempts)")

      if self.reconnectAttempts >= self.maxReconnectAttempts {
        // Give up
        timer.invalidate()
        self.reconnectTimer = nil
        self.isPlaying = false
        self.reconnectAttempts = 0
        self.onPlayerError(["msg": "Stream lost — reconnect failed"])
        self.onPlayerStateChanged(["state": "failed"])
        return
      }

      // Try fresh connection with new media
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

  private var lastReportedState = ""

  func mediaPlayerTimeChanged(_ aNotification: Notification) {
    guard let player = mediaPlayer, player.isPlaying else { return }
    if lastReportedState != "playing" {
      lastReportedState = "playing"
      onPlayerStateChanged(["state": "playing"])
    }
  }

  // MARK: - Cleanup (matches Android cleanup + onDetachedFromWindow)

  private func cleanup() {
    reconnectTimer?.invalidate()
    reconnectTimer = nil
    if let observer = orientationObserver {
      NotificationCenter.default.removeObserver(observer)
      orientationObserver = nil
    }
    isPlaying = false // Set BEFORE stop() to prevent VLC delegate from starting reconnect poller
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
