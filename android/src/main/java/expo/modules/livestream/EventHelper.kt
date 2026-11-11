package expo.modules.livestream

import android.view.View
import com.facebook.react.bridge.Arguments
import com.facebook.react.bridge.ReactContext
import com.facebook.react.bridge.WritableMap
import com.facebook.react.uimanager.UIManagerHelper
import com.facebook.react.uimanager.events.Event

internal fun normalizeReactEventName(eventName: String): String {
  return if (eventName.startsWith("on") && eventName.length > 2) {
    "top" + eventName.substring(2)
  } else {
    eventName
  }
}

internal fun emitViewEvent(view: View, eventName: String, params: Map<String, Any?> = emptyMap()) {
  val reactContext = view.context as? ReactContext ?: return
  val surfaceId = UIManagerHelper.getSurfaceId(view)
  val dispatcher = UIManagerHelper.getEventDispatcherForReactTag(reactContext, view.id) ?: return
  val payload = Arguments.createMap()
  for ((k, v) in params) {
    when (v) {
      null -> payload.putNull(k)
      is String -> payload.putString(k, v)
      is Int -> payload.putInt(k, v)
      is Double -> payload.putDouble(k, v)
      is Float -> payload.putDouble(k, v.toDouble())
      is Long -> payload.putDouble(k, v.toDouble())
      is Boolean -> payload.putBoolean(k, v)
      else -> payload.putString(k, v.toString())
    }
  }
  dispatcher.dispatchEvent(
    SimpleViewEvent(surfaceId, view.id, normalizeReactEventName(eventName), payload)
  )
}

private class SimpleViewEvent(
  surfaceId: Int,
  viewId: Int,
  private val customEventName: String,
  private val payload: WritableMap
) : Event<SimpleViewEvent>(surfaceId, viewId) {
  override fun getEventName(): String = customEventName
  override fun getEventData(): WritableMap = payload
}
