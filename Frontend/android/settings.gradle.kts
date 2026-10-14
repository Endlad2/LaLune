// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// Android Gradle settings (Flutter 3.29+).
//
// ВАЖНО: order репозиториев здесь критичен.
// Раньше первым был gradlePluginPortal(), который для kotlin-compiler-embeddable
// делает redirect на github.com/JetBrains/kotlin/releases/... — на GitHub
// Actions это регулярно падает с "github.com: No address associated with hostname".
//
// Мы убрали gradlePluginPortal() из pluginManagement и
// dependencyResolutionManagement. Всё нужное (AGP, Kotlin, plugin-loader)
// есть на google() + mavenCentral().

pluginManagement {
    val flutterSdkPath: String = run {
        val properties = java.util.Properties()
        file("local.properties").inputStream().use { properties.load(it) }
        val path = properties.getProperty("flutter.sdk")
        require(path != null) { "flutter.sdk not set in local.properties" }
        path
    }

    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")

    repositories {
        // Порядок: localMaven → google → mavenCentral → gradlePluginPortal (fallback).
        mavenLocal()
        google {
            content {
                includeGroupByRegex("com\\.android.*")
                includeGroupByRegex("com\\.google.*")
                includeGroupByRegex("androidx.*")
            }
        }
        mavenCentral()
        // gradlePluginPortal оставляем последним — только как fallback,
        // если чего-то нет в google/mavenCentral.
        gradlePluginPortal()
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    // AGP 8.7.3 — стабильный, есть на google() без redirects.
    id("com.android.application") version "8.7.3" apply false
    id("com.android.library") version "8.7.3" apply false
    // Kotlin 2.0.21 — есть на Maven Central, но plugin portal redirect'ит на GitHub.
    // Оставляем 2.0.21, но репозитории выше гарантируют, что Gradle пойдёт
    // в mavenCentral первым.
    id("org.jetbrains.kotlin.android") version "2.0.21" apply false
}

include(":app")
