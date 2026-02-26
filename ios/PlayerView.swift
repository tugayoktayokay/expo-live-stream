import ExpoModulesCore
import MobileVLCKit

class PlayerView: ExpoView, VLCMediaPlayerDelegate {

  // MARK: - Static Instance
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

  override init(frame: CGRect) {
    super.init(frame: frame)
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
    player.scaleFactor = 0  // Best fit — matches Android RESIZE_MODE_FIT
    mediaPlayer = player
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

    var connectUrl = url
    let playName = streamName

    if !playName.isEmpty && !connectUrl.hasSuffix("/\(playName)") {
      connectUrl = "\(connectUrl)/\(playName)"
    }

    guard !connectUrl.isEmpty else {
      onPlayerError(["msg": "URL is empty"])
      return
    }

    print("[ExpoLiveStreamPlayer] play: url=\(connectUrl)")
    onPlayerStateChanged(["state": "connecting"])

    mediaPlayer?.stop()
    isPlaying = true

    guard let mediaUrl = URL(string: connectUrl) else {
      onPlayerError(["msg": "Invalid URL"])
      isPlaying = false
      return
    }
    let media = VLCMedia(url: mediaUrl)
    media.addOption("--network-caching=100")
    media.addOption("--rtmp-buffer=0")
    media.addOption("--live-caching=100")
    media.addOption("--clock-jitter=0")
    media.addOption("--clock-synchro=0")
    media.addOption("--file-caching=0")
    // Drop late frames instead of buffering — keeps playback close to real-time
    media.addOption("--drop-late-frames")
    media.addOption("--skip-frames")

    mediaPlayer?.media = media
    mediaPlayer?.play()
  }

  // Matches Android stop()
  func stop() {
    guard isPlaying || mediaPlayer?.isPlaying == true else { return }
    isPlaying = false
    stopReconnectPoller()
    mediaPlayer?.stop()
    print("[ExpoLiveStreamPlayer] stop: success")
    onPlayerStateChanged(["state": "stopped"])
  }

  // Matches Android pause()
  func pause() {
    guard let player = mediaPlayer, player.isPlaying else { return }
    player.pause()
    onPlayerStateChanged(["state": "paused"])
  }

  // Matches Android resume() — for live streams, restart playback to jump to live edge
  // VLC doesn't auto-seek to live edge like ExoPlayer does
  func resume() {
    guard mediaPlayer != nil else { return }
    // For live RTMP: stop and re-play to get the latest live position
    mediaPlayer?.stop()
    mediaPlayer?.play()
    onPlayerStateChanged(["state": "playing"])
  }

  // MARK: - Volume & Seek

  func setVolume(_ volume: Double) {
    // VLC volume: 0-200, we use 0.0-1.0
    let vlcVolume = Int32(max(0, min(1, volume)) * 100)
    mediaPlayer?.audio?.volume = vlcVolume
  }

  func setMuted(_ muted: Bool) {
    if muted {
      mediaPlayer?.audio?.volume = 0
    } else {
      mediaPlayer?.audio?.volume = 100
    }
  }

  func seekTo(_ positionMs: Int) {
    guard let player = mediaPlayer else { return }
    player.time = VLCTime(int: Int32(positionMs))
  }

  func getPosition() -> Int {
    guard let player = mediaPlayer else { return 0 }
    return Int(player.time.intValue)
  }

  func getDuration() -> Int {
    guard let player = mediaPlayer, let media = player.media else { return 0 }
    return Int(media.length.intValue)
  }

  func setRate(_ rate: Float) {
    mediaPlayer?.rate = rate
  }

  // MARK: - VLCMediaPlayerDelegate (matches Android Player.Listener)

  func mediaPlayerStateChanged(_ aNotification: Notification) {
    guard let player = mediaPlayer else { return }

    switch player.state {
    case .playing:
      // Matches Android STATE_READY → "playing"
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
        guard let self = self, let player = self.mediaPlayer, player.isPlaying else { return }
        player.videoAspectRatio = UnsafeMutablePointer<CChar>(mutating: ("FILL_TO_SCREEN" as NSString).utf8String)
      }
      onPlayerStateChanged(["state": "playing"])
      reconnectAttempts = 0  // Reset on successful play
      stopReconnectPoller()  // Stream is back — cancel any poller

    case .buffering:
      // Matches Android STATE_BUFFERING → "buffering"
      onPlayerStateChanged(["state": "buffering"])

    case .error:
      // Stream error — start polling for reconnect
      if isPlaying {
        startReconnectPoller()
      } else {
        onPlayerError(["msg": "VLC playback error"])
        onPlayerStateChanged(["state": "failed"])
      }

    case .ended, .stopped:
      // Stream ended while we expected it to be playing — publisher probably stopped
      // Start polling to reconnect when publisher comes back
      if isPlaying {
        startReconnectPoller()
      }
      // If !isPlaying, user called stop() — do nothing (already handled)

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

      var connectUrl = self.url
      let playName = self.streamName
      if !playName.isEmpty && !connectUrl.hasSuffix("/\(playName)") {
        connectUrl = "\(connectUrl)/\(playName)"
      }
      guard let mediaUrl = URL(string: connectUrl) else { return }

      let media = VLCMedia(url: mediaUrl)
      media.addOption("--network-caching=100")
      media.addOption("--rtmp-buffer=0")
      media.addOption("--live-caching=100")
      media.addOption("--clock-jitter=0")
      media.addOption("--clock-synchro=0")
      media.addOption("--file-caching=0")
      media.addOption("--drop-late-frames")
      media.addOption("--skip-frames")

      self.mediaPlayer?.media = media
      self.mediaPlayer?.play()
    }
  }

  private func stopReconnectPoller() {
    reconnectTimer?.invalidate()
    reconnectTimer = nil
    reconnectAttempts = 0
  }

  // VLC doesn't have ExoPlayer's STATE_READY. When VLC is stuck in "buffering"
  // but actually playing, timeChanged fires. This mimics Android's STATE_READY → "playing".
  func mediaPlayerTimeChanged(_ aNotification: Notification) {
    guard let player = mediaPlayer, player.isPlaying else { return }
    // If VLC says it's playing but we never got the .playing state callback, force it now
    onPlayerStateChanged(["state": "playing"])
  }

  // MARK: - Cleanup (matches Android cleanup + onDetachedFromWindow)

  private func cleanup() {
    reconnectTimer?.invalidate()
    reconnectTimer = nil
    if let observer = orientationObserver {
      NotificationCenter.default.removeObserver(observer)
      orientationObserver = nil
    }
    if isPlaying {
      mediaPlayer?.stop()
      isPlaying = false
    }
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
