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
} from "react-native";
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
  const {
    ref,
    state,
    isStreaming,
    error,
    start,
    stop,
    switchCamera,
    toggleFlash,
    toggleMute,
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
      </View>

      {/* Error Banner */}
      {error && (
        <View style={styles.errorBanner}>
          <Text style={styles.errorText}>⚠️ {error}</Text>
        </View>
      )}

      {/* Controls */}
      <View style={styles.controls}>
        <ControlButton icon="✕" onPress={onBack} />
        <ControlButton icon="🔄" onPress={switchCamera} />
        <ControlButton
          icon={isStreaming ? "⏹" : "⏺"}
          onPress={() => (isStreaming ? stop() : start())}
          style={isStreaming ? styles.stopBtn : styles.startBtn}
        />
        <ControlButton
          icon={isMuted ? "🔇" : "🔊"}
          onPress={handleToggleMute}
        />
        <ControlButton icon="⚡" onPress={toggleFlash} />
      </View>
    </View>
  );
}

// ─── PLAYER SCREEN (using useLiveStreamPlayer hook) ──────────

function PlayerScreen({ url, onBack }: { url: string; onBack: () => void }) {
  const { ref, state, isPlaying, isBuffering, play, stop, pause, resume } =
    useLiveStreamPlayer({ autoPlay: true });

  return (
    <View style={styles.fullScreen}>
      <ExpoLiveStreamPlayerView
        ref={ref}
        style={StyleSheet.absoluteFill}
        url={url}
        autoPlay
        onPlayerStateChanged={(e) =>
          console.log("[Player]", e.nativeEvent.state)
        }
        onPlayerError={(e) => Alert.alert("Player Error", e.nativeEvent.msg)}
      />

      {/* Status Badge */}
      <View style={styles.statusBadge}>
        <View
          style={[
            styles.dot,
            isPlaying && styles.dotLive,
            isBuffering && styles.dotBuffering,
          ]}
        />
        <Text style={styles.statusText}>{state.toUpperCase()}</Text>
      </View>

      {/* Controls */}
      <View style={styles.controls}>
        <ControlButton icon="✕" onPress={onBack} />
        <ControlButton
          icon={isPlaying ? "⏹" : "▶️"}
          onPress={() => (isPlaying ? stop() : play())}
          style={isPlaying ? styles.stopBtn : styles.startBtn}
        />
        <ControlButton icon="⏸" onPress={pause} />
        <ControlButton icon="▶️" onPress={resume} />
      </View>
    </View>
  );
}

// ─── SHARED COMPONENTS ───────────────────────────────────────

function ControlButton({
  icon,
  onPress,
  style,
}: {
  icon: string;
  onPress: () => void;
  style?: object;
}) {
  return (
    <TouchableOpacity style={[styles.controlBtn, style]} onPress={onPress}>
      <Text style={styles.controlText}>{icon}</Text>
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
  errorBanner: {
    position: "absolute",
    top: 110,
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
    backgroundColor: "rgba(255,255,255,0.2)",
    justifyContent: "center",
    alignItems: "center",
  },
  controlText: { fontSize: 24 },
  startBtn: { backgroundColor: "#e74c3c" },
  stopBtn: { backgroundColor: "#555" },
});
