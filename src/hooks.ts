import React, { useState, useCallback, useRef, useEffect } from 'react';
import type { LiveStreamPublisherRef, StreamState } from './ExpoLiveStreamPublisherView';

// ─── Statistics ──────────────────────────────────────────────

export interface LiveStreamStatistics {
    /** Current video bitrate in bps */
    bitrate: number;
    /** Bitrate formatted as human-readable string (e.g., "2.1 Mbps") */
    bitrateFormatted: string;
    /** Duration of current stream in seconds */
    duration: number;
    /** Duration formatted as "HH:MM:SS" */
    durationFormatted: string;
    /** Total bytes sent since stream started */
    totalBytesSent: number;
}

function formatBitrate(bps: number): string {
    if (bps >= 1_000_000) return `${(bps / 1_000_000).toFixed(1)} Mbps`;
    if (bps >= 1_000) return `${(bps / 1_000).toFixed(0)} kbps`;
    return `${bps} bps`;
}

function formatDuration(seconds: number): string {
    const h = Math.floor(seconds / 3600);
    const m = Math.floor((seconds % 3600) / 60);
    const s = seconds % 60;
    return [h, m, s].map((v) => String(v).padStart(2, '0')).join(':');
}

// ─── Reconnect Config ───────────────────────────────────────

export interface ReconnectConfig {
    /** Enable auto-reconnect (default: true) */
    enabled?: boolean;
    /** Maximum number of reconnect attempts (default: 5) */
    maxRetries?: number;
    /** Initial delay in ms before first retry (default: 1000) */
    initialDelay?: number;
    /** Maximum delay in ms between retries (default: 30000) */
    maxDelay?: number;
    /** Exponential backoff multiplier (default: 2) */
    backoffMultiplier?: number;
    /** Called when a reconnect attempt starts */
    onReconnectAttempt?: (attempt: number, maxRetries: number) => void;
    /** Called when all reconnect attempts are exhausted */
    onReconnectFailed?: () => void;
    /** Called when reconnect succeeds */
    onReconnectSuccess?: () => void;
}

const DEFAULT_RECONNECT: Required<Omit<ReconnectConfig, 'onReconnectAttempt' | 'onReconnectFailed' | 'onReconnectSuccess'>> = {
    enabled: true,
    maxRetries: 5,
    initialDelay: 1000,
    maxDelay: 30000,
    backoffMultiplier: 2,
};

// ─── Publisher Hook ──────────────────────────────────────────

export interface UseLiveStreamOptions {
    /** Auto-stop stream when hook unmounts (default: true) */
    autoStopOnUnmount?: boolean;
    /** Auto-reconnect configuration */
    reconnect?: ReconnectConfig;
}

export interface UseLiveStreamReturn {
    /** Ref to attach to ExpoLiveStreamPublisherView */
    ref: React.RefObject<LiveStreamPublisherRef | null>;
    /** Current stream state */
    state: StreamState;
    /** Last error message, null if no error */
    error: string | null;
    /** Whether currently streaming */
    isStreaming: boolean;
    /** Whether currently connecting */
    isConnecting: boolean;
    /** Whether currently reconnecting */
    isReconnecting: boolean;
    /** Current reconnect attempt number (0 if not reconnecting) */
    reconnectAttempt: number;
    /** Live statistics (updates every bitrate callback) */
    statistics: LiveStreamStatistics;
    /** Start streaming */
    start: (url?: string) => void;
    /** Stop streaming */
    stop: () => void;
    /** Switch between front/back camera */
    switchCamera: () => void;
    /** Toggle flash on/off */
    toggleFlash: () => void;
    /** Toggle microphone mute */
    toggleMute: () => void;
    /** Start recording locally (returns file path) */
    startRecording: () => Promise<string>;
    /** Stop recording */
    stopRecording: () => void;
    /** Whether currently recording */
    isRecording: boolean;
    /** Path of the current/last recording */
    recordingPath: string | null;
    /** Set zoom level (0.0 = no zoom, 1.0 = max zoom) */
    setZoom: (level: number) => void;
    /** Get current zoom level (0.0-1.0) */
    getZoom: () => Promise<number>;
    /** Get maximum zoom factor */
    getMaxZoom: () => Promise<number>;
    /** Set exposure compensation (-1.0 to 1.0) */
    setExposure: (value: number) => void;
    /** Get current exposure compensation */
    getExposure: () => Promise<number>;
    /** Set video filter by name */
    setFilter: (name: string) => void;
    /** Get current filter name */
    getFilter: () => Promise<string>;
    /** Get list of available filter names */
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
    /** Clear current error */
    clearError: () => void;

    // ── Event handlers to wire to the view ──
    /** Wire to ExpoLiveStreamPublisherView.onStreamStateChanged */
    handleStreamStateChanged: (event: { nativeEvent: { state: StreamState } }) => void;
    /** Wire to ExpoLiveStreamPublisherView.onConnectionFailed */
    handleConnectionFailed: (event: { nativeEvent: { msg: string } }) => void;
    /** Wire to ExpoLiveStreamPublisherView.onConnectionSuccess */
    handleConnectionSuccess: (event: any) => void;
    /** Wire to ExpoLiveStreamPublisherView.onDisconnect */
    handleDisconnect: (event: any) => void;
    /** Wire to ExpoLiveStreamPublisherView.onBitrateUpdate */
    handleBitrateUpdate: (event: { nativeEvent: { bitrate: number } }) => void;
}

/**
 * Hook for controlling the RTMP publisher with reactive state,
 * auto-reconnect, and live statistics.
 *
 * @example
 * ```tsx
 * const stream = useLiveStream({
 *   reconnect: { enabled: true, maxRetries: 5 },
 * });
 *
 * <ExpoLiveStreamPublisherView
 *   ref={stream.ref}
 *   url="rtmps://secure-server/live/key"
 *   quality={VideoQuality.HD_720P}
 *   onStreamStateChanged={stream.handleStreamStateChanged}
 *   onConnectionFailed={stream.handleConnectionFailed}
 *   onConnectionSuccess={stream.handleConnectionSuccess}
 *   onDisconnect={stream.handleDisconnect}
 *   onBitrateUpdate={stream.handleBitrateUpdate}
 * />
 *
 * // Check stats
 * <Text>{stream.statistics.durationFormatted}</Text>
 * <Text>{stream.statistics.bitrateFormatted}</Text>
 * ```
 */
export function useLiveStream(options: UseLiveStreamOptions = {}): UseLiveStreamReturn {
    const { autoStopOnUnmount = true, reconnect: reconnectOpt } = options;

    const reconnectConfig = {
        ...DEFAULT_RECONNECT,
        ...reconnectOpt,
    };

    const ref = useRef<LiveStreamPublisherRef>(null);
    const [state, setState] = useState<StreamState>('idle');
    const [error, setError] = useState<string | null>(null);
    const [isReconnecting, setIsReconnecting] = useState(false);
    const [reconnectAttempt, setReconnectAttempt] = useState(0);
    const [statistics, setStatistics] = useState<LiveStreamStatistics>({
        bitrate: 0,
        bitrateFormatted: '0 bps',
        duration: 0,
        durationFormatted: '00:00:00',
        totalBytesSent: 0,
    });

    const lastUrlRef = useRef<string | undefined>(undefined);
    const reconnectTimerRef = useRef<any>(null);
    const durationTimerRef = useRef<any>(null);
    const streamStartTimeRef = useRef<number>(0);
    const wasStreamingRef = useRef(false);

    // Recording state
    const [isRecordingState, setIsRecordingState] = useState(false);
    const [recordingPath, setRecordingPath] = useState<string | null>(null);

    const isStreaming = state === 'streaming';
    const isConnecting = state === 'connecting';

    // ── Duration timer ──
    useEffect(() => {
        if (isStreaming) {
            if (!streamStartTimeRef.current) {
                streamStartTimeRef.current = Date.now();
            }
            durationTimerRef.current = setInterval(() => {
                const elapsed = Math.floor((Date.now() - streamStartTimeRef.current) / 1000);
                setStatistics((prev) => ({
                    ...prev,
                    duration: elapsed,
                    durationFormatted: formatDuration(elapsed),
                }));
            }, 1000);
        } else {
            if (durationTimerRef.current) {
                clearInterval(durationTimerRef.current);
                durationTimerRef.current = null;
            }
        }
        return () => {
            if (durationTimerRef.current) clearInterval(durationTimerRef.current);
        };
    }, [isStreaming]);

    // ── Actions ──
    const start = useCallback((url?: string) => {
        setError(null);
        setReconnectAttempt(0);
        setIsReconnecting(false);
        streamStartTimeRef.current = 0;
        setStatistics({
            bitrate: 0,
            bitrateFormatted: '0 bps',
            duration: 0,
            durationFormatted: '00:00:00',
            totalBytesSent: 0,
        });
        lastUrlRef.current = url;
        wasStreamingRef.current = true;
        ref.current?.start(url);
    }, []);

    const stop = useCallback(() => {
        wasStreamingRef.current = false;
        setIsReconnecting(false);
        setReconnectAttempt(0);
        if (reconnectTimerRef.current) {
            clearTimeout(reconnectTimerRef.current);
            reconnectTimerRef.current = null;
        }
        ref.current?.stop();
    }, []);

    const switchCamera = useCallback(() => ref.current?.switchCamera(), []);
    const toggleFlash = useCallback(() => ref.current?.toggleFlash(), []);
    const toggleMute = useCallback(() => ref.current?.toggleMute(), []);
    const clearError = useCallback(() => setError(null), []);

    // ── Auto-reconnect logic ──
    const attemptReconnect = useCallback(
        (attempt: number) => {
            if (!reconnectConfig.enabled || attempt >= reconnectConfig.maxRetries) {
                setIsReconnecting(false);
                reconnectOpt?.onReconnectFailed?.();
                return;
            }

            const delay = Math.min(
                reconnectConfig.initialDelay * Math.pow(reconnectConfig.backoffMultiplier, attempt),
                reconnectConfig.maxDelay,
            );

            setIsReconnecting(true);
            setReconnectAttempt(attempt + 1);
            reconnectOpt?.onReconnectAttempt?.(attempt + 1, reconnectConfig.maxRetries);

            reconnectTimerRef.current = setTimeout(() => {
                ref.current?.start(lastUrlRef.current);
            }, delay);
        },
        [reconnectConfig, reconnectOpt],
    );

    // ── Event handlers ──
    const handleStreamStateChanged = useCallback(
        (event: { nativeEvent: { state: StreamState } }) => {
            const newState = event.nativeEvent.state;
            setState(newState);

            if (newState === 'streaming' && isReconnecting) {
                setIsReconnecting(false);
                setReconnectAttempt(0);
                reconnectOpt?.onReconnectSuccess?.();
            }
        },
        [isReconnecting, reconnectOpt],
    );

    const handleConnectionFailed = useCallback(
        (event: { nativeEvent: { msg: string } }) => {
            setError(event.nativeEvent.msg);
            setState('failed');

            if (wasStreamingRef.current && reconnectConfig.enabled) {
                attemptReconnect(reconnectAttempt);
            }
        },
        [reconnectConfig, reconnectAttempt, attemptReconnect],
    );

    const handleConnectionSuccess = useCallback((_event: any) => {
        setError(null);
    }, []);

    const handleDisconnect = useCallback(
        (_event: any) => {
            setState('disconnected');

            if (wasStreamingRef.current && reconnectConfig.enabled) {
                attemptReconnect(0);
            }
        },
        [reconnectConfig, attemptReconnect],
    );

    const handleBitrateUpdate = useCallback((event: { nativeEvent: { bitrate: number } }) => {
        const bps = event.nativeEvent.bitrate;
        setStatistics((prev) => ({
            ...prev,
            bitrate: bps,
            bitrateFormatted: formatBitrate(bps),
            totalBytesSent: prev.totalBytesSent + bps / 8, // approximate
        }));
    }, []);

    // ── Cleanup ──
    useEffect(() => {
        return () => {
            if (autoStopOnUnmount) ref.current?.stop();
            if (reconnectTimerRef.current) clearTimeout(reconnectTimerRef.current);
            if (durationTimerRef.current) clearInterval(durationTimerRef.current);
        };
    }, [autoStopOnUnmount]);

    return {
        ref,
        state,
        error,
        isStreaming,
        isConnecting,
        isReconnecting,
        reconnectAttempt,
        statistics,
        start,
        stop,
        switchCamera,
        toggleFlash,
        toggleMute,
        startRecording: async () => {
            const path = await ref.current?.startRecording() ?? '';
            setRecordingPath(path);
            setIsRecordingState(true);
            return path;
        },
        stopRecording: () => {
            ref.current?.stopRecording();
            setIsRecordingState(false);
        },
        isRecording: isRecordingState,
        recordingPath,
        setZoom: (level: number) => { ref.current?.setZoom(level); },
        getZoom: () => ref.current?.getZoom() ?? Promise.resolve(0),
        getMaxZoom: () => ref.current?.getMaxZoom() ?? Promise.resolve(1),
        setExposure: (value: number) => { ref.current?.setExposure(value); },
        getExposure: () => ref.current?.getExposure() ?? Promise.resolve(0),
        setFilter: (name: string) => { ref.current?.setFilter(name); },
        getFilter: () => ref.current?.getFilter() ?? Promise.resolve('none'),
        getAvailableFilters: () => ref.current?.getAvailableFilters() ?? Promise.resolve([]),
        // Phase 7
        startMulti: (urls: string[]) => { ref.current?.startMulti(urls); },
        stopMulti: () => { ref.current?.stopMulti(); },
        getMultiDestinations: () => ref.current?.getMultiDestinations() ?? Promise.resolve([]),
        // Phase 8
        setTextOverlay: (text: string, x: number, y: number, size: number) => { ref.current?.setTextOverlay(text, x, y, size); },
        clearOverlay: () => { ref.current?.clearOverlay(); },
        // Phase 9
        setBackgroundMusic: (path: string, volume: number) => { ref.current?.setBackgroundMusic(path, volume); },
        stopBackgroundMusic: () => { ref.current?.stopBackgroundMusic(); },
        // Phase 10
        setAdaptiveBitrate: (enabled: boolean) => { ref.current?.setAdaptiveBitrate(enabled); },
        getStreamStats: () => ref.current?.getStreamStats() ?? Promise.resolve({}),
        clearError,
        handleStreamStateChanged,
        handleConnectionFailed,
        handleConnectionSuccess,
        handleDisconnect,
        handleBitrateUpdate,
    };
}

// ─── Player Hook ─────────────────────────────────────────────

export interface UseLiveStreamPlayerOptions {
    /** Auto-play when component mounts (default: false) */
    autoPlay?: boolean;
    /** Auto-stop when hook unmounts (default: true) */
    autoStopOnUnmount?: boolean;
    /** Auto-reconnect config for player */
    reconnect?: ReconnectConfig;
}

export type PlayerState =
    | 'idle'
    | 'connecting'
    | 'buffering'
    | 'playing'
    | 'paused'
    | 'stopped'
    | 'failed';

export interface UseLiveStreamPlayerReturn {
    /** Ref to attach to ExpoLiveStreamPlayerView */
    ref: React.RefObject<any>;
    /** Current player state */
    state: PlayerState;
    /** Last error message */
    error: string | null;
    /** Whether currently playing */
    isPlaying: boolean;
    /** Whether buffering */
    isBuffering: boolean;
    /** Whether reconnecting */
    isReconnecting: boolean;
    /** Current reconnect attempt */
    reconnectAttempt: number;
    /** Start playback */
    play: () => void;
    /** Stop playback */
    stop: () => void;
    /** Pause playback */
    pause: () => void;
    /** Resume playback */
    resume: () => void;
    /** Set volume (0.0 – 1.0) */
    setVolume: (volume: number) => void;
    /** Mute/unmute audio */
    setMuted: (muted: boolean) => void;
    /** Seek to position in ms (VOD only) */
    seekTo: (positionMs: number) => void;
    /** Get current position in ms */
    getPosition: () => Promise<number>;
    /** Get total duration in ms (0 for live) */
    getDuration: () => Promise<number>;
    /** Set playback speed (1.0 = normal, 2.0 = 2x) */
    setRate: (rate: number) => void;
    /** Clear error */
    clearError: () => void;

    // ── Event handlers ──
    /** Wire to ExpoLiveStreamPlayerView.onPlayerStateChanged */
    handlePlayerStateChanged: (event: { nativeEvent: { state: string } }) => void;
    /** Wire to ExpoLiveStreamPlayerView.onPlayerError */
    handlePlayerError: (event: { nativeEvent: { msg: string } }) => void;
}

/**
 * Hook for controlling the RTMP player with reactive state and auto-reconnect.
 *
 * @example
 * ```tsx
 * const player = useLiveStreamPlayer({ autoPlay: true });
 *
 * <ExpoLiveStreamPlayerView
 *   ref={player.ref}
 *   url="rtmps://secure-server/live/key"
 *   onPlayerStateChanged={player.handlePlayerStateChanged}
 *   onPlayerError={player.handlePlayerError}
 * />
 * ```
 */
export function useLiveStreamPlayer(
    options: UseLiveStreamPlayerOptions = {},
): UseLiveStreamPlayerReturn {
    const { autoPlay = false, autoStopOnUnmount = true, reconnect: reconnectOpt } = options;

    const reconnectConfig = {
        ...DEFAULT_RECONNECT,
        ...reconnectOpt,
    };

    const ref = useRef<any>(null);
    const [state, setState] = useState<PlayerState>('idle');
    const [error, setError] = useState<string | null>(null);
    const [isReconnecting, setIsReconnecting] = useState(false);
    const [reconnectAttempt, setReconnectAttempt] = useState(0);
    const reconnectTimerRef = useRef<any>(null);
    const hasAutoPlayed = useRef(false);
    const wasPlayingRef = useRef(false);

    const isPlaying = state === 'playing';
    const isBuffering = state === 'buffering';

    const play = useCallback(() => {
        setError(null);
        wasPlayingRef.current = true;
        ref.current?.play();
    }, []);

    const stop = useCallback(() => {
        wasPlayingRef.current = false;
        setIsReconnecting(false);
        setReconnectAttempt(0);
        if (reconnectTimerRef.current) clearTimeout(reconnectTimerRef.current);
        ref.current?.stop();
    }, []);

    const pause = useCallback(() => ref.current?.pause(), []);
    const resume = useCallback(() => ref.current?.resume(), []);
    const setVolume = useCallback((volume: number) => ref.current?.setVolume(volume), []);
    const setMuted = useCallback((muted: boolean) => ref.current?.setMuted(muted), []);
    const seekTo = useCallback((positionMs: number) => ref.current?.seekTo(positionMs), []);
    const getPosition = useCallback((): Promise<number> => ref.current?.getPosition() ?? Promise.resolve(0), []);
    const getDuration = useCallback((): Promise<number> => ref.current?.getDuration() ?? Promise.resolve(0), []);
    const setRate = useCallback((rate: number) => ref.current?.setRate(rate), []);
    const clearError = useCallback(() => setError(null), []);

    // ── Auto-reconnect ──
    const attemptReconnect = useCallback(
        (attempt: number) => {
            if (!reconnectConfig.enabled || attempt >= reconnectConfig.maxRetries) {
                setIsReconnecting(false);
                reconnectOpt?.onReconnectFailed?.();
                return;
            }

            const delay = Math.min(
                reconnectConfig.initialDelay * Math.pow(reconnectConfig.backoffMultiplier, attempt),
                reconnectConfig.maxDelay,
            );

            setIsReconnecting(true);
            setReconnectAttempt(attempt + 1);
            reconnectOpt?.onReconnectAttempt?.(attempt + 1, reconnectConfig.maxRetries);

            reconnectTimerRef.current = setTimeout(() => {
                ref.current?.play();
            }, delay);
        },
        [reconnectConfig, reconnectOpt],
    );

    // ── Event handlers ──
    const handlePlayerStateChanged = useCallback(
        (event: { nativeEvent: { state: string } }) => {
            const newState = event.nativeEvent.state as PlayerState;
            setState(newState);

            if (newState === 'playing' && isReconnecting) {
                setIsReconnecting(false);
                setReconnectAttempt(0);
                reconnectOpt?.onReconnectSuccess?.();
            }
        },
        [isReconnecting, reconnectOpt],
    );

    const handlePlayerError = useCallback(
        (event: { nativeEvent: { msg: string } }) => {
            setError(event.nativeEvent.msg);
            setState('failed');

            if (wasPlayingRef.current && reconnectConfig.enabled) {
                attemptReconnect(reconnectAttempt);
            }
        },
        [reconnectConfig, reconnectAttempt, attemptReconnect],
    );

    // ── Auto-play ──
    useEffect(() => {
        if (autoPlay && !hasAutoPlayed.current && ref.current) {
            hasAutoPlayed.current = true;
            const timer = setTimeout(() => play(), 300);
            return () => clearTimeout(timer);
        }
    }, [autoPlay, play]);

    // ── Cleanup ──
    useEffect(() => {
        return () => {
            if (autoStopOnUnmount) ref.current?.stop();
            if (reconnectTimerRef.current) clearTimeout(reconnectTimerRef.current);
        };
    }, [autoStopOnUnmount]);

    return {
        ref,
        state,
        error,
        isPlaying,
        isBuffering,
        isReconnecting,
        reconnectAttempt,
        play,
        stop,
        pause,
        resume,
        setVolume,
        setMuted,
        seekTo,
        getPosition,
        getDuration,
        setRate,
        clearError,
        handlePlayerStateChanged,
        handlePlayerError,
    };
}
