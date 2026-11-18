package expo.modules.livestream

import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.bridge.ReactContextBaseJavaModule
import com.facebook.react.bridge.ReactMethod
import com.facebook.react.common.MapBuilder
import com.facebook.react.uimanager.SimpleViewManager
import com.facebook.react.uimanager.ThemedReactContext
import com.facebook.react.uimanager.annotations.ReactProp

class ExpoLiveStreamPlayerRNModule(reactContext: ReactApplicationContext) : ReactContextBaseJavaModule(reactContext) {
  override fun getName(): String = "ExpoLiveStreamPlayer"

  @ReactMethod
  fun playerPlay() {
    PlayerView.activeInstance?.let { view -> view.post { view.play() } }
  }

  @ReactMethod
  fun playerStop() {
    PlayerView.activeInstance?.let { view -> view.post { view.stop() } }
  }

  @ReactMethod
  fun playerPause() {
    PlayerView.activeInstance?.let { view -> view.post { view.pause() } }
  }

  @ReactMethod
  fun playerResume() {
    PlayerView.activeInstance?.let { view -> view.post { view.resume() } }
  }
}

class ExpoLiveStreamPlayerViewManager : SimpleViewManager<PlayerView>() {
  override fun getName(): String = "ExpoLiveStreamPlayer"

  override fun createViewInstance(reactContext: ThemedReactContext): PlayerView {
    return PlayerView(reactContext)
  }

  @ReactProp(name = "url")
  fun setUrl(view: PlayerView, url: String?) {
    view.url = url ?: ""
  }

  @ReactProp(name = "streamName")
  fun setStreamName(view: PlayerView, name: String?) {
    view.streamName = name ?: ""
  }

  @ReactProp(name = "resizeMode")
  fun setResizeMode(view: PlayerView, mode: String?) {
    view.resizeMode = mode ?: "contain"
  }

  override fun getExportedCustomDirectEventTypeConstants(): MutableMap<String, Any> {
    val map = super.getExportedCustomDirectEventTypeConstants() ?: mutableMapOf()
    val events = listOf(
      "onPlayerStateChanged",
      "onPlayerError"
    )
    for (ev in events) {
      map[ev] = MapBuilder.of("registrationName", ev)
      map[normalizeReactEventName(ev)] = MapBuilder.of("registrationName", ev)
    }
    return map
  }
}
