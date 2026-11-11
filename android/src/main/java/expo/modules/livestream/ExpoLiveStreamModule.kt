package expo.modules.livestream

import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.bridge.ReactContextBaseJavaModule
import com.facebook.react.bridge.ReactMethod
import com.facebook.react.common.MapBuilder
import com.facebook.react.uimanager.SimpleViewManager
import com.facebook.react.uimanager.ThemedReactContext
import com.facebook.react.uimanager.annotations.ReactProp

class ExpoLiveStreamRNModule(reactContext: ReactApplicationContext) : ReactContextBaseJavaModule(reactContext) {
  override fun getName(): String = "ExpoLiveStream"

  @ReactMethod
  fun start(url: String?) {
    PublisherView.activeInstance?.let { view -> view.post { view.start(url) } }
  }

  @ReactMethod
  fun stop() {
    PublisherView.activeInstance?.let { view -> view.post { view.stop() } }
  }

  @ReactMethod
  fun switchCamera() {
    PublisherView.activeInstance?.let { view -> view.post { view.switchCamera() } }
  }

  @ReactMethod
  fun toggleFlash() {
    PublisherView.activeInstance?.let { view -> view.post { view.toggleFlash() } }
  }

  @ReactMethod
  fun toggleMute() {
    PublisherView.activeInstance?.let { view -> view.post { view.toggleMute() } }
  }
}

class ExpoLiveStreamViewManager : SimpleViewManager<PublisherView>() {
  override fun getName(): String = "ExpoLiveStream"

  override fun createViewInstance(reactContext: ThemedReactContext): PublisherView {
    return PublisherView(reactContext)
  }

  @ReactProp(name = "url")
  fun setUrl(view: PublisherView, url: String?) {
    view.url = url ?: ""
  }

  @ReactProp(name = "streamKey")
  fun setStreamKey(view: PublisherView, key: String?) {
    view.streamKey = key ?: ""
  }

  @ReactProp(name = "videoWidth", defaultInt = 720)
  fun setVideoWidth(view: PublisherView, width: Int) {
    view.videoWidth = width
  }

  @ReactProp(name = "videoHeight", defaultInt = 1280)
  fun setVideoHeight(view: PublisherView, height: Int) {
    view.videoHeight = height
  }

  @ReactProp(name = "videoBitrate", defaultInt = 2_000_000)
  fun setVideoBitrate(view: PublisherView, bitrate: Int) {
    view.videoBitrate = bitrate
  }

  @ReactProp(name = "videoFps", defaultInt = 30)
  fun setVideoFps(view: PublisherView, fps: Int) {
    view.videoFps = fps
  }

  @ReactProp(name = "audioBitrate", defaultInt = 128_000)
  fun setAudioBitrate(view: PublisherView, bitrate: Int) {
    view.audioBitrate = bitrate
  }

  @ReactProp(name = "audioSampleRate", defaultInt = 44100)
  fun setAudioSampleRate(view: PublisherView, rate: Int) {
    view.audioSampleRate = rate
  }

  @ReactProp(name = "frontCamera", defaultBoolean = true)
  fun setFrontCamera(view: PublisherView, front: Boolean) {
    view.isFrontCamera = front
  }

  override fun getExportedCustomDirectEventTypeConstants(): MutableMap<String, Any> {
    val map = super.getExportedCustomDirectEventTypeConstants() ?: mutableMapOf()
    val events = listOf(
      "onConnectionSuccess",
      "onConnectionFailed",
      "onDisconnect",
      "onStreamStateChanged",
      "onBitrateUpdate"
    )
    for (ev in events) {
      map[ev] = MapBuilder.of("registrationName", ev)
      map[normalizeReactEventName(ev)] = MapBuilder.of("registrationName", ev)
    }
    return map
  }
}
