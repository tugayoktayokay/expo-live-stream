# expo-live-stream module
-keep class expo.modules.livestream.** { *; }
-dontwarn expo.modules.livestream.**

# RootEncoder (RTMP publishing)
-keep class com.pedro.** { *; }
-dontwarn com.pedro.**

# Media3/ExoPlayer (RTMP playback) ships its own consumer rules in the AAR, so
# only the RTMP client it pulls in needs covering here.
-dontwarn io.antmedia.rtmp_client.**

# Kotlin Reflection & Metadata (required by ExpoModulesCore View/Prop/AsyncFunction typeOf)
-keep class kotlin.Metadata { *; }
-keep class kotlin.reflect.** { *; }
-keepclassmembers class kotlin.reflect.** { *; }
-dontwarn kotlin.reflect.**
-keep class kotlin.jvm.internal.** { *; }
-dontwarn org.slf4j.**
