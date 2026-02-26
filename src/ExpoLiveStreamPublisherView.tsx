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
  startRecording: () => Promise<string>;
  stopRecording: () => void;
  isRecording: () => Promise<boolean>;
  setZoom: (level: number) => void;
  getZoom: () => Promise<number>;
  getMaxZoom: () => Promise<number>;
  setExposure: (value: number) => void;
  getExposure: () => Promise<number>;
  setFilter: (name: string) => void;
  getFilter: () => Promise<string>;
  getAvailableFilters: () => Promise<string[]>;
  // Phase 7: Multi-Destination
  startMulti: (urls: string[]) => void;
  stopMulti: () => void;
  getMultiDestinations: () => Promise<string[]>;
  // Phase 8: Overlay
  setTextOverlay: (text: string, x: number, y: number, size: number) => void;
  clearOverlay: () => void;
  // Phase 9: Audio
  setBackgroundMusic: (path: string, volume: number) => void;
  stopBackgroundMusic: () => void;
  // Phase 10: Advanced
  setAdaptiveBitrate: (enabled: boolean) => void;
  getStreamStats: () => Promise<Record<string, any>>;
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

const NativeView = requireNativeViewManager("ExpoLiveStream", "PublisherView");
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
      startRecording: () => {
        return NativeModule.publisherStartRecording();
      },
      stopRecording: () => {
        NativeModule.publisherStopRecording();
      },
      isRecording: () => {
        return NativeModule.publisherIsRecording();
      },
      setZoom: (level: number) => {
        NativeModule.publisherSetZoom(level);
      },
      getZoom: () => {
        return NativeModule.publisherGetZoom();
      },
      getMaxZoom: () => {
        return NativeModule.publisherGetMaxZoom();
      },
      setExposure: (value: number) => {
        NativeModule.publisherSetExposure(value);
      },
      getExposure: () => {
        return NativeModule.publisherGetExposure();
      },
      setFilter: (name: string) => {
        NativeModule.publisherSetFilter(name);
      },
      getFilter: () => {
        return NativeModule.publisherGetFilter();
      },
      getAvailableFilters: () => {
        return NativeModule.publisherGetAvailableFilters();
      },
      // Phase 7
      startMulti: (urls: string[]) => {
        NativeModule.publisherStartMulti(urls);
      },
      stopMulti: () => {
        NativeModule.publisherStopMulti();
      },
      getMultiDestinations: () => NativeModule.publisherGetMultiDestinations(),
      // Phase 8
      setTextOverlay: (text: string, x: number, y: number, size: number) => {
        NativeModule.publisherSetTextOverlay(text, x, y, size);
      },
      clearOverlay: () => {
        NativeModule.publisherClearOverlay();
      },
      // Phase 9
      setBackgroundMusic: (path: string, volume: number) => {
        NativeModule.publisherSetBackgroundMusic(path, volume);
      },
      stopBackgroundMusic: () => {
        NativeModule.publisherStopBackgroundMusic();
      },
      // Phase 10
      setAdaptiveBitrate: (enabled: boolean) => {
        NativeModule.publisherSetAdaptiveBitrate(enabled);
      },
      getStreamStats: () => NativeModule.publisherGetStreamStats(),
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
