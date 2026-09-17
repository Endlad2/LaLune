package com.lalune.app;

import android.annotation.SuppressLint;
import android.app.Activity;
import android.app.Dialog;
import android.content.Context;
import android.graphics.Bitmap;
import android.graphics.Color;
import android.graphics.drawable.ColorDrawable;
import android.net.Uri;
import android.os.Handler;
import android.os.Looper;
import android.util.Log;
import android.view.ViewGroup;
import android.view.Window;
import android.webkit.CookieManager;
import android.webkit.WebResourceRequest;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.FrameLayout;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;

import java.util.concurrent.atomic.AtomicBoolean;

/**
 * LaLuneTokenFetcherAndroid — открывает WebView с OAuth ВК и возвращает
 * access_token через Callback.
 *
 * Использование из MainActivity:
 *   LaLuneTokenFetcherAndroid.fetchToken(activity, new Callback() {
 *       public void onSuccess(String token) { ... }
 *       public void onError(String message) { ... }
 *   });
 *
 * Параметры авторизации (client_id, scope, redirect_uri) — точные копии
 * из Windows/Linux-версии и из Flutter-приложения FOCSQ.
 */
public final class LaLuneTokenFetcherAndroid {

    private static final String TAG = "LaLuneTokenFetcher";

    private static final String CLIENT_ID = "7793118";
    private static final String SCOPE = "1073737727";
    private static final String REDIRECT_URI = "https://oauth.vk.ru/blank.html";
    private static final String AUTH_URL =
            "https://oauth.vk.ru/authorize?" +
            "client_id=" + CLIENT_ID + "&" +
            "scope=" + SCOPE + "&" +
            "redirect_uri=" + Uri.encode(REDIRECT_URI) + "&" +
            "display=page&" +
            "response_type=token&" +
            "revoke=1&" +
            "v=5.199";

    private static final String[] BLANK_HOSTS = {"oauth.vk.ru", "oauth.vk.com"};
    private static final String BLANK_PATH = "/blank.html";

    private static final long POLL_INTERVAL_MS = 3000L;
    private static final long TIMEOUT_MS = 5 * 60 * 1000L;

    private LaLuneTokenFetcherAndroid() {
        // утилитный класс
    }

    // ---------------------------------------------------------------------
    //  Публичный API
    // ---------------------------------------------------------------------

    public interface Callback {
        void onSuccess(@NonNull String token);
        void onError(@NonNull String message);
    }

    /**
     * Открывает WebView с авторизацией VK и вызывает callback при получении
     * токена или ошибке. Должен вызываться из UI-потока.
     */
    public static void fetchToken(@NonNull Activity activity, @NonNull Callback callback) {
        if (Looper.myLooper() != Looper.getMainLooper()) {
            throw new IllegalStateException(
                    "fetchToken() must be called from the main (UI) thread");
        }
        new Session(activity, callback).start();
    }

    /**
     * Извлекает access_token из URL редиректа VK.
     */
    @Nullable
    public static String extractAccessToken(@Nullable String url) {
        if (url == null || url.isEmpty()) return null;

        Uri parsed = Uri.parse(url);
        String host = parsed.getHost();
        if (host == null) return null;

        boolean hostOk = false;
        for (String h : BLANK_HOSTS) {
            if (h.equalsIgnoreCase(host)) { hostOk = true; break; }
        }
        if (!hostOk) return null;
        if (!BLANK_PATH.equalsIgnoreCase(parsed.getPath())) return null;

        String fragment = parsed.getFragment();
        if (fragment == null) return null;

        String token = extractQueryParam(fragment, "access_token");
        return (token == null || token.isEmpty()) ? null : token;
    }

    // ---------------------------------------------------------------------
    //  Внутренняя реализация
    // ---------------------------------------------------------------------

    private static final class Session {
        private final Activity activity;
        private final Callback callback;

        private Dialog dialog;
        private WebView webView;
        private Handler handler;

        private Runnable pollRunnable;
        private Runnable timeoutRunnable;

        private final AtomicBoolean finished = new AtomicBoolean(false);
        private String lastLoggedUrl = "";

        Session(Activity activity, Callback callback) {
            this.activity = activity;
            this.callback = callback;
        }

        void start() {
            handler = new Handler(Looper.getMainLooper());

            dialog = new Dialog(activity);
            dialog.requestWindowFeature(Window.FEATURE_NO_TITLE);
            Window window = dialog.getWindow();
            if (window != null) {
                window.setBackgroundDrawable(new ColorDrawable(Color.WHITE));
            }
            dialog.setCancelable(true);
            dialog.setCanceledOnTouchOutside(false);
            dialog.setOnCancelListener(d -> finishWithError("окно закрыто пользователем"));

            webView = buildWebView(activity);

            FrameLayout container = new FrameLayout(activity);
            container.setLayoutParams(new FrameLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT,
                    ViewGroup.LayoutParams.MATCH_PARENT));
            container.addView(webView);
            dialog.setContentView(container);

            dialog.show();

            webView.loadUrl(AUTH_URL);

            schedulePolling();
            scheduleTimeout();
        }

        @SuppressLint("SetJavaScriptEnabled")
        private WebView buildWebView(Context context) {
            WebView view = new WebView(context);

            WebSettings settings = view.getSettings();
            settings.setJavaScriptEnabled(true);
            settings.setDomStorageEnabled(true);
            settings.setDatabaseEnabled(true);
            settings.setLoadWithOverviewMode(true);
            settings.setUseWideViewPort(true);
            settings.setUserAgentString(
                    settings.getUserAgentString().replace("; wv", ""));

            CookieManager.getInstance().setAcceptCookie(true);
            CookieManager.getInstance().setAcceptThirdPartyCookies(view, true);

            view.setWebViewClient(new WebViewClient() {
                @Override
                public boolean shouldOverrideUrlLoading(WebView wv, String url) {
                    tryCompleteFromUrl(url, "shouldOverrideUrlLoading");
                    return false;
                }

                @Override
                public boolean shouldOverrideUrlLoading(WebView wv, WebResourceRequest request) {
                    tryCompleteFromUrl(request.getUrl().toString(),
                            "shouldOverrideUrlLoading(request)");
                    return false;
                }

                @Override
                public void onPageStarted(WebView wv, String url, Bitmap favicon) {
                    tryCompleteFromUrl(url, "onPageStarted");
                }

                @Override
                public void onPageFinished(WebView wv, String url) {
                    tryCompleteFromUrl(url, "onPageFinished");
                }
            });

            return view;
        }

        private void schedulePolling() {
            pollRunnable = new Runnable() {
                @Override
                public void run() {
                    if (finished.get()) return;
                    String url = (webView != null) ? webView.getUrl() : null;
                    logUrl(url);
                    tryCompleteFromUrl(url, "poll");
                    if (!finished.get()) {
                        handler.postDelayed(this, POLL_INTERVAL_MS);
                    }
                }
            };
            handler.postDelayed(pollRunnable, POLL_INTERVAL_MS);
        }

        private void scheduleTimeout() {
            timeoutRunnable = () -> finishWithError("тайм-аут ожидания токена");
            handler.postDelayed(timeoutRunnable, TIMEOUT_MS);
        }

        private void logUrl(String url) {
            if (url == null || url.equals(lastLoggedUrl)) return;
            lastLoggedUrl = url;
            Log.i(TAG, "[LaLune] URL: " + url);
        }

        private void tryCompleteFromUrl(@Nullable String url, String source) {
            if (url == null || finished.get()) return;
            logUrl(url);

            String token = extractAccessToken(url);
            if (token == null) return;

            Log.i(TAG, "[LaLune] Токен получен (" + source + "), закрываю окно.");
            finishWithToken(token);
        }

        private void finishWithToken(@NonNull String token) {
            if (!finished.compareAndSet(false, true)) return;
            cleanup();
            handler.post(() -> callback.onSuccess(token));
        }

        private void finishWithError(@NonNull String message) {
            if (!finished.compareAndSet(false, true)) return;
            cleanup();
            handler.post(() -> callback.onError(message));
        }

        private void cleanup() {
            if (pollRunnable != null) {
                handler.removeCallbacks(pollRunnable);
                pollRunnable = null;
            }
            if (timeoutRunnable != null) {
                handler.removeCallbacks(timeoutRunnable);
                timeoutRunnable = null;
            }
            if (webView != null) {
                try {
                    webView.stopLoading();
                    webView.loadUrl("about:blank");
                    webView.removeAllViews();
                    webView.destroy();
                } catch (Exception ignored) {
                }
                webView = null;
            }
            if (dialog != null) {
                try {
                    if (dialog.isShowing()) dialog.dismiss();
                } catch (Exception ignored) {
                }
                dialog = null;
            }
        }
    }

    // ---------------------------------------------------------------------
    //  Утилиты
    // ---------------------------------------------------------------------

    @Nullable
    private static String extractQueryParam(@NonNull String query, @NonNull String key) {
        String q = query.startsWith("?") || query.startsWith("#")
                ? query.substring(1)
                : query;

        for (String pair : q.split("&")) {
            if (pair.isEmpty()) continue;
            int eq = pair.indexOf('=');
            if (eq <= 0) continue;
            String k = pair.substring(0, eq);
            if (!k.equals(key)) continue;
            String v = pair.substring(eq + 1);
            return Uri.decode(v);
        }
        return null;
    }
}
