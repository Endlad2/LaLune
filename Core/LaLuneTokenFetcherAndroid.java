package com.lalune.app;

import android.annotation.SuppressLint;
import android.app.Activity;
import android.app.Dialog;
import android.content.Context;
import android.graphics.Bitmap;
import android.graphics.Color;
import android.graphics.drawable.ColorDrawable;
import android.net.Uri;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.util.Log;
import android.view.KeyEvent;
import android.view.View;
import android.view.ViewGroup;
import android.view.Window;
import android.view.WindowManager;
import android.webkit.CookieManager;
import android.webkit.WebResourceError;
import android.webkit.WebResourceRequest;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.FrameLayout;
import android.widget.Toast;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;

import java.util.concurrent.atomic.AtomicBoolean;

/**
 * LaLuneTokenFetcherAndroid — открывает WebView с OAuth ВК и возвращает
 * access_token через Callback.
 *
 * Диагностика: логирует каждый шаг — создание диалога, показ, размеры окна,
 * загрузку URL, ошибки сети. Если WebView не появился — в логах будет видно,
 * на каком шаге всё встало.
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

    private static final long POLL_INTERVAL_MS = 1000L;
    private static final long TIMEOUT_MS = 5 * 60 * 1000L;
    /** Если за это время не пришло ни onPageStarted, ни onPageFinished — считаем, что WebView не открылся. */
    private static final long FIRST_LOAD_TIMEOUT_MS = 15_000L;

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

    public static void fetchToken(@NonNull Activity activity, @NonNull Callback callback) {
        if (Looper.myLooper() != Looper.getMainLooper()) {
            throw new IllegalStateException(
                    "fetchToken() must be called from the main (UI) thread");
        }
        new Session(activity, callback).start();
    }

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
        private Runnable firstLoadTimeoutRunnable;

        private final AtomicBoolean finished = new AtomicBoolean(false);
        private volatile boolean closingByUs = false;
        private volatile boolean firstLoadReceived = false;
        private String lastLoggedUrl = "";

        Session(Activity activity, Callback callback) {
            this.activity = activity;
            this.callback = callback;
        }

        void start() {
            handler = new Handler(Looper.getMainLooper());

            if (activity.isFinishing()) {
                Log.e(TAG, "Activity is finishing — abort");
                callback.onError("Activity is finishing");
                return;
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.JELLY_BEAN_MR1
                    && activity.isDestroyed()) {
                Log.e(TAG, "Activity is destroyed — abort");
                callback.onError("Activity is destroyed");
                return;
            }

            Log.d(TAG, "start(): creating dialog");

            dialog = new Dialog(activity);
            dialog.requestWindowFeature(Window.FEATURE_NO_TITLE);

            Window window = dialog.getWindow();
            if (window != null) {
                window.setBackgroundDrawable(new ColorDrawable(Color.WHITE));
                // setLayout здесь не сработает на всех устройствах — сделаем
                // это ПОСЛЕ show() через post().
            }

            dialog.setCancelable(true);
            dialog.setCanceledOnTouchOutside(false);

            // Игнорируем onCancel — обрабатываем явный back в onKeyListener.
            dialog.setOnCancelListener(d ->
                    Log.d(TAG, "onCancel (ignored)"));

            dialog.setOnKeyListener((d, keyCode, event) -> {
                if (keyCode == KeyEvent.KEYCODE_BACK
                        && event.getAction() == KeyEvent.ACTION_UP) {
                    if (!finished.get()) {
                        Log.d(TAG, "Back pressed — user cancelled");
                        finishWithError("окно закрыто пользователем");
                    }
                    return true;
                }
                return false;
            });

            dialog.setOnDismissListener(d ->
                    Log.d(TAG, "onDismiss (closingByUs=" + closingByUs + ")"));

            Log.d(TAG, "buildWebView()");
            webView = buildWebView(activity);

            FrameLayout container = new FrameLayout(activity);
            container.setLayoutParams(new FrameLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT,
                    ViewGroup.LayoutParams.MATCH_PARENT));
            container.addView(webView);
            dialog.setContentView(container);

            if (window != null) {
                window.setSoftInputMode(
                        WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE);
            }

            try {
                dialog.show();
                Log.d(TAG, "dialog.show() OK, isShowing=" + dialog.isShowing());
            } catch (Exception e) {
                Log.e(TAG, "dialog.show() failed: " + e.getMessage(), e);
                finishWithError("не удалось открыть окно: " + e.getMessage());
                return;
            }

            // Применяем размеры ПОСЛЕ show().
            if (window != null) {
                window.setLayout(
                        ViewGroup.LayoutParams.MATCH_PARENT,
                        ViewGroup.LayoutParams.MATCH_PARENT);
            }

            // Ещё раз — на случай, если активити была не foreground.
            dialog.getWindow().getDecorView().post(() -> {
                if (dialog != null && dialog.isShowing()) {
                    Window w = dialog.getWindow();
                    if (w != null) {
                        w.setLayout(
                                ViewGroup.LayoutParams.MATCH_PARENT,
                                ViewGroup.LayoutParams.MATCH_PARENT);
                    }
                    Log.d(TAG, "post(): sizes applied, decor=" +
                            dialog.getWindow().getDecorView().getWidth() + "x" +
                            dialog.getWindow().getDecorView().getHeight());
                }
            });

            Log.d(TAG, "loadUrl: " + AUTH_URL);
            webView.loadUrl(AUTH_URL);

            schedulePolling();
            scheduleTimeout();
            scheduleFirstLoadTimeout();
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
                    firstLoadReceived = true;
                    Log.d(TAG, "onPageStarted: " + url);
                    tryCompleteFromUrl(url, "onPageStarted");
                }

                @Override
                public void onPageFinished(WebView wv, String url) {
                    firstLoadReceived = true;
                    Log.d(TAG, "onPageFinished: " + url);
                    tryCompleteFromUrl(url, "onPageFinished");
                }

                @Override
                public void onReceivedError(WebView wv, WebResourceRequest request,
                                            WebResourceError error) {
                    Log.e(TAG, "onReceivedError: " + request.getUrl() + " -> " +
                            error.getDescription());
                }

                @Override
                public void onReceivedHttpError(WebView wv, WebResourceRequest request,
                                                android.webkit.WebResourceResponse response) {
                    Log.w(TAG, "onReceivedHttpError: " + request.getUrl() +
                            " -> " + response.getStatusCode());
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

        private void scheduleFirstLoadTimeout() {
            firstLoadTimeoutRunnable = () -> {
                if (finished.get()) return;
                if (!firstLoadReceived) {
                    Log.e(TAG, "WebView did not load anything in " +
                            FIRST_LOAD_TIMEOUT_MS + "ms");
                    // Показываем тост — юзер поймёт, что что-то не так.
                    try {
                        Toast.makeText(activity,
                                "WebView не загрузился. Проверьте интернет.",
                                Toast.LENGTH_LONG).show();
                    } catch (Exception ignored) {}
                    finishWithError("страница авторизации не загрузилась");
                }
            };
            handler.postDelayed(firstLoadTimeoutRunnable, FIRST_LOAD_TIMEOUT_MS);
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
            closingByUs = true;
            cleanup();
            handler.post(() -> callback.onSuccess(token));
        }

        private void finishWithError(@NonNull String message) {
            if (!finished.compareAndSet(false, true)) return;
            closingByUs = true;
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
            if (firstLoadTimeoutRunnable != null) {
                handler.removeCallbacks(firstLoadTimeoutRunnable);
                firstLoadTimeoutRunnable = null;
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