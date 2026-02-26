// Components
export { default as ExpoLiveStreamPublisherView } from './ExpoLiveStreamPublisherView';
export type { LiveStreamPublisherRef, LiveStreamPublisherProps, StreamState } from './ExpoLiveStreamPublisherView';

export { default as ExpoLiveStreamPlayerView } from './ExpoLiveStreamPlayerView';
export type { LiveStreamPlayerRef, LiveStreamPlayerProps, PlayerState } from './ExpoLiveStreamPlayerView';

export { LiveStreamWatermark } from './LiveStreamWatermark';
export type { WatermarkProps, WatermarkPosition } from './LiveStreamWatermark';

// Hooks
export { useLiveStream, useLiveStreamPlayer } from './hooks';
export type {
    UseLiveStreamOptions,
    UseLiveStreamReturn,
    UseLiveStreamPlayerOptions,
    UseLiveStreamPlayerReturn,
    ReconnectConfig,
    LiveStreamStatistics,
} from './hooks';

// Presets & Enums
export {
    VideoQuality,
    QualityPresets,
    AudioQuality,
    AudioPresets,
    CameraPosition,
    StreamState as StreamStateEnum,
    PlayerState as PlayerStateEnum,
    StreamProtocol,
    detectProtocol,
} from './presets';
export type { QualityConfig } from './presets';
