import {
  requireNativeViewManager,
  requireNativeModule,
} from "expo-modules-core";
import React, { forwardRef, useImperativeHandle, useRef, useMemo } from "react";
import { ViewProps } from "react-native";
import { VideoQuality, QualityPresets, QualityConfig } from "./presets";

// ---- Types ----

export type LiveStreamPublisherRef = {
  start: (url?: string) => void;
  stop: () => void;
  switchCamera: () => void;
  toggleFlash: () => void;
  toggleMute: () => void;
};

export type StreamState =
  | "idle"
  | "connecting"
  | "streaming"
  | "stopped"
  | "failed"
  | "disconnected"
  | "auth_error";

export type LiveStreamPublisherProps = ViewProps & {
  /** RTMP URL (e.g., rtmp://server/live/stream-key) */
  url?: string;
  /** Stream key (appended to URL if provided separately) */
  streamKey?: string;
  /**
   * Video quality preset. If set, overrides videoWidth/videoHeight/videoBitrate/videoFps.
   * Individual props still override the preset values.
   */
  quality?: VideoQuality;
  /** Video width in pixels (default: 720, or from quality preset) */
  videoWidth?: number;
  /** Video height in pixels (default: 1280, or from quality preset) */
  videoHeight?: number;
  /** Video bitrate in bps (default: 2000000, or from quality preset) */
  videoBitrate?: number;
  /** Video FPS (default: 30, or from quality preset) */
  videoFps?: number;
  /** Audio bitrate in bps (default: 128000, or from quality preset) */
  audioBitrate?: number;
  /** Audio sample rate in Hz (default: 44100, or from quality preset) */
  audioSampleRate?: number;
  /** Use front camera (default: true) */
  frontCamera?: boolean;
  /** Called when RTMP connection succeeds */
  onConnectionSuccess?: (event: any) => void;
  /** Called when RTMP connection fails */
  onConnectionFailed?: (event: { nativeEvent: { msg: string } }) => void;
  /** Called when disconnected */
  onDisconnect?: (event: any) => void;
  /** Called when stream state changes */
  onStreamStateChanged?: (event: {
    nativeEvent: { state: StreamState };
  }) => void;
  /** Called periodically with current bitrate */
  onBitrateUpdate?: (event: { nativeEvent: { bitrate: number } }) => void;
};

// ---- Native bindings ----

const NativeView = requireNativeViewManager("ExpoLiveStream");
const NativeModule = requireNativeModule("ExpoLiveStream");

// ---- Default config ----

const DEFAULT_CONFIG: QualityConfig = QualityPresets[VideoQuality.HD_720P];

// ---- No-op handler (Fabric requires all events to be registered) ----
const noop = () => {};

// ---- Component ----

const ExpoLiveStreamPublisherView = forwardRef<
  LiveStreamPublisherRef,
  LiveStreamPublisherProps
>(
  (
    {
      quality,
      videoWidth,
      videoHeight,
      videoBitrate,
      videoFps,
      audioBitrate,
      audioSampleRate,
      onConnectionSuccess,
      onConnectionFailed,
      onDisconnect,
      onStreamStateChanged,
      onBitrateUpdate,
      ...props
    },
    ref,
  ) => {
    const nativeRef = useRef<any>(null);

    // Resolve quality: preset → individual overrides → defaults
    const resolvedConfig = useMemo(() => {
      const preset = quality ? QualityPresets[quality] : DEFAULT_CONFIG;
      return {
        videoWidth: videoWidth ?? preset.videoWidth,
        videoHeight: videoHeight ?? preset.videoHeight,
        videoBitrate: videoBitrate ?? preset.videoBitrate,
        videoFps: videoFps ?? preset.videoFps,
        audioBitrate: audioBitrate ?? preset.audioBitrate,
        audioSampleRate: audioSampleRate ?? preset.audioSampleRate,
      };
    }, [
      quality,
      videoWidth,
      videoHeight,
      videoBitrate,
      videoFps,
      audioBitrate,
      audioSampleRate,
    ]);

    useImperativeHandle(ref, () => ({
      start: (url?: string) => {
        NativeModule.start(url ?? null);
      },
      stop: () => {
        NativeModule.stop();
      },
      switchCamera: () => {
        NativeModule.switchCamera();
      },
      toggleFlash: () => {
        NativeModule.toggleFlash();
      },
      toggleMute: () => {
        NativeModule.toggleMute();
      },
    }));

    return (
      <NativeView
        {...props}
        {...resolvedConfig}
        onConnectionSuccess={onConnectionSuccess ?? noop}
        onConnectionFailed={onConnectionFailed ?? noop}
        onDisconnect={onDisconnect ?? noop}
        onStreamStateChanged={onStreamStateChanged ?? noop}
        onBitrateUpdate={onBitrateUpdate ?? noop}
        ref={nativeRef}
      />
    );
  },
);

ExpoLiveStreamPublisherView.displayName = "ExpoLiveStreamPublisherView";

export default ExpoLiveStreamPublisherView;
