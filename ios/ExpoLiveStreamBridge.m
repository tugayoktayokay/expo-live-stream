#if !__has_include(<ExpoModulesCore/ExpoModulesCore.h>)
#import <React/RCTBridgeModule.h>
#import <React/RCTViewManager.h>

@interface RCT_EXTERN_REMAP_MODULE(ExpoLiveStream, ExpoLiveStreamRNViewManager, RCTViewManager)

RCT_EXPORT_VIEW_PROPERTY(url, NSString)
RCT_EXPORT_VIEW_PROPERTY(streamKey, NSString)
RCT_EXPORT_VIEW_PROPERTY(videoWidth, NSInteger)
RCT_EXPORT_VIEW_PROPERTY(videoHeight, NSInteger)
RCT_EXPORT_VIEW_PROPERTY(videoBitrate, NSInteger)
RCT_EXPORT_VIEW_PROPERTY(videoFps, double)
RCT_EXPORT_VIEW_PROPERTY(audioBitrate, NSInteger)
RCT_EXPORT_VIEW_PROPERTY(audioSampleRate, double)
RCT_EXPORT_VIEW_PROPERTY(frontCamera, BOOL)
RCT_EXPORT_VIEW_PROPERTY(onConnectionSuccess, RCTDirectEventBlock)
RCT_EXPORT_VIEW_PROPERTY(onConnectionFailed, RCTDirectEventBlock)
RCT_EXPORT_VIEW_PROPERTY(onDisconnect, RCTDirectEventBlock)
RCT_EXPORT_VIEW_PROPERTY(onStreamStateChanged, RCTDirectEventBlock)
RCT_EXPORT_VIEW_PROPERTY(onBitrateUpdate, RCTDirectEventBlock)

RCT_EXTERN_METHOD(start:(NSString *)url)
RCT_EXTERN_METHOD(stop)
RCT_EXTERN_METHOD(switchCamera)
RCT_EXTERN_METHOD(toggleFlash)
RCT_EXTERN_METHOD(toggleMute)

@end

@interface RCT_EXTERN_REMAP_MODULE(ExpoLiveStreamPlayer, ExpoLiveStreamPlayerRNViewManager, RCTViewManager)

RCT_EXPORT_VIEW_PROPERTY(url, NSString)
RCT_EXPORT_VIEW_PROPERTY(streamName, NSString)
RCT_EXPORT_VIEW_PROPERTY(onPlayerStateChanged, RCTDirectEventBlock)
RCT_EXPORT_VIEW_PROPERTY(onPlayerError, RCTDirectEventBlock)

RCT_EXTERN_METHOD(playerPlay)
RCT_EXTERN_METHOD(playerStop)
RCT_EXTERN_METHOD(playerPause)
RCT_EXTERN_METHOD(playerResume)

@end
#endif
