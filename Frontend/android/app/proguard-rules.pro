# FreeTurn AAR (gomobile bind): JNI-классы, EventSink, Protector.
-keep class com.freeturn.core.mobile.** { *; }
-keep interface com.freeturn.core.mobile.** { *; }
-keepclassmembers class com.freeturn.core.mobile.** {
    native <methods>;
    public *;
}

# LaLune backend + VpnService + LaLuneApplication
-keep class com.lalune.lalune.** { *; }

# AndroidX
-keep class androidx.core.app.NotificationCompat { *; }
-keep class androidx.core.app.ServiceCompat { *; }
