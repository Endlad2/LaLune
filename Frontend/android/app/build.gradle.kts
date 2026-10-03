// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// Android-конфиг Flutter-проекта.
//
// ВАЖНО: ndkVersion = "27.0.12077973" — требование shared_preferences_android.
// Без него сборка падает с "plugin(s) depend on a different Android NDK version".

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

    // Подключаем Kotlin-файлы бэкенда из com.lalune.backend.
    // Gradle по умолчанию компилирует всё из src/main/kotlin, так что
    // дополнительных sourceSets не требуется.
    sourceSets {
        getByName("main") {
            java.srcDirs("src/main/kotlin")
        }
    }

    buildTypes {
        release {
            // Debug-подпись — чтобы APK можно было ставить без keystore.
            // Для релиза в маркет нужен свой signingConfig.
            signingConfig = signingConfigs.getByName("debug")
        }
    }

    packaging {
        // Не сжимать .so — они и так упакованы, а распаковка при установке
        // занимает время и требует extractNativeLibs=true.
        jniLibs {
            useLegacyPackaging = true
        }
    }
}

flutter {
    source = "../.."
}
