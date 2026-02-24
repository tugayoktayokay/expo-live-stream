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

  // MARK: - State
  private var isPlaying = false

  // MARK: - Init
  required public init(appContext: AppContext? = nil) {
    super.init(appContext: appContext)
    PlayerView.activeInstance = self
    setupPlayer()
  }

  override init(frame: CGRect) {
    super.init(frame: frame)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  // MARK: - Layout
  override func layoutSubviews() {
    super.layoutSubviews()
    videoView?.frame = bounds
  }

  // MARK: - Setup
  private func setupPlayer() {
    let view = UIView(frame: bounds)
    view.backgroundColor = .black
    view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    addSubview(view)
    videoView = view

    let player = VLCMediaPlayer()
    player.delegate = self
    player.drawable = view
    player.scaleFactor = 0  // best fit — fill view maintaining aspect ratio
    mediaPlayer = player
  }

  // MARK: - Public Methods
  func play() {
    var connectUrl = url
    let playName = streamName

    if !playName.isEmpty && !connectUrl.hasSuffix("/\(playName)") {
      connectUrl = "\(connectUrl)/\(playName)"
    }

    guard !connectUrl.isEmpty else {
      onPlayerError(["msg": "URL is empty"])
      return
    }

    // Stop previous playback
    if isPlaying {
      mediaPlayer?.stop()
    }

    isPlaying = true
    onPlayerStateChanged(["state": "connecting"])

    // Configure VLC media with low-latency RTMP options
    let media = VLCMedia(url: URL(string: connectUrl)!)

    media.addOption("--network-caching=150")
    media.addOption("--rtmp-buffer=50")
    media.addOption("--live-caching=150")
    media.addOption("--clock-jitter=0")
    media.addOption("--clock-synchro=0")
    media.addOption("--file-caching=0")

    mediaPlayer?.media = media
    mediaPlayer?.play()
  }

  func stop() {
    guard isPlaying else { return }
    isPlaying = false
    mediaPlayer?.stop()
    onPlayerStateChanged(["state": "stopped"])
  }

  func pause() {
    guard isPlaying else { return }
    mediaPlayer?.pause()
    onPlayerStateChanged(["state": "paused"])
  }

  func resume() {
    mediaPlayer?.play()
    onPlayerStateChanged(["state": "playing"])
  }

  // MARK: - VLCMediaPlayerDelegate
  func mediaPlayerStateChanged(_ aNotification: Notification) {
    guard let player = mediaPlayer else { return }

    switch player.state {
    case .playing:
      // Delay aspect ratio update to ensure VLC rendering is ready
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
        guard let self = self, let player = self.mediaPlayer, player.isPlaying else { return }
        // "FILL_TO_SCREEN" is VLCKit's built-in way to fit without black bars
        player.videoAspectRatio = UnsafeMutablePointer<CChar>(mutating: ("FILL_TO_SCREEN" as NSString).utf8String)
      }
      onPlayerStateChanged(["state": "playing"])
    case .buffering:
      onPlayerStateChanged(["state": "buffering"])
    case .error:
      isPlaying = false
      onPlayerError(["msg": "VLC playback error"])
      onPlayerStateChanged(["state": "failed"])
    case .ended, .stopped:
      isPlaying = false
      onPlayerStateChanged(["state": "stopped"])
    default:
      break
    }
  }

  // MARK: - Cleanup
  override func removeFromSuperview() {
    super.removeFromSuperview()
    if PlayerView.activeInstance === self {
      PlayerView.activeInstance = nil
    }
    if isPlaying {
      mediaPlayer?.stop()
      isPlaying = false
    }
    mediaPlayer?.delegate = nil
    mediaPlayer = nil
  }

  deinit {
    mediaPlayer?.stop()
    mediaPlayer?.delegate = nil
    mediaPlayer = nil
  }
}
