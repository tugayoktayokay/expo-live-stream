import React, {
  forwardRef,
  useImperativeHandle,
  useRef,
  useEffect,
} from "react";
import { View, ViewProps } from "react-native";
import { resolveNativeModule, resolveNativeView } from "./resolveNativeView";

export type LiveStreamPlayerRef = {
  play: () => void;
  stop: () => void;
  pause: () => void;
  resume: () => void;
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
  /** RTMP URL (e.g., rtmp://server/app/stream-key) */
  url?: string;
  /** Stream name to subscribe to (optional, can be part of URL) */
  streamName?: string;
  /** Video scaling mode on Android ('contain' fits full frame, 'cover' fills and crops) */
  resizeMode?: "contain" | "cover";
  /** Automatically start playback when component mounts (default: false) */
  autoPlay?: boolean;
  /** Called when player state changes */
  onPlayerStateChanged?: (event: {
    nativeEvent: { state: PlayerState };
  }) => void;
  /** Called when player encounters an error */
  onPlayerError?: (event: { nativeEvent: { msg: string } }) => void;
};

const PLAYER_VIEW_CONFIG = {
  uiViewClassName: "ExpoLiveStreamPlayer",
  bubblingEventTypes: {},
  directEventTypes: {
    topPlayerStateChanged: { registrationName: "onPlayerStateChanged" },
    topPlayerError: { registrationName: "onPlayerError" },
  },
  validAttributes: {
    url: true,
    streamName: true,
    resizeMode: true,
  },
};

const NativeView = resolveNativeView(PLAYER_VIEW_CONFIG);
const NativeModule = resolveNativeModule<{
  playerPlay: () => void;
  playerStop: () => void;
  playerPause: () => void;
  playerResume: () => void;
}>("ExpoLiveStreamPlayer");

const noop = () => {};

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
        NativeModule?.playerPlay?.();
      },
      stop: () => {
        NativeModule?.playerStop?.();
      },
      pause: () => {
        NativeModule?.playerPause?.();
      },
      resume: () => {
        NativeModule?.playerResume?.();
      },
    }));

    useEffect(() => {
      if (autoPlay && !hasAutoPlayed.current) {
        hasAutoPlayed.current = true;
        const timer = setTimeout(() => {
          NativeModule?.playerPlay?.();
        }, 500);
        return () => clearTimeout(timer);
      }
    }, [autoPlay]);

    if (!NativeView) {
      return <View {...props} ref={nativeRef} />;
    }

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
