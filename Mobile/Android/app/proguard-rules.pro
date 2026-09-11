# LaLune ProGuard rules
# Пока minifyEnabled=false, файл не используется, но пусть будет заготовкой.

# Сохраняем JS-мост
-keepclassmembers class com.lalune.app.MainActivity$AndroidBridge {
    @android.webkit.JavascriptInterface <methods>;
}

# Kotlin coroutines
-keepnames class kotlinx.coroutines.internal.MainDispatcherFactory {}
-keepnames class kotlinx.coroutines.CoroutineExceptionHandler {}

# JSON
-keep class org.json.** { *; }
