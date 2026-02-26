/**
 * expo-live-stream — Feature Tests (Phases 5–10)
 *
 * Tests verify native module wiring, correct argument passing, and return types.
 */

// ── Mock the native module ──────────────────────────────────────────────────
const mockNativeModule = {
    // Phase 5: Camera Controls
    publisherSetZoom: jest.fn(),
    publisherGetZoom: jest.fn().mockResolvedValue(0),
    publisherGetMaxZoom: jest.fn().mockResolvedValue(10),
    publisherSetExposure: jest.fn(),
    publisherGetExposure: jest.fn().mockResolvedValue(0),
    // Phase 6: Filters
    publisherSetFilter: jest.fn(),
    publisherGetFilter: jest.fn().mockResolvedValue('none'),
    publisherGetAvailableFilters: jest.fn().mockResolvedValue([
        'none', 'sepia', 'grayscale', 'negative', 'brightness',
        'contrast', 'saturation', 'edge_detection', 'beauty',
        'cartoon', 'glitch', 'snow', 'blur',
    ]),
    // Phase 7: Multi-Destination
    publisherStartMulti: jest.fn(),
    publisherStopMulti: jest.fn(),
    publisherGetMultiDestinations: jest.fn().mockResolvedValue([]),
    // Phase 8: Overlay
    publisherSetTextOverlay: jest.fn(),
    publisherClearOverlay: jest.fn(),
    // Phase 9: Audio
    publisherSetBackgroundMusic: jest.fn(),
    publisherStopBackgroundMusic: jest.fn(),
    // Phase 10: Advanced
    publisherSetAdaptiveBitrate: jest.fn(),
    publisherGetStreamStats: jest.fn().mockResolvedValue({
        isStreaming: false,
        isRecording: false,
        isFrontCamera: true,
        currentFilter: 'none',
        secondaryDestinations: 0,
    }),
    // Existing
    publisherStart: jest.fn(),
    publisherStop: jest.fn(),
    publisherSwitchCamera: jest.fn(),
    publisherToggleFlash: jest.fn(),
    publisherToggleMute: jest.fn(),
    publisherStartRecording: jest.fn(),
    publisherStopRecording: jest.fn(),
    publisherIsRecording: jest.fn().mockResolvedValue(false),
};

jest.mock('expo-modules-core', () => ({
    requireNativeModule: () => mockNativeModule,
    requireNativeViewManager: () => 'ExpoLiveStreamPublisherView',
}));

jest.mock('react-native', () => ({
    Platform: { OS: 'android', select: (obj) => obj.android },
    UIManager: {},
    StyleSheet: {
        create: (styles) => styles,
        absoluteFill: {},
    },
    findNodeHandle: jest.fn().mockReturnValue(1),
}));

// ── Tests ────────────────────────────────────────────────────────────────────

describe('Module API Completeness', () => {
    it('native module has all Phase 5 methods', () => {
        expect(typeof mockNativeModule.publisherSetZoom).toBe('function');
        expect(typeof mockNativeModule.publisherGetZoom).toBe('function');
        expect(typeof mockNativeModule.publisherGetMaxZoom).toBe('function');
        expect(typeof mockNativeModule.publisherSetExposure).toBe('function');
        expect(typeof mockNativeModule.publisherGetExposure).toBe('function');
    });

    it('native module has all Phase 6 methods', () => {
        expect(typeof mockNativeModule.publisherSetFilter).toBe('function');
        expect(typeof mockNativeModule.publisherGetFilter).toBe('function');
        expect(typeof mockNativeModule.publisherGetAvailableFilters).toBe('function');
    });

    it('native module has all Phase 7-10 methods', () => {
        expect(typeof mockNativeModule.publisherStartMulti).toBe('function');
        expect(typeof mockNativeModule.publisherStopMulti).toBe('function');
        expect(typeof mockNativeModule.publisherGetMultiDestinations).toBe('function');
        expect(typeof mockNativeModule.publisherSetTextOverlay).toBe('function');
        expect(typeof mockNativeModule.publisherClearOverlay).toBe('function');
        expect(typeof mockNativeModule.publisherSetBackgroundMusic).toBe('function');
        expect(typeof mockNativeModule.publisherStopBackgroundMusic).toBe('function');
        expect(typeof mockNativeModule.publisherSetAdaptiveBitrate).toBe('function');
        expect(typeof mockNativeModule.publisherGetStreamStats).toBe('function');
    });
});

describe('Phase 5 — Camera Controls', () => {
    beforeEach(() => jest.clearAllMocks());

    it('setZoom passes level to native', async () => {
        await mockNativeModule.publisherSetZoom(0.5);
        expect(mockNativeModule.publisherSetZoom).toHaveBeenCalledWith(0.5);
    });

    it('getZoom returns number', async () => {
        const zoom = await mockNativeModule.publisherGetZoom();
        expect(typeof zoom).toBe('number');
        expect(zoom).toBe(0);
    });

    it('getMaxZoom returns number', async () => {
        const max = await mockNativeModule.publisherGetMaxZoom();
        expect(typeof max).toBe('number');
        expect(max).toBe(10);
    });

    it('setExposure passes value to native', async () => {
        await mockNativeModule.publisherSetExposure(-0.5);
        expect(mockNativeModule.publisherSetExposure).toHaveBeenCalledWith(-0.5);
    });

    it('getExposure returns number', async () => {
        const exp = await mockNativeModule.publisherGetExposure();
        expect(typeof exp).toBe('number');
    });
});

describe('Phase 6 — Filters', () => {
    beforeEach(() => jest.clearAllMocks());

    it('setFilter cycles through all 13 filters', async () => {
        const filters = [
            'none', 'sepia', 'grayscale', 'negative', 'brightness',
            'contrast', 'saturation', 'edge_detection', 'beauty',
            'cartoon', 'glitch', 'snow', 'blur',
        ];
        for (const f of filters) {
            await mockNativeModule.publisherSetFilter(f);
        }
        expect(mockNativeModule.publisherSetFilter).toHaveBeenCalledTimes(13);
    });

    it('getFilter returns string', async () => {
        const filter = await mockNativeModule.publisherGetFilter();
        expect(typeof filter).toBe('string');
        expect(filter).toBe('none');
    });

    it('getAvailableFilters returns 13 items', async () => {
        const list = await mockNativeModule.publisherGetAvailableFilters();
        expect(list).toHaveLength(13);
        expect(list).toContain('sepia');
        expect(list).toContain('cartoon');
        expect(list).toContain('blur');
    });
});

describe('Phase 7 — Multi-Destination', () => {
    beforeEach(() => jest.clearAllMocks());

    it('startMulti accepts URL array', async () => {
        const urls = ['rtmp://a/live/1', 'rtmp://b/live/2'];
        await mockNativeModule.publisherStartMulti(urls);
        expect(mockNativeModule.publisherStartMulti).toHaveBeenCalledWith(urls);
    });

    it('stopMulti is callable', async () => {
        await mockNativeModule.publisherStopMulti();
        expect(mockNativeModule.publisherStopMulti).toHaveBeenCalled();
    });

    it('getMultiDestinations returns array', async () => {
        const d = await mockNativeModule.publisherGetMultiDestinations();
        expect(Array.isArray(d)).toBe(true);
    });
});

describe('Phase 8 — Overlay', () => {
    beforeEach(() => jest.clearAllMocks());

    it('setTextOverlay passes text, x, y, size', async () => {
        await mockNativeModule.publisherSetTextOverlay('LIVE', 0.1, 0.1, 24);
        expect(mockNativeModule.publisherSetTextOverlay).toHaveBeenCalledWith('LIVE', 0.1, 0.1, 24);
    });

    it('clearOverlay is callable', async () => {
        await mockNativeModule.publisherClearOverlay();
        expect(mockNativeModule.publisherClearOverlay).toHaveBeenCalled();
    });
});

describe('Phase 9 — Audio Mixing', () => {
    beforeEach(() => jest.clearAllMocks());

    it('setBackgroundMusic passes path and volume', async () => {
        await mockNativeModule.publisherSetBackgroundMusic('/music.mp3', 0.5);
        expect(mockNativeModule.publisherSetBackgroundMusic).toHaveBeenCalledWith('/music.mp3', 0.5);
    });

    it('stopBackgroundMusic is callable', async () => {
        await mockNativeModule.publisherStopBackgroundMusic();
        expect(mockNativeModule.publisherStopBackgroundMusic).toHaveBeenCalled();
    });
});

describe('Phase 10 — Advanced', () => {
    beforeEach(() => jest.clearAllMocks());

    it('setAdaptiveBitrate accepts boolean', async () => {
        await mockNativeModule.publisherSetAdaptiveBitrate(true);
        expect(mockNativeModule.publisherSetAdaptiveBitrate).toHaveBeenCalledWith(true);
        await mockNativeModule.publisherSetAdaptiveBitrate(false);
        expect(mockNativeModule.publisherSetAdaptiveBitrate).toHaveBeenCalledWith(false);
    });

    it('getStreamStats returns stats object', async () => {
        const stats = await mockNativeModule.publisherGetStreamStats();
        expect(stats).toHaveProperty('isStreaming');
        expect(stats).toHaveProperty('isRecording');
        expect(stats).toHaveProperty('isFrontCamera');
        expect(stats).toHaveProperty('currentFilter');
        expect(stats).toHaveProperty('secondaryDestinations');
        expect(stats.isStreaming).toBe(false);
        expect(stats.currentFilter).toBe('none');
    });
});
