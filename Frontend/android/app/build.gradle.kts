// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// Android-конфиг Flutter-проекта.
//
// Добавлена зависимость LuaJ — чистый Java-интерпретатор Lua 5.2
// (без NDK/JNI/внешних .so). Используется в Backend/Android/LuaRuntime.kt
// для SmartTunnel + csqtt_decode.

plugins {
    id("com.android.application")
    id("kotlin-android")
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.lalune.lalune"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = "27.0.12077973"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        applicationId = "com.lalune.lalune"
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("debug")
        }
    }

    packaging {
        jniLibs {
            useLegacyPackaging = true
        }
        // LuaJ-jse не содержит дубликатов META-INF, но на всякий случай
        // исключаем типичные конфликты.
        resources {
            excludes += setOf(
                "META-INF/DEPENDENCIES",
                "META-INF/LICENSE",
                "META-INF/LICENSE.txt",
                "META-INF/NOTICE",
                "META-INF/NOTICE.txt",
            )
        }
    }
}

dependencies {
    // Lua 5.2 интерпретатор (чистый Java, без NDK/JNI).
    // Используется в com.lalune.lalune.LuaRuntime.
    implementation("org.luaj:luaj-jse:3.0.1")
}

flutter {
    source = "../.."
}
