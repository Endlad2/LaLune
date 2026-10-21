// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// Android-конфиг Flutter-проекта.
//
// csqtt-link упаковывается как ELF-бинарник в jniLibs/<abi>/libcsqtt-link.so.
// ВАЖНО: APK-упаковщик по умолчанию сжимает .so → ProcessBuilder не сможет
// exec-нуть файл (EACCES). Поэтому useLegacyPackaging = true +
// keepDebugSymbols для libcsqtt-link.so, чтобы файл шёл в APK без сжатия.
//
// LuaJ — чистый Java Lua 5.2 интерпретатор, используется в LuaRuntime.kt.

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
            // Оставляем .so без сжатия — это критично для csqtt-link,
            // потому что он запускается как ELF-бинарник через ProcessBuilder,
            // а не грузится через System.loadLibrary.
            useLegacyPackaging = true

            // Явно просим не сжимать и не резать debug symbols у нашего ELF.
            // В большинстве AGP-версий этого достаточно вместе с
            // useLegacyPackaging = true.
            keepDebugSymbols += setOf(
                "**/libcsqtt-link.so",
            )
        }
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
