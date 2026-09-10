# Keep WebView JS interface
-keepclassmembers class com.lalune.app.MainActivity$AndroidBridge {
    public *;
}
-keep class com.lalune.app.** { *; }
