import {
  requireNativeViewManager,
  requireNativeModule,
} from "expo-modules-core";
import React, {
  forwardRef,
  useImperativeHandle,
  useRef,
  useEffect,
} from "react";
import { ViewProps } from "react-native";

// ---- Types ----

export type LiveStreamPlayerRef = {
  play: () => void;
  stop: () => void;
  pause: () => void;
  resume: () => void;
  setVolume: (volume: number) => void;
  setMuted: (muted: boolean) => void;
  seekTo: (positionMs: number) => void;
  getPosition: () => Promise<number>;
  getDuration: () => Promise<number>;
  setRate: (rate: number) => void;
};

export type PlayerState =
  | "idle"
  | "connecting"
  | "buffering"
  | "playing"
  | "paused"
  | "stopped"
  | "failed";

export type LiveStreamPlayerProps = ViewProps & {
  /**
   * Stream URL — supports multiple protocols:
   * - `rtmp://` / `rtmps://` — RTMP live stream
   * - `rtsp://` / `rtsps://` — IP cameras, security systems
   * - `https://...m3u8` — HLS (YouTube, Twitch)
   * - `http://...mp4` — HTTP progressive video
   * - `srt://` — SRT low-latency stream
   */
  url?: string;
  /** Stream name to subscribe to (optional, can be part of URL) */
  streamName?: string;
  /** Automatically start playback when component mounts (default: false) */
  autoPlay?: boolean;
  /** Called when player state changes */
  onPlayerStateChanged?: (event: {
    nativeEvent: { state: PlayerState };
  }) => void;
  /** Called when player encounters an error */
  onPlayerError?: (event: { nativeEvent: { msg: string } }) => void;
};

// ---- Native bindings ----

const NativeView = requireNativeViewManager("ExpoLiveStream", "PlayerView");
const NativeModule = requireNativeModule("ExpoLiveStream");

// ---- No-op handler (Fabric requires all events to be registered) ----
const noop = () => {};

// ---- Component ----

const ExpoLiveStreamPlayerView = forwardRef<
  LiveStreamPlayerRef,
  LiveStreamPlayerProps
>(
  (
    { autoPlay = false, onPlayerStateChanged, onPlayerError, ...props },
    ref,
  ) => {
    const nativeRef = useRef<any>(null);
    const hasAutoPlayed = useRef(false);

    useImperativeHandle(ref, () => ({
      play: () => {
        NativeModule.playerPlay();
      },
      stop: () => {
        NativeModule.playerStop();
      },
      pause: () => {
        NativeModule.playerPause();
      },
      resume: () => {
        NativeModule.playerResume();
      },
      setVolume: (volume: number) => {
        NativeModule.playerSetVolume(volume);
      },
      setMuted: (muted: boolean) => {
        NativeModule.playerSetMuted(muted);
      },
      seekTo: (positionMs: number) => {
        NativeModule.playerSeekTo(positionMs);
      },
      getPosition: () => {
        return NativeModule.playerGetPosition();
      },
      getDuration: () => {
        return NativeModule.playerGetDuration();
      },
      setRate: (rate: number) => {
        NativeModule.playerSetRate(rate);
      },
    }));

    // Auto-play support
    useEffect(() => {
      if (autoPlay && !hasAutoPlayed.current) {
        hasAutoPlayed.current = true;
        const timer = setTimeout(() => {
          NativeModule.playerPlay();
        }, 500);
        return () => clearTimeout(timer);
      }
    }, [autoPlay]);

    return (
      <NativeView
        {...props}
        onPlayerStateChanged={onPlayerStateChanged ?? noop}
        onPlayerError={onPlayerError ?? noop}
        ref={nativeRef}
      />
    );
  },
);

ExpoLiveStreamPlayerView.displayName = "ExpoLiveStreamPlayerView";

export default ExpoLiveStreamPlayerView;
