// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// Нативный WebView для OAuth-авторизации ВК.
//
// package = com.lalune.lalune — тот же, что у MainActivity и Backend.
//
// Цикл:
//   Pass 1: WebView грузит AUTH_URL.
//             - access_token=...     → сохраняем, выходим.
//             - payload=... (silent) → идём на vk.com на 2 сек, потом снова
//                                       на AUTH_URL в ТОМ ЖЕ WebView.
//             - error=...            → сообщаем ошибку.
//   Pass 2: VK видит cookies → показывает "Продолжить как Имя" → access_token.
//   Максимум MAX_SILENT_RESTARTS проходов.

package com.lalune.lalune

import android.annotation.SuppressLint
import android.app.Activity
import android.app.Dialog
import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.drawable.ColorDrawable
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.KeyEvent
import android.view.ViewGroup
import android.view.Window
import android.view.WindowManager
import android.webkit.CookieManager
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.FrameLayout
import android.widget.Toast
import java.net.URLDecoder
import java.util.concurrent.atomic.AtomicBoolean

class VkWebViewFetcher(
    private val activity: Activity,
    private val onSuccess: (String) -> Unit,
    private val onError: (String) -> Unit,
) {
    companion object {
        private const val TAG = "LaLune-VkWebView"

        private const val CLIENT_ID = "7793118"
        private const val SCOPE = "1073737727"
        private const val REDIRECT_URI = "https://oauth.vk.ru/blank.html"

        private const val AUTH_URL =
            "https://oauth.vk.ru/authorize?" +
                "client_id=$CLIENT_ID&" +
                "scope=$SCOPE&" +
                "redirect_uri=" + "https%3A%2F%2Foauth.vk.ru%2Fblank.html" + "&" +
                "display=page&" +
                "response_type=token&" +
                "revoke=1&" +
                "v=5.199"

        private const val VK_DOT_COM_URL = "https://vk.com/"

        private val BLANK_HOSTS = arrayOf("oauth.vk.ru", "oauth.vk.com")
        private const val BLANK_PATH = "/blank.html"

        private const val POLL_INTERVAL_MS = 1000L
        private const val TIMEOUT_MS = 5 * 60 * 1000L
        private const val FIRST_LOAD_TIMEOUT_MS = 15_000L
        private const val VK_DOT_COM_WAIT_MS = 2000L
        private const val MAX_SILENT_RESTARTS = 1
    }

    private var dialog: Dialog? = null
    private var webView: WebView? = null
    private val handler = Handler(Looper.getMainLooper())
    private val finished = AtomicBoolean(false)
    private var pollRunnable: Runnable? = null
    private var firstLoadReceived = false
    private var firstLoadTimeoutRunnable: Runnable? = null
    private var lastLoggedUrl: String = ""
    private var silentRestarts = 0
    private var deadlineMs = 0L
    private var inSilentRecovery = false

    fun start() {
        if (activity.isFinishing ||
            (Build.VERSION.SDK_INT >= Build.VERSION_CODES.JELLY_BEAN_MR1 && activity.isDestroyed)
        ) {
            onError("Activity недоступна")
            return
        }
        deadlineMs = System.currentTimeMillis() + TIMEOUT_MS
        showDialogAndLoad()
    }

    fun cancel() {
        if (!finished.compareAndSet(false, true)) return
        cleanup()
        onError("cancelled")
    }

    private fun showDialogAndLoad() {
        Log.d(TAG, "showDialogAndLoad")

        val d = Dialog(activity)
        d.requestWindowFeature(Window.FEATURE_NO_TITLE)
        val window = d.window
        window?.setBackgroundDrawable(ColorDrawable(Color.WHITE))
        d.setCancelable(true)
        d.setCanceledOnTouchOutside(false)
        d.setOnKeyListener { _, keyCode, event ->
            if (keyCode == KeyEvent.KEYCODE_BACK && event.action == KeyEvent.ACTION_UP) {
                if (!finished.get()) finishWithError("окно закрыто пользователем")
                true
            } else false
        }

        val wv = buildWebView()
        val container = FrameLayout(activity)
        container.layoutParams = FrameLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT,
            ViewGroup.LayoutParams.MATCH_PARENT,
        )
        container.addView(wv)
        d.setContentView(container)

        window?.setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE)

        try {
            d.show()
        } catch (e: Exception) {
            finishWithError("не удалось открыть окно: ${e.message}")
            return
        }

        window?.setLayout(
            ViewGroup.LayoutParams.MATCH_PARENT,
            ViewGroup.LayoutParams.MATCH_PARENT,
        )

        dialog = d
        webView = wv

        firstLoadReceived = false
        lastLoggedUrl = ""
        wv.loadUrl(AUTH_URL)

        schedulePolling()
        scheduleFirstLoadTimeout()
    }

    @SuppressLint("SetJavaScriptEnabled")
    private fun buildWebView(): WebView {
        val wv = WebView(activity)
        wv.setBackgroundColor(Color.WHITE)

        val settings: WebSettings = wv.settings
        settings.javaScriptEnabled = true
        settings.domStorageEnabled = true
        settings.databaseEnabled = true
        settings.loadWithOverviewMode = true
        settings.useWideViewPort = true

        CookieManager.getInstance().setAcceptCookie(true)
        CookieManager.getInstance().setAcceptThirdPartyCookies(wv, true)

        wv.webViewClient = object : WebViewClient() {
            override fun shouldOverrideUrlLoading(view: WebView?, url: String?): Boolean {
                handleUrl(url); return false
            }
            override fun shouldOverrideUrlLoading(
                view: WebView?, request: WebResourceRequest?
            ): Boolean {
                handleUrl(request?.url?.toString()); return false
            }
            override fun onPageStarted(view: WebView?, url: String?, favicon: Bitmap?) {
                firstLoadReceived = true; handleUrl(url)
            }
            override fun onPageFinished(view: WebView?, url: String?) {
                firstLoadReceived = true; handleUrl(url)
            }
            override fun doUpdateVisitedHistory(view: WebView?, url: String?, isReload: Boolean) {
                handleUrl(url)
            }
            override fun onPageCommitVisible(view: WebView?, url: String?) {
                firstLoadReceived = true; handleUrl(url)
            }
            override fun onReceivedError(
                view: WebView?, request: WebResourceRequest?, error: WebResourceError?
            ) {
                Log.e(TAG, "onReceivedError: ${request?.url} -> ${error?.description}")
            }
            override fun onReceivedHttpError(
                view: WebView?, request: WebResourceRequest?, errorResponse: WebResourceResponse?
            ) {
                Log.w(TAG, "onReceivedHttpError: ${request?.url} -> ${errorResponse?.statusCode}")
            }
        }
        return wv
    }

    private fun handleUrl(url: String?) {
        if (finished.get() || url == null) return
        if (System.currentTimeMillis() > deadlineMs) {
            finishWithError("тайм-аут ожидания токена")
            return
        }
        if (inSilentRecovery) {
            logUrl(url)
            return
        }
        logUrl(url)
        if (!isBlankRedirect(url)) return

        val fragment = extractFragment(url) ?: return
        if (fragment.isEmpty()) return

        val token = extractQueryParam(fragment, "access_token")
        if (!token.isNullOrEmpty()) {
            Log.i(TAG, "access_token received (pass=${silentRestarts + 1})")
            finishWithToken(token)
            return
        }

        if (fragment.contains("payload=")) {
            handleSilentToken()
            return
        }

        if (fragment.contains("error=")) {
            var desc = extractQueryParam(fragment, "error_description")
            if (desc.isNullOrEmpty()) desc = extractQueryParam(fragment, "error")
            finishWithError("VK: ${desc ?: "неизвестная ошибка"}")
        }
    }

    private fun handleSilentToken() {
        if (silentRestarts >= MAX_SILENT_RESTARTS) {
            finishWithError("VK вернул silent_token дважды. Войдите заново вручную.")
            return
        }

        silentRestarts++
        inSilentRecovery = true
        Log.i(TAG, "silent_token → visiting vk.com (pass $silentRestarts)")

        try {
            Toast.makeText(
                activity,
                "Получаем токен, подождите...",
                Toast.LENGTH_SHORT,
            ).show()
        } catch (_: Exception) {}

        val wv = webView ?: run {
            finishWithError("WebView потерян")
            return
        }

        wv.loadUrl(VK_DOT_COM_URL)

        handler.postDelayed({
            if (finished.get()) return@postDelayed
            val wv2 = webView ?: return@postDelayed
            inSilentRecovery = false
            wv2.loadUrl(AUTH_URL)
        }, VK_DOT_COM_WAIT_MS)
    }

    private fun isBlankRedirect(url: String): Boolean {
        return try {
            val parsed = Uri.parse(url)
            val host = parsed.host ?: return false
            val hostOk = BLANK_HOSTS.any { it.equals(host, ignoreCase = true) }
            if (!hostOk) return false
            BLANK_PATH.equals(parsed.path, ignoreCase = true)
        } catch (_: Exception) { false }
    }

    private fun extractFragment(url: String): String? {
        val hash = url.indexOf('#')
        if (hash >= 0) return url.substring(hash + 1)
        val q = url.indexOf('?')
        if (q >= 0) return url.substring(q + 1)
        return null
    }

    private fun extractQueryParam(query: String, key: String): String? {
        var q = query
        if (q.startsWith("#") || q.startsWith("?")) q = q.substring(1)
        for (pair in q.split("&")) {
            if (pair.isEmpty()) continue
            val eq = pair.indexOf('=')
            if (eq <= 0) continue
            val k = pair.substring(0, eq)
            if (k != key) continue
            val v = pair.substring(eq + 1)
            return try { URLDecoder.decode(v, "UTF-8") } catch (_: Exception) { v }
        }
        return null
    }

    private fun schedulePolling() {
        pollRunnable?.let { handler.removeCallbacks(it) }
        val r = object : Runnable {
            override fun run() {
                if (finished.get()) return
                val wv = webView ?: return
                wv.url?.let { handleUrl(it) }
                if (!finished.get() && webView == wv) {
                    handler.postDelayed(this, POLL_INTERVAL_MS)
                }
            }
        }
        pollRunnable = r
        handler.postDelayed(r, POLL_INTERVAL_MS)
    }

    private fun scheduleFirstLoadTimeout() {
        firstLoadTimeoutRunnable?.let { handler.removeCallbacks(it) }
        val r = Runnable {
            if (finished.get()) return@Runnable
            if (!firstLoadReceived) {
                try {
                    Toast.makeText(
                        activity,
                        "WebView не загрузился. Проверьте интернет.",
                        Toast.LENGTH_LONG,
                    ).show()
                } catch (_: Exception) {}
                finishWithError("страница авторизации не загрузилась")
            }
        }
        firstLoadTimeoutRunnable = r
        handler.postDelayed(r, FIRST_LOAD_TIMEOUT_MS)
    }

    private fun logUrl(url: String) {
        if (url == lastLoggedUrl) return
        lastLoggedUrl = url
        Log.i(TAG, "[VK] URL: $url")
    }

    private fun finishWithToken(token: String) {
        if (!finished.compareAndSet(false, true)) return
        cleanup()
        handler.post { onSuccess(token) }
    }

    private fun finishWithError(message: String) {
        if (!finished.compareAndSet(false, true)) return
        cleanup()
        handler.post { onError(message) }
    }

    private fun cleanup() {
        pollRunnable?.let { handler.removeCallbacks(it) }
        pollRunnable = null
        firstLoadTimeoutRunnable?.let { handler.removeCallbacks(it) }
        firstLoadTimeoutRunnable = null

        webView?.let { wv ->
            try {
                wv.stopLoading()
                wv.loadUrl("about:blank")
                wv.removeAllViews()
                wv.destroy()
            } catch (_: Exception) {}
        }
        webView = null

        dialog?.let { d ->
            try { if (d.isShowing) d.dismiss() } catch (_: Exception) {}
        }
        dialog = null
    }
}
