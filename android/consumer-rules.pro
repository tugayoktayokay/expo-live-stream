# expo-live-stream module
-keep class expo.modules.livestream.** { *; }
-dontwarn expo.modules.livestream.**

# RootEncoder (RTMP publishing)
-keep class com.pedro.** { *; }
-dontwarn com.pedro.**

# VLC (libvlc-all — RTMP playback)
-keep class org.videolan.** { *; }
-dontwarn org.videolan.**
