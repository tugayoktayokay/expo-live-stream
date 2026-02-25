// ─── Video Quality Presets ───────────────────────────────────

export enum VideoQuality {
    /** 240×426, 400kbps — minimum bandwidth */
    LOW_240P = '240p',
    /** 360×640, 800kbps — low quality */
    LOW_360P = '360p',
    /** 480×854, 1.2Mbps — standard definition */
    SD_480P = '480p',
    /** 720×1280, 2Mbps — HD (recommended) */
    HD_720P = '720p',
    /** 1080×1920, 4Mbps — Full HD */
    FHD_1080P = '1080p',
}

export interface QualityConfig {
    videoWidth: number;
    videoHeight: number;
    videoBitrate: number;
    videoFps: number;
    audioBitrate: number;
    audioSampleRate: number;
}

export const QualityPresets: Record<VideoQuality, QualityConfig> = {
    [VideoQuality.LOW_240P]: {
        videoWidth: 240,
        videoHeight: 426,
        videoBitrate: 400_000,
        videoFps: 24,
        audioBitrate: 64_000,
        audioSampleRate: 44100,
    },
    [VideoQuality.LOW_360P]: {
        videoWidth: 360,
        videoHeight: 640,
        videoBitrate: 800_000,
        videoFps: 24,
        audioBitrate: 96_000,
        audioSampleRate: 44100,
    },
    [VideoQuality.SD_480P]: {
        videoWidth: 480,
        videoHeight: 854,
        videoBitrate: 1_200_000,
        videoFps: 30,
        audioBitrate: 128_000,
        audioSampleRate: 44100,
    },
    [VideoQuality.HD_720P]: {
        videoWidth: 720,
        videoHeight: 1280,
        videoBitrate: 2_000_000,
        videoFps: 30,
        audioBitrate: 128_000,
        audioSampleRate: 44100,
    },
    [VideoQuality.FHD_1080P]: {
        videoWidth: 1080,
        videoHeight: 1920,
        videoBitrate: 4_000_000,
        videoFps: 30,
        audioBitrate: 192_000,
        audioSampleRate: 48000,
    },
};

// ─── Audio Quality Presets ───────────────────────────────────

export enum AudioQuality {
    /** 64kbps mono — minimum */
    LOW = 'low',
    /** 128kbps stereo — standard (recommended) */
    STANDARD = 'standard',
    /** 192kbps stereo — high */
    HIGH = 'high',
}

export const AudioPresets: Record<AudioQuality, { audioBitrate: number; audioSampleRate: number }> = {
    [AudioQuality.LOW]: { audioBitrate: 64_000, audioSampleRate: 44100 },
    [AudioQuality.STANDARD]: { audioBitrate: 128_000, audioSampleRate: 44100 },
    [AudioQuality.HIGH]: { audioBitrate: 192_000, audioSampleRate: 48000 },
};

// ─── Camera Position ────────────────────────────────────────

export enum CameraPosition {
    FRONT = 'front',
    BACK = 'back',
}

// ─── Stream State ───────────────────────────────────────────

export enum StreamState {
    IDLE = 'idle',
    CONNECTING = 'connecting',
    STREAMING = 'streaming',
    STOPPED = 'stopped',
    FAILED = 'failed',
    DISCONNECTED = 'disconnected',
}

// ─── Player State ───────────────────────────────────────────

export enum PlayerState {
    IDLE = 'idle',
    CONNECTING = 'connecting',
    BUFFERING = 'buffering',
    PLAYING = 'playing',
    PAUSED = 'paused',
    STOPPED = 'stopped',
    FAILED = 'failed',
}
