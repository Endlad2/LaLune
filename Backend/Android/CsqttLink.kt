// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// JNI-мост к libcsqtt_decode.so (Rust-крейт Core/csqtt-link).
//
// Библиотека лежит в jniLibs/<abi>/libcsqtt_decode.so.
// Если её нет (старая сборка) — loadLibrary бросит UnsatisfiedLinkError,
// и вызывающий код должен использовать нативный fallback.

package com.lalune.lalune

import android.util.Log

object CsqttLink {
    private const val TAG = "LaLune-CsqttLink"

    @Volatile private var loaded = false
    @Volatile private var loadFailed = false

    fun ensureLoaded(): Boolean {
        if (loaded) return true
        if (loadFailed) return false
        return try {
            System.loadLibrary("csqtt_decode")
            loaded = true
            Log.i(TAG, "libcsqtt_decode.so loaded")
            true
        } catch (e: UnsatisfiedLinkError) {
            loadFailed = true
            Log.w(TAG, "libcsqtt_decode.so not available: ${e.message}")
            false
        }
    }

    /** Возвращает JSON или null. */
    fun parse(link: String): String? {
        if (!ensureLoaded()) return null
        return try {
            nativeParse(link)
        } catch (e: Throwable) {
            Log.w(TAG, "nativeParse failed: ${e.message}")
            null
        }
    }

    /** Возвращает `csqtt://connect?...` или null. */
    fun decode(link: String): String? {
        if (!ensureLoaded()) return null
        return try {
            nativeDecode(link)
        } catch (e: Throwable) {
            Log.w(TAG, "nativeDecode failed: ${e.message}")
            null
        }
    }

    fun lastError(): String? {
        if (!ensureLoaded()) return null
        return try {
            nativeLastError()
        } catch (_: Throwable) {
            null
        }
    }

    // JNI-функции (реализованы в Rust через #[no_mangle]).
    // Реализация csqtt_link_parse / csqtt_link_decode в Core/csqtt-link/src/lib.rs
    // вызывается через JNI-обёртки. Мы используем простой подход:
    // JNI_OnLoad не нужен, символы ищутся по имени.
    private external fun nativeParse(link: String): String?
    private external fun nativeDecode(link: String): String?
    private external fun nativeLastError(): String?
}
