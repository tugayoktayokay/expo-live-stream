# expo-live-stream

[![npm version](https://img.shields.io/npm/v/expo-live-stream.svg?style=flat-square)](https://www.npmjs.com/package/expo-live-stream)
[![license](https://img.shields.io/npm/l/expo-live-stream.svg?style=flat-square)](https://github.com/tugayoktayokay/expo-live-stream/blob/main/LICENSE)
[![platform - ios](https://img.shields.io/badge/iOS-15.1+-blue?style=flat-square&logo=apple)](https://developer.apple.com)
[![platform - android](https://img.shields.io/badge/Android-API_24+-green?style=flat-square&logo=android)](https://developer.android.com)
[![expo](https://img.shields.io/badge/Expo-SDK_51+-000020?style=flat-square&logo=expo)](https://expo.dev)

Multi-protocol live stream **publisher** & **player** for React Native — built as a native Expo Module.

> 📹 Stream live from camera • 📺 Watch RTMP/RTSP/HLS/HTTP streams • ⚡ Zero bridge overhead

---

## Features

- 🎥 **RTMP Publisher** — Stream live video from device camera with full controls
- 📺 **Multi-Protocol Player** — Watch live and on-demand streams:
  - `rtmp://` / `rtmps://` — RTMP live streams
  - `rtsp://` / `rtsps://` — IP cameras, security systems
  - `https://...m3u8` — HLS (YouTube, Twitch, Apple)
  - `http://...mp4` — HTTP progressive video
  - `srt://` — SRT low-latency streams
- 🔐 **RTMPS** — Secure streaming over SSL/TLS (`rtmps://`)
- 🔄 **Auto-Reconnect** — Smart reconnect at both JS (hooks) and native level
- 📊 **Live Statistics** — Bitrate, duration, bytes sent in real-time
- 🖼️ **Watermark Overlay** — Custom image or text watermark with 5 positions
- 🎚️ **Quality Presets** — `VideoQuality.HD_720P`, `FHD_1080P`, etc.
- 🪝 **React Hooks** — `useLiveStream()` and `useLiveStreamPlayer()` for reactive state
- 📱 **Rotation Support** — Seamless video playback during device orientation changes
- 🔍 **Camera Controls** — Zoom, exposure compensation with cross-platform sliders
- 🎨 **Real-time Filters** — 13 GPU-accelerated filters (sepia, grayscale, beauty, cartoon, etc.)
- 📡 **Multi-Destination** — Stream to multiple RTMP servers simultaneously (optional)
- 📝 **Text Overlay** — Live text overlay on Android stream
- 🎵 **Audio Mixing** — Background music API (extensible)
- 📈 **Stream Stats** — Real-time stream analytics
- 🍎 **iOS** — [HaishinKit 2.0](https://github.com/shogo4405/HaishinKit.swift) (publisher) + [VLCKit](https://code.videolan.org/videolan/VLCKit) (player)
- 🤖 **Android** — [RootEncoder](https://github.com/pedroSG94/RootEncoder) (publisher) + [VLC](https://code.videolan.org/videolan/vlc-android) (player)
- ⚡ **Expo Modules API** — Native performance, no bridge overhead

---

## Installation

```bash
yarn add expo-live-stream
# or
npm install expo-live-stream
```

### iOS

```bash
cd ios && pod install
```

### Android

No additional setup needed — native dependencies are bundled.

---

## Quick Start

### 1. Publisher (Streaming)

```tsx
import {
  ExpoLiveStreamPublisherView,
  useLiveStream,
  VideoQuality,
} from "expo-live-stream";

function StreamScreen() {
  const { ref, isStreaming, start, stop, switchCamera } = useLiveStream();

  return (
    <View style={{ flex: 1 }}>
      <ExpoLiveStreamPublisherView
        ref={ref}
        style={{ flex: 1 }}
        url="rtmp://your-server/live/stream-key"
        quality={VideoQuality.HD_720P}
      />
      <Button onPress={() => (isStreaming ? stop() : start())} />
    </View>
  );
}
```

### 2. Player (Watching)

```tsx
import { ExpoLiveStreamPlayerView } from "expo-live-stream";

function WatchScreen() {
  return (
    <ExpoLiveStreamPlayerView
      style={{ flex: 1 }}
      url="rtmp://your-server/live/stream-key"
      autoPlay
    />
  );
}
```

#### Multi-Protocol Examples

```tsx
// 📹 IP Camera (RTSP)
<ExpoLiveStreamPlayerView url="rtsp://192.168.1.100:554/stream1" autoPlay />

// 📺 HLS Stream (YouTube/Twitch)
<ExpoLiveStreamPlayerView url="https://cdn.example.com/live.m3u8" autoPlay />

// 🎬 HTTP Video (VOD)
<ExpoLiveStreamPlayerView url="https://example.com/video.mp4" autoPlay />

// 🔐 Secure RTMP
<ExpoLiveStreamPlayerView url="rtmps://secure.server.com/live/key" autoPlay />
```

---

## API Reference

### `<ExpoLiveStreamPublisherView />`

| Prop                   | Type           | Default     | Description                               |
| ---------------------- | -------------- | ----------- | ----------------------------------------- |
| `url`                  | `string`       | —           | RTMP URL                                  |
| `streamKey`            | `string`       | —           | Stream key (optional, can be part of URL) |
| `quality`              | `VideoQuality` | `HD_720P`   | Quality preset                            |
| `videoWidth`           | `number`       | from preset | Override width                            |
| `videoHeight`          | `number`       | from preset | Override height                           |
| `videoBitrate`         | `number`       | from preset | Override bitrate (bps)                    |
| `videoFps`             | `number`       | from preset | Override FPS                              |
| `audioBitrate`         | `number`       | from preset | Override audio bitrate                    |
| `frontCamera`          | `boolean`      | `true`      | Use front camera                          |
| `onStreamStateChanged` | `(e) => void`  | —           | State change callback                     |
| `onConnectionFailed`   | `(e) => void`  | —           | Connection error callback                 |
| `onBitrateUpdate`      | `(e) => void`  | —           | Bitrate update callback                   |

**Ref methods:** `start()`, `stop()`, `switchCamera()`, `toggleFlash()`, `toggleMute()`, `startRecording(path)`, `stopRecording()`, `setZoom(level)`, `setExposure(value)`, `setFilter(name)`, `startMulti(urls)`, `stopMulti()`, `setTextOverlay(text, x, y, size)`, `clearOverlay()`, `setAdaptiveBitrate(enabled)`, `getStreamStats()`

### `<ExpoLiveStreamPlayerView />`

| Prop                   | Type          | Default | Description                             |
| ---------------------- | ------------- | ------- | --------------------------------------- |
| `url`                  | `string`      | —       | Stream URL (RTMP, RTSP, HLS, HTTP, SRT) |
| `streamName`           | `string`      | —       | Stream name (optional)                  |
| `autoPlay`             | `boolean`     | `false` | Auto-start on mount                     |
| `onPlayerStateChanged` | `(e) => void` | —       | State change callback                   |
| `onPlayerError`        | `(e) => void` | —       | Error callback                          |

**Ref methods:** `play()`, `stop()`, `pause()`, `resume()`, `setVolume(vol)`, `setMuted(bool)`, `seekTo(ms)`, `getPosition()`, `getDuration()`, `setRate(rate)`

### Supported Protocols

| Protocol | Scheme            | Use Case               | Latency |
| -------- | ----------------- | ---------------------- | ------- |
| RTMP     | `rtmp://`         | Live streaming         | ~1-2s   |
| RTMPS    | `rtmps://`        | Secure live streaming  | ~1-2s   |
| RTSP     | `rtsp://`         | IP cameras, security   | ~0.5-1s |
| HLS      | `https://...m3u8` | YouTube, Twitch, Apple | ~5-15s  |
| HTTP     | `http://...mp4`   | VOD playback           | Instant |
| SRT      | `srt://`          | Low-latency broadcast  | ~0.5s   |

---

### Quality Presets

```tsx
import { VideoQuality } from "expo-live-stream";
```

| Preset      | Resolution | Video Bitrate | FPS |
| ----------- | ---------- | ------------- | --- |
| `LOW_240P`  | 426×240    | 400 kbps      | 24  |
| `LOW_360P`  | 640×360    | 800 kbps      | 24  |
| `SD_480P`   | 854×480    | 1.2 Mbps      | 30  |
| `HD_720P`   | 1280×720   | 2 Mbps        | 30  |
| `FHD_1080P` | 1920×1080  | 4 Mbps        | 30  |

Custom values override presets:

```tsx
<ExpoLiveStreamPublisherView
  quality={VideoQuality.HD_720P}
  videoBitrate={3000000}
/>
```

---

### Hooks

#### `useLiveStream(options?)`

```tsx
const stream = useLiveStream({
  autoStopOnUnmount: true,
  reconnect: { enabled: true, maxRetries: 5 },
});

// State
stream.state              // 'idle' | 'connecting' | 'streaming' | 'stopped' | 'failed'
stream.isStreaming         // boolean
stream.isConnecting        // boolean
stream.isReconnecting      // boolean (auto-reconnect active?)
stream.reconnectAttempt    // current attempt number
stream.error               // last error or null

// Statistics (live updates)
stream.statistics.bitrate           // 2000000 (bps)
stream.statistics.bitrateFormatted  // "2.0 Mbps"
stream.statistics.duration          // 125 (seconds)
stream.statistics.durationFormatted // "00:02:05"
stream.statistics.totalBytesSent    // bytes

// Actions
stream.start()        // start streaming
stream.stop()         // stop streaming
stream.switchCamera() // toggle front/back
stream.toggleFlash()  // toggle flash
stream.toggleMute()   // toggle mic

// Wire event handlers to view
<ExpoLiveStreamPublisherView
  ref={stream.ref}
  url="rtmps://server/live/key"
  quality={VideoQuality.HD_720P}
  onStreamStateChanged={stream.handleStreamStateChanged}
  onConnectionFailed={stream.handleConnectionFailed}
  onConnectionSuccess={stream.handleConnectionSuccess}
  onDisconnect={stream.handleDisconnect}
  onBitrateUpdate={stream.handleBitrateUpdate}
/>
```

---

### Camera Controls

```tsx
const stream = useLiveStream();

// Zoom (0.0 to 1.0)
stream.setZoom(0.5); // 50% zoom
stream.getZoom(); // → 0.5
stream.getMaxZoom(); // → 10 (platform-dependent)

// Exposure (-1.0 to 1.0)
stream.setExposure(-0.3); // slightly darker
stream.getExposure(); // → -0.3
```

> Zoom and exposure auto-reset when switching camera.

---

### Real-time Filters

13 GPU-accelerated filters on both platforms:

```tsx
stream.setFilter("sepia"); // apply sepia filter
stream.getFilter(); // → 'sepia'
stream.getAvailableFilters(); // → ['none', 'sepia', ...]
stream.setFilter("none"); // remove filter
```

Available: `none`, `sepia`, `grayscale`, `negative`, `brightness`, `contrast`, `saturation`, `edge_detection`, `beauty`, `cartoon`, `glitch`, `snow`, `blur`

---

### Multi-Destination Streaming (Optional)

```tsx
// Register secondary destinations
stream.startMulti([
  "rtmp://youtube.com/live/key1",
  "rtmp://twitch.tv/live/key2",
]);

stream.start(); // primary + secondaries connect
stream.stop(); // all disconnect
stream.stopMulti(); // remove secondaries
```

> If `startMulti()` is never called, behavior is identical to single-destination.

---

### Text Overlay (Android)

```tsx
stream.setTextOverlay("LIVE", 0.1, 0.1, 24); // text, x, y, fontSize
stream.clearOverlay();
```

---

### Stream Analytics

```tsx
const stats = await stream.getStreamStats();
// → { isStreaming, isRecording, isFrontCamera, currentFilter, secondaryDestinations }
```

#### `useLiveStreamPlayer(options?)`

```tsx
const player = useLiveStreamPlayer({
  autoPlay: true,
  reconnect: { enabled: true, maxRetries: 3 },
});

player.state       // 'idle' | 'playing' | 'buffering' | 'paused' | 'stopped' | 'failed'
player.isPlaying   // boolean
player.isBuffering // boolean

<ExpoLiveStreamPlayerView
  ref={player.ref}
  url="rtmps://server/live/key"
  onPlayerStateChanged={player.handlePlayerStateChanged}
  onPlayerError={player.handlePlayerError}
/>
```

---

### RTMPS (Secure Streaming)

Both publisher and player natively support RTMPS — just use `rtmps://` instead of `rtmp://`:

```tsx
// Unencrypted
url = "rtmp://server/live/key";

// Encrypted (SSL/TLS)
url = "rtmps://server/live/key";
```

---

### Auto-Reconnect

Both hooks support automatic reconnection with exponential backoff:

```tsx
const stream = useLiveStream({
  reconnect: {
    enabled: true, // enable auto-reconnect (default: true)
    maxRetries: 5, // max attempts (default: 5)
    initialDelay: 1000, // first retry delay in ms (default: 1000)
    maxDelay: 30000, // max delay cap in ms (default: 30000)
    backoffMultiplier: 2, // exponential multiplier (default: 2)
    onReconnectAttempt: (attempt, max) =>
      console.log(`Retry ${attempt}/${max}`),
    onReconnectFailed: () => Alert.alert("Connection lost"),
    onReconnectSuccess: () => console.log("Reconnected!"),
  },
});
```

Retry delays: 1s → 2s → 4s → 8s → 16s (capped at `maxDelay`).

---

### Watermark Overlay

```tsx
import { LiveStreamWatermark } from 'expo-live-stream';

// Image watermark
<View style={{ flex: 1 }}>
  <ExpoLiveStreamPublisherView ref={ref} style={{ flex: 1 }} url="..." />
  <LiveStreamWatermark
    image={require('./logo.png')}
    position="top-right"
    opacity={0.5}
    size={48}
  />
</View>

// Text watermark
<LiveStreamWatermark
  text="LIVE"
  position="top-left"
  textStyle={{ color: '#e74c3c', fontWeight: 'bold' }}
/>
```

| Prop       | Type                | Default     | Description                                                      |
| ---------- | ------------------- | ----------- | ---------------------------------------------------------------- |
| `position` | `WatermarkPosition` | `top-right` | `top-left`, `top-right`, `bottom-left`, `bottom-right`, `center` |
| `image`    | `ImageSource`       | —           | Logo image                                                       |
| `text`     | `string`            | —           | Text badge (if no image)                                         |
| `opacity`  | `number`            | `0.7`       | Transparency                                                     |
| `size`     | `number`            | `60`        | Image size in px                                                 |
| `margin`   | `number`            | `16`        | Edge margin in px                                                |

---

## Requirements

- **Expo** SDK 51+
- **iOS** 15.1+
- **Android** API 24+
- **React Native** 0.73+

## Native Dependencies

| Platform | Library                                                         | Purpose       |
| -------- | --------------------------------------------------------------- | ------------- |
| iOS      | [HaishinKit 2.0](https://github.com/shogo4405/HaishinKit.swift) | RTMP publish  |
| iOS      | [MobileVLCKit](https://code.videolan.org/videolan/VLCKit)       | RTMP playback |
| Android  | [RootEncoder 2.6.7](https://github.com/pedroSG94/RootEncoder)   | RTMP publish  |
| Android  | [libVLC 3.6.5](https://code.videolan.org/videolan/vlc-android)  | RTMP playback |

## License

MIT © [tugayoktayokay](https://github.com/tugayoktayokay)
