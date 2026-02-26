import React, { useState } from "react";
import {
  View,
  Text,
  TouchableOpacity,
  StyleSheet,
  TextInput,
  Alert,
  SafeAreaView,
  Platform,
  PermissionsAndroid,
  PanResponder,
  Animated,
  LayoutAnimation,
  UIManager,
  ToastAndroid,
  Dimensions,
} from "react-native";
import { ScrollView } from "react-native";

// Enable LayoutAnimation on Android
if (
  Platform.OS === "android" &&
  UIManager.setLayoutAnimationEnabledExperimental
) {
  UIManager.setLayoutAnimationEnabledExperimental(true);
}
import {
  ExpoLiveStreamPublisherView,
  ExpoLiveStreamPlayerView,
  useLiveStream,
  useLiveStreamPlayer,
  VideoQuality,
} from "expo-live-stream";

type Mode = "menu" | "publisher" | "player";

export default function App() {
  const [mode, setMode] = useState<Mode>("menu");
  const [rtmpUrl, setRtmpUrl] = useState("rtmp://192.168.68.59/live/test");

  if (mode === "menu") {
    return (
      <SafeAreaView style={styles.container}>
        <Text style={styles.title}>🎬 expo-live-stream</Text>
        <Text style={styles.subtitle}>RTMP Publisher & Player Demo</Text>

        <TextInput
          style={styles.input}
          value={rtmpUrl}
          onChangeText={setRtmpUrl}
          placeholder="RTMP URL"
          placeholderTextColor="#999"
        />

        <TouchableOpacity
          style={[styles.button, { backgroundColor: "#e74c3c" }]}
          onPress={() => requestPermissions().then(() => setMode("publisher"))}
        >
          <Text style={styles.buttonText}>📹 Start Publisher</Text>
        </TouchableOpacity>

        <TouchableOpacity
          style={[styles.button, { backgroundColor: "#3498db" }]}
          onPress={() => setMode("player")}
        >
          <Text style={styles.buttonText}>📺 Start Player</Text>
        </TouchableOpacity>

        <TouchableOpacity
          style={[styles.button, { backgroundColor: "#9b59b6" }]}
          onPress={() => {
            setRtmpUrl(
              "http://commondatastorage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4",
            );
            setMode("player");
          }}
        >
          <Text style={styles.buttonText}>🎬 VOD Test (Seek Bar)</Text>
        </TouchableOpacity>
      </SafeAreaView>
    );
  }

  if (mode === "publisher") {
    return <PublisherScreen url={rtmpUrl} onBack={() => setMode("menu")} />;
  }

  return <PlayerScreen url={rtmpUrl} onBack={() => setMode("menu")} />;
}

// ─── PUBLISHER SCREEN (using useLiveStream hook) ─────────────

function PublisherScreen({ url, onBack }: { url: string; onBack: () => void }) {
  const [isMuted, setIsMuted] = useState(false);
  const [toastMsg, setToastMsg] = useState<string | null>(null);
  const toastTimer = React.useRef<any>(null);

  const showToast = (msg: string) => {
    setToastMsg(msg);
    clearTimeout(toastTimer.current);
    toastTimer.current = setTimeout(() => setToastMsg(null), 2500);
  };
  const [zoomLevel, setZoomLevel] = useState(0);
  const [exposureLevel, setExposureLevel] = useState(0.5);
  const [activeFilter, setActiveFilter] = useState("none");

  const {
    ref,
    state,
    isStreaming,
    error,
    statistics,
    start,
    stop,
    switchCamera,
    toggleFlash,
    toggleMute,
    startRecording,
    stopRecording,
    isRecording,
    setZoom,
    setExposure,
    setFilter,
    handleStreamStateChanged,
    handleConnectionFailed,
    handleConnectionSuccess,
    handleDisconnect,
    handleBitrateUpdate,
  } = useLiveStream();

  const handleToggleMute = () => {
    toggleMute();
    setIsMuted(!isMuted);
  };

  const handleSwitchCamera = () => {
    switchCamera();
    // Reset zoom/exposure to defaults after camera switch
    setZoomLevel(0);
    setExposureLevel(0.5);
  };

  const handleToggleRecording = async () => {
    if (isRecording) {
      stopRecording();
      showToast("✅ Kayıt galeriye kaydedildi");
    } else {
      await startRecording();
      showToast("⏺ Kayıt başladı");
    }
  };

  return (
    <View style={styles.fullScreen}>
      <ExpoLiveStreamPublisherView
        ref={ref}
        style={StyleSheet.absoluteFill as any}
        url={url}
        quality={VideoQuality.HD_720P}
        onStreamStateChanged={handleStreamStateChanged}
        onConnectionFailed={handleConnectionFailed}
        onConnectionSuccess={handleConnectionSuccess}
        onDisconnect={handleDisconnect}
        onBitrateUpdate={handleBitrateUpdate}
      />

      {/* Status Badge */}
      <View style={styles.statusBadge}>
        <View style={[styles.dot, isStreaming && styles.dotLive]} />
        <Text style={styles.statusText}>{state.toUpperCase()}</Text>
        {isStreaming && (
          <Text style={styles.statsText}>
            {statistics.durationFormatted} • {statistics.bitrateFormatted}
          </Text>
        )}
      </View>

      {/* Mute Indicator */}
      {isMuted && (
        <View style={styles.muteBadge}>
          <Text style={styles.muteText}>🔇 SES KAPALI</Text>
        </View>
      )}

      {/* Error Banner */}
      {error && (
        <View style={styles.errorBanner}>
          <Text style={styles.errorText}>⚠️ {error}</Text>
        </View>
      )}

      {/* Recording Badge */}
      {isRecording && (
        <View style={styles.recordingBadge}>
          <View style={styles.recDot} />
          <Text style={styles.recText}>REC</Text>
        </View>
      )}

      {/* Controls */}
      <View style={styles.controls}>
        <ControlButton icon="✕" onPress={onBack} />
        <ControlButton icon="🔄" onPress={handleSwitchCamera} />
        <ControlButton
          icon={isStreaming ? "⏹" : "⏺"}
          onPress={() => (isStreaming ? stop() : start())}
          style={isStreaming ? styles.stopBtn : styles.startBtn}
        />
        <ControlButton
          icon={isMuted ? "🔇" : "🔊"}
          onPress={handleToggleMute}
          style={isMuted ? styles.mutedBtn : undefined}
        />
        <ControlButton icon="⚡" onPress={toggleFlash} />
      </View>

      {/* Floating Record Button (right side) */}
      <TouchableOpacity
        style={[
          styles.floatingRecBtn,
          isRecording && styles.floatingRecBtnActive,
          !isStreaming && styles.disabledBtn,
        ]}
        onPress={handleToggleRecording}
        disabled={!isStreaming}
      >
        <Text style={styles.floatingRecIcon}>{isRecording ? "⏹" : "🔴"}</Text>
        <Text style={styles.floatingRecLabel}>
          {isRecording ? "STOP" : "REC"}
        </Text>
      </TouchableOpacity>

      {/* Zoom & Exposure Sliders (left side) */}
      <View style={styles.sliderPanel}>
        <Text style={styles.sliderLabel}>
          🔍 {Math.round(zoomLevel * 100)}%
        </Text>
        <SliderBar
          value={zoomLevel}
          onValueChange={(v) => {
            setZoomLevel(v);
            setZoom(v);
          }}
          fillColor="#3498db"
        />
        <Text style={[styles.sliderLabel, { marginTop: 12 }]}>
          ☀️ {Math.round((exposureLevel - 0.5) * 200)}%
        </Text>
        <SliderBar
          value={exposureLevel}
          onValueChange={(v) => {
            setExposureLevel(v);
            setExposure(v * 2 - 1);
          }}
          fillColor="#f39c12"
        />
      </View>

      {/* Filter Picker */}
      <View style={styles.filterBar}>
        <ScrollView horizontal showsHorizontalScrollIndicator={false}>
          {[
            "none",
            "sepia",
            "grayscale",
            "negative",
            "beauty",
            "cartoon",
            "glitch",
            "blur",
            "snow",
            "contrast",
            "edge_detection",
            "saturation",
            "brightness",
          ].map((f) => (
            <TouchableOpacity
              key={f}
              style={[
                styles.filterChip,
                activeFilter === f && styles.filterChipActive,
              ]}
              onPress={() => {
                setActiveFilter(f);
                setFilter(f);
              }}
            >
              <Text
                style={[
                  styles.filterChipText,
                  activeFilter === f && styles.filterChipTextActive,
                ]}
              >
                {f === "none" ? "❌" : f === "edge_detection" ? "edge" : f}
              </Text>
            </TouchableOpacity>
          ))}
        </ScrollView>
      </View>

      {/* Toast Notification */}
      {toastMsg && (
        <View style={styles.toastContainer}>
          <Text style={styles.toastText}>{toastMsg}</Text>
        </View>
      )}
    </View>
  );
}

// ─── PLAYER SCREEN (using useLiveStreamPlayer hook) ──────────

function PlayerScreen({ url, onBack }: { url: string; onBack: () => void }) {
  const [isMuted, setIsMuted] = useState(false);
  const [volume, setVolume] = useState(1.0);
  const [position, setPosition] = useState(0);
  const [duration, setDuration] = useState(0);
  const [isSeeking, setIsSeeking] = useState(false);
  const [panelOpen, setPanelOpen] = useState(false);
  const positionTimer = React.useRef<any>(null);
  const panelAnim = React.useRef(new Animated.Value(0)).current;

  const {
    ref,
    state,
    isPlaying,
    isBuffering,
    play,
    stop,
    pause,
    resume,
    setVolume: playerSetVolume,
    setMuted: playerSetMuted,
    seekTo,
    getPosition,
    getDuration,
    setRate,
    handlePlayerStateChanged,
    handlePlayerError,
  } = useLiveStreamPlayer({ autoPlay: true });

  // Detect if URL is VOD (not live)
  const isVod = /\.(mp4|mkv|avi|mov|flv|m3u8)(\?|$)/i.test(url);

  // ── Long-press 2x speed ──
  const [isSpeedUp, setIsSpeedUp] = useState(false);
  const longPressTimer = React.useRef<any>(null);

  const handlePressIn = () => {
    longPressTimer.current = setTimeout(() => {
      setRate(2.0);
      setIsSpeedUp(true);
    }, 400);
  };

  const handlePressOut = () => {
    clearTimeout(longPressTimer.current);
    if (isSpeedUp) {
      setRate(1.0);
      setIsSpeedUp(false);
    }
  };

  const togglePanel = () => {
    const toValue = panelOpen ? 0 : 1;
    setPanelOpen(!panelOpen);
    Animated.spring(panelAnim, {
      toValue,
      useNativeDriver: false,
      friction: 8,
      tension: 60,
    }).start();
  };

  const handleVolumeChange = (newVol: number) => {
    setVolume(newVol);
    setIsMuted(newVol === 0);
    playerSetVolume(newVol);
  };

  const handleToggleMute = () => {
    const newMuted = !isMuted;
    setIsMuted(newMuted);
    playerSetMuted(newMuted);
  };

  const handleSeek = (pct: number) => {
    if (duration > 0) {
      const ms = Math.round(pct * duration);
      seekTo(ms);
      setPosition(ms);
    }
  };

  // Poll position/duration for VOD
  React.useEffect(() => {
    if (!isVod || !isPlaying) return;
    positionTimer.current = setInterval(async () => {
      if (isSeeking) return;
      try {
        const [pos, dur] = await Promise.all([getPosition(), getDuration()]);
        setPosition(pos);
        if (dur > 0) setDuration(dur);
      } catch {}
    }, 500);
    return () => clearInterval(positionTimer.current);
  }, [isVod, isPlaying, isSeeking, getPosition, getDuration]);

  const formatTime = (ms: number) => {
    const totalSec = Math.floor(ms / 1000);
    const m = Math.floor(totalSec / 60);
    const s = totalSec % 60;
    return `${m}:${s.toString().padStart(2, "0")}`;
  };

  // Animated interpolations
  const panelWidth = panelAnim.interpolate({
    inputRange: [0, 1],
    outputRange: [44, 280],
  });
  const sliderOpacity = panelAnim.interpolate({
    inputRange: [0, 0.5, 1],
    outputRange: [0, 0, 1],
  });

  // ── Double-tap to seek + center tap to pause ──
  const lastTapRef = React.useRef<{ time: number; side: string }>({
    time: 0,
    side: "",
  });
  const [seekIndicator, setSeekIndicator] = useState<"left" | "right" | null>(
    null,
  );
  const seekTimerRef = React.useRef<any>(null);
  const singleTapTimer = React.useRef<any>(null);

  const handleDoubleTap = (evt: any) => {
    if (panelOpen) return;
    const tapX = evt.nativeEvent.locationX;
    const screenW = Dimensions.get("window").width;
    const side =
      tapX < screenW * 0.35
        ? "left"
        : tapX > screenW * 0.65
          ? "right"
          : "center";
    const now = Date.now();

    if (
      side !== "center" &&
      isVod &&
      now - lastTapRef.current.time < 300 &&
      lastTapRef.current.side === side
    ) {
      // Double tap on side — seek
      clearTimeout(singleTapTimer.current);
      const skipMs = 10000;
      const newPos =
        side === "left"
          ? Math.max(0, position - skipMs)
          : Math.min(duration, position + skipMs);
      seekTo(newPos);
      setPosition(newPos);
      setSeekIndicator(side as "left" | "right");
      clearTimeout(seekTimerRef.current);
      seekTimerRef.current = setTimeout(() => setSeekIndicator(null), 600);
      lastTapRef.current = { time: 0, side: "" };
    } else if (side === "center") {
      // Single tap center — toggle pause/resume
      if (isPlaying) {
        pause();
      } else if (state === "paused") {
        resume();
      } else {
        play();
      }
    } else {
      lastTapRef.current = { time: now, side };
    }
  };

  return (
    <View style={styles.fullScreen}>
      <ExpoLiveStreamPlayerView
        ref={ref}
        style={StyleSheet.absoluteFill as any}
        url={url}
        onPlayerStateChanged={handlePlayerStateChanged}
        onPlayerError={handlePlayerError}
      />

      {/* Gesture overlay — double-tap seek, center-tap pause, long-press 2x */}
      {!panelOpen && (
        <TouchableOpacity
          activeOpacity={1}
          style={StyleSheet.absoluteFill}
          onPress={handleDoubleTap}
          onPressIn={handlePressIn}
          onPressOut={handlePressOut}
        />
      )}

      {/* Seek indicator */}
      {seekIndicator && (
        <View
          style={[
            styles.seekIndicator,
            seekIndicator === "left" ? { left: 40 } : { right: 40 },
          ]}
        >
          <Text style={styles.seekIndicatorText}>
            {seekIndicator === "left" ? "⏪ 10s" : "10s ⏩"}
          </Text>
        </View>
      )}

      {/* 2x Speed indicator */}
      {isSpeedUp && (
        <View style={styles.speedBadge}>
          <Text style={styles.speedBadgeText}>▶▶ 2x</Text>
        </View>
      )}

      {/* Status Badge — always visible */}
      <View style={styles.statusBadge}>
        <View
          style={[
            styles.dot,
            isPlaying && styles.dotLive,
            isBuffering && styles.dotBuffering,
          ]}
        />
        <Text style={styles.statusText}>{state.toUpperCase()}</Text>
        {!isVod && isPlaying && <Text style={styles.statsText}>● CANLI</Text>}
      </View>

      {/* Dismiss overlay — tapping outside closes the panel */}
      {panelOpen && (
        <TouchableOpacity
          activeOpacity={1}
          style={StyleSheet.absoluteFill}
          onPress={togglePanel}
        />
      )}

      {/* ─── Collapsible Volume Panel ─── */}
      <Animated.View style={[styles.topPanel, { width: panelWidth }]}>
        {/* Icon button — always visible */}
        <TouchableOpacity onPress={togglePanel} style={styles.panelToggle}>
          <Text style={{ fontSize: 18 }}>
            {isMuted ? "🔇" : volume > 0.5 ? "🔊" : "🔉"}
          </Text>
        </TouchableOpacity>

        {/* Expanded content — only rendered when open */}
        {panelOpen && (
          <Animated.View
            style={{ flex: 1, opacity: sliderOpacity, overflow: "hidden" }}
          >
            {/* Volume slider */}
            <View style={styles.panelSliderRow}>
              <TouchableOpacity onPress={handleToggleMute}>
                <Text style={{ fontSize: 14 }}>{isMuted ? "🔇" : "🔊"}</Text>
              </TouchableOpacity>
              <SliderBar
                value={isMuted ? 0 : volume}
                onValueChange={(v) => handleVolumeChange(v)}
                onSlidingComplete={(v) => handleVolumeChange(v)}
                trackColor="#666"
                fillColor="#2ecc71"
                thumbColor="#fff"
              />
              <Text style={styles.panelVolText}>
                {Math.round(volume * 100)}%
              </Text>
            </View>
          </Animated.View>
        )}
      </Animated.View>

      {/* VOD Seek Bar */}
      {isVod && duration > 0 && (
        <View style={styles.seekContainer}>
          <Text style={styles.timeText}>{formatTime(position)}</Text>
          <SliderBar
            value={duration > 0 ? position / duration : 0}
            onValueChange={(pct) => {
              setIsSeeking(true);
              setPosition(Math.round(pct * duration));
            }}
            onSlidingComplete={(pct) => {
              handleSeek(pct);
              setIsSeeking(false);
            }}
            trackColor="#555"
            fillColor="#3498db"
            thumbColor="#fff"
          />
          <Text style={styles.timeText}>{formatTime(duration)}</Text>
        </View>
      )}

      {/* Controls */}
      <View style={styles.controls}>
        <ControlButton icon="✕" onPress={onBack} />
        {state === "paused" ? (
          <>
            <ControlButton icon="▶️" onPress={resume} style={styles.startBtn} />
            <ControlButton icon="⏹" onPress={stop} style={styles.stopBtn} />
          </>
        ) : isPlaying || isBuffering ? (
          <>
            <ControlButton icon="⏸" onPress={pause} />
            <ControlButton icon="⏹" onPress={stop} style={styles.stopBtn} />
          </>
        ) : (
          <ControlButton icon="▶️" onPress={play} style={styles.startBtn} />
        )}
      </View>
    </View>
  );
}

// ─── SLIDER COMPONENT (Draggable) ────────────────────────────

function SliderBar({
  value,
  onValueChange,
  onSlidingComplete,
  trackColor = "#555",
  fillColor = "#3498db",
  thumbColor = "#fff",
}: {
  value: number;
  onValueChange?: (v: number) => void;
  onSlidingComplete?: (v: number) => void;
  trackColor?: string;
  fillColor?: string;
  thumbColor?: string;
}) {
  const trackRef = React.useRef<View>(null);
  const [trackWidth, setTrackWidth] = useState(200);
  const trackXRef = React.useRef(0);
  const offsetRef = React.useRef(0); // offset between finger and thumb center
  const currentValue = React.useRef(value);
  currentValue.current = value;

  const measureTrack = React.useCallback(() => {
    trackRef.current?.measureInWindow((x) => {
      if (x != null) trackXRef.current = x;
    });
  }, []);

  const clampedValue = Math.max(0, Math.min(1, value));

  const panResponder = React.useMemo(
    () =>
      PanResponder.create({
        onStartShouldSetPanResponder: () => true,
        onMoveShouldSetPanResponder: () => true,
        onPanResponderGrant: (evt) => {
          measureTrack();
          const touchX = evt.nativeEvent.pageX;
          const thumbCenterX =
            trackXRef.current + currentValue.current * trackWidth;
          // If touch is near the thumb, track the offset so it doesn't jump
          if (Math.abs(touchX - thumbCenterX) < 30) {
            offsetRef.current = touchX - thumbCenterX;
          } else {
            // Tapped far from thumb — jump to tap position, no offset
            offsetRef.current = 0;
            const pct = Math.max(
              0,
              Math.min(1, (touchX - trackXRef.current) / trackWidth),
            );
            onValueChange?.(pct);
          }
        },
        onPanResponderMove: (evt) => {
          const adjustedX = evt.nativeEvent.pageX - offsetRef.current;
          const pct = Math.max(
            0,
            Math.min(1, (adjustedX - trackXRef.current) / trackWidth),
          );
          onValueChange?.(pct);
        },
        onPanResponderRelease: (evt) => {
          const adjustedX = evt.nativeEvent.pageX - offsetRef.current;
          const pct = Math.max(
            0,
            Math.min(1, (adjustedX - trackXRef.current) / trackWidth),
          );
          onSlidingComplete?.(pct);
          offsetRef.current = 0;
        },
      }),
    [trackWidth, onValueChange, onSlidingComplete, measureTrack],
  );

  return (
    <View
      style={{ flex: 1, justifyContent: "center", paddingVertical: 12 }}
      {...panResponder.panHandlers}
    >
      <View
        ref={trackRef}
        onLayout={(e) => {
          setTrackWidth(e.nativeEvent.layout.width);
          setTimeout(measureTrack, 50);
        }}
        style={{
          height: 6,
          backgroundColor: trackColor,
          borderRadius: 3,
          overflow: "visible",
        }}
      >
        {/* Fill */}
        <View
          style={{
            position: "absolute",
            left: 0,
            top: 0,
            bottom: 0,
            width: `${clampedValue * 100}%`,
            backgroundColor: fillColor,
            borderRadius: 3,
          }}
        />
        {/* Thumb */}
        <View
          style={{
            position: "absolute",
            left: clampedValue * trackWidth - 10,
            top: -7,
            width: 20,
            height: 20,
            borderRadius: 10,
            backgroundColor: thumbColor,
            shadowColor: "#000",
            shadowOffset: { width: 0, height: 2 },
            shadowOpacity: 0.4,
            shadowRadius: 3,
            elevation: 4,
          }}
        />
      </View>
    </View>
  );
}

// ─── SHARED COMPONENTS ───────────────────────────────────────

function ControlButton({
  icon,
  onPress,
  style,
  disabled,
}: {
  icon: string;
  onPress: () => void;
  style?: object;
  disabled?: boolean;
}) {
  return (
    <TouchableOpacity
      style={[styles.controlBtn, style, disabled && styles.disabledBtn]}
      onPress={onPress}
      disabled={disabled}
    >
      <Text style={[styles.controlText, disabled && { opacity: 0.4 }]}>
        {icon}
      </Text>
    </TouchableOpacity>
  );
}

// ─── PERMISSIONS ─────────────────────────────────────────────

async function requestPermissions() {
  if (Platform.OS === "android") {
    await PermissionsAndroid.requestMultiple([
      PermissionsAndroid.PERMISSIONS.CAMERA,
      PermissionsAndroid.PERMISSIONS.RECORD_AUDIO,
    ]);
  }
  // iOS permissions are handled via Info.plist
}

// ─── STYLES ──────────────────────────────────────────────────

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: "#1a1a2e",
    justifyContent: "center",
    alignItems: "center",
    padding: 20,
  },
  title: { fontSize: 32, fontWeight: "bold", color: "#fff", marginBottom: 8 },
  subtitle: { fontSize: 16, color: "#888", marginBottom: 40 },
  input: {
    width: "100%",
    backgroundColor: "#16213e",
    color: "#fff",
    padding: 14,
    borderRadius: 10,
    fontSize: 14,
    marginBottom: 20,
    borderWidth: 1,
    borderColor: "#333",
  },
  button: {
    width: "100%",
    padding: 16,
    borderRadius: 10,
    alignItems: "center",
    marginBottom: 12,
  },
  buttonText: { color: "#fff", fontSize: 18, fontWeight: "600" },
  fullScreen: { flex: 1, backgroundColor: "#000" },
  statusBadge: {
    position: "absolute",
    top: 60,
    alignSelf: "center",
    backgroundColor: "rgba(0,0,0,0.7)",
    paddingHorizontal: 16,
    paddingVertical: 8,
    borderRadius: 20,
    flexDirection: "row",
    alignItems: "center",
    gap: 8,
  },
  dot: {
    width: 8,
    height: 8,
    borderRadius: 4,
    backgroundColor: "#666",
  },
  dotLive: { backgroundColor: "#e74c3c" },
  dotBuffering: { backgroundColor: "#f39c12" },
  statusText: { color: "#fff", fontSize: 14, fontWeight: "600" },
  statsText: { color: "#aaa", fontSize: 12 },
  muteBadge: {
    position: "absolute",
    top: 110,
    alignSelf: "center",
    backgroundColor: "rgba(231,76,60,0.9)",
    paddingHorizontal: 16,
    paddingVertical: 8,
    borderRadius: 8,
  },
  muteText: { color: "#fff", fontSize: 14, fontWeight: "bold" },
  errorBanner: {
    position: "absolute",
    top: 150,
    alignSelf: "center",
    backgroundColor: "rgba(231,76,60,0.9)",
    paddingHorizontal: 16,
    paddingVertical: 8,
    borderRadius: 8,
  },
  errorText: { color: "#fff", fontSize: 13 },
  controls: {
    position: "absolute",
    bottom: 50,
    flexDirection: "row",
    justifyContent: "center",
    alignItems: "center",
    width: "100%",
    gap: 16,
  },
  controlBtn: {
    width: 56,
    height: 56,
    borderRadius: 28,
    backgroundColor: "#333", // Solid dark background instead of translucent
    justifyContent: "center",
    alignItems: "center",
  },
  controlText: { fontSize: 24, color: "#fff" },
  startBtn: { backgroundColor: "#f39c12" }, // Orange for start/play
  stopBtn: { backgroundColor: "#e74c3c" }, // Red for stop
  mutedBtn: { backgroundColor: "#e74c3c" },
  topPanel: {
    position: "absolute" as const,
    top: 105,
    left: 16,
    flexDirection: "row" as const,
    alignItems: "center" as const,
    backgroundColor: "rgba(0,0,0,0.75)",
    borderRadius: 22,
    paddingVertical: 4,
    paddingHorizontal: 4,
    overflow: "hidden" as const,
  },
  panelToggle: {
    width: 36,
    height: 36,
    justifyContent: "center" as const,
    alignItems: "center" as const,
  },
  panelStatusRow: {
    flexDirection: "row" as const,
    alignItems: "center" as const,
    gap: 6,
    paddingHorizontal: 4,
    paddingTop: 6,
    paddingBottom: 2,
  },
  panelStatusText: {
    color: "#fff",
    fontSize: 13,
    fontWeight: "700" as const,
  },
  panelLiveText: {
    color: "#e74c3c",
    fontSize: 12,
    fontWeight: "700" as const,
  },
  panelMuteText: {
    color: "#e74c3c",
    fontSize: 11,
    fontWeight: "600" as const,
    marginLeft: 4,
  },
  panelSliderRow: {
    flexDirection: "row" as const,
    alignItems: "center" as const,
    gap: 6,
    paddingHorizontal: 4,
    paddingBottom: 4,
  },
  panelVolText: {
    color: "#aaa",
    fontSize: 12,
    fontWeight: "600" as const,
    minWidth: 32,
    textAlign: "right" as const,
  },
  seekContainer: {
    position: "absolute" as const,
    bottom: 130,
    left: 16,
    right: 16,
    flexDirection: "row" as const,
    alignItems: "center" as const,
    gap: 8,
    backgroundColor: "rgba(0,0,0,0.6)",
    borderRadius: 12,
    paddingHorizontal: 12,
    paddingVertical: 8,
  },
  timeText: {
    color: "#fff",
    fontSize: 12,
    fontWeight: "600" as const,
    minWidth: 36,
    textAlign: "center" as const,
  },
  seekIndicator: {
    position: "absolute" as const,
    top: "45%" as any,
    backgroundColor: "rgba(0,0,0,0.7)",
    borderRadius: 30,
    paddingHorizontal: 16,
    paddingVertical: 10,
  },
  seekIndicatorText: {
    color: "#fff",
    fontSize: 16,
    fontWeight: "700" as const,
  },
  speedBadge: {
    position: "absolute" as const,
    top: "45%" as any,
    alignSelf: "center" as const,
    backgroundColor: "rgba(0,0,0,0.8)",
    borderRadius: 20,
    paddingHorizontal: 16,
    paddingVertical: 8,
  },
  speedBadgeText: {
    color: "#f39c12",
    fontSize: 18,
    fontWeight: "800" as const,
  },
  recordingBtn: {
    backgroundColor: "#e74c3c",
  },
  floatingRecBtn: {
    position: "absolute" as const,
    right: 16,
    bottom: 120,
    backgroundColor: "rgba(0,0,0,0.6)",
    borderRadius: 28,
    paddingVertical: 10,
    paddingHorizontal: 14,
    alignItems: "center" as const,
    borderWidth: 2,
    borderColor: "rgba(255,255,255,0.3)",
  },
  floatingRecBtnActive: {
    backgroundColor: "rgba(231,76,60,0.9)",
    borderColor: "#e74c3c",
  },
  floatingRecIcon: {
    fontSize: 24,
  },
  floatingRecLabel: {
    color: "#fff",
    fontSize: 10,
    fontWeight: "700" as const,
    marginTop: 2,
  },
  recordingBadge: {
    position: "absolute" as const,
    top: 90,
    alignSelf: "center" as const,
    flexDirection: "row" as const,
    alignItems: "center" as const,
    backgroundColor: "rgba(231,76,60,0.85)",
    paddingHorizontal: 12,
    paddingVertical: 6,
    borderRadius: 16,
    gap: 6,
  },
  recDot: {
    width: 10,
    height: 10,
    borderRadius: 5,
    backgroundColor: "#fff",
  },
  recText: {
    color: "#fff",
    fontSize: 14,
    fontWeight: "800" as const,
    letterSpacing: 2,
  },
  disabledBtn: {
    opacity: 0.3,
  },
  filterBar: {
    position: "absolute" as const,
    bottom: 60,
    left: 0,
    right: 0,
    paddingHorizontal: 8,
  },
  filterChip: {
    backgroundColor: "rgba(0,0,0,0.5)",
    paddingHorizontal: 12,
    paddingVertical: 6,
    borderRadius: 16,
    marginHorizontal: 3,
  },
  filterChipActive: {
    backgroundColor: "#3498db",
  },
  filterChipText: {
    color: "#ccc",
    fontSize: 11,
    fontWeight: "600" as const,
  },
  filterChipTextActive: {
    color: "#fff",
  },
  sliderPanel: {
    position: "absolute" as const,
    left: 16,
    bottom: 110,
    width: 160,
    backgroundColor: "rgba(0,0,0,0.5)",
    borderRadius: 14,
    padding: 10,
  },
  sliderLabel: {
    color: "#fff",
    fontSize: 12,
    fontWeight: "600" as const,
    marginBottom: 4,
  },
  toastContainer: {
    position: "absolute" as const,
    bottom: 100,
    alignSelf: "center" as const,
    backgroundColor: "rgba(0,0,0,0.8)",
    paddingHorizontal: 20,
    paddingVertical: 10,
    borderRadius: 24,
  },
  toastText: {
    color: "#fff",
    fontSize: 14,
    fontWeight: "600" as const,
  },
});
