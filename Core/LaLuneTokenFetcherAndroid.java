package com.lalune.app;

import android.annotation.SuppressLint;
import android.app.Activity;
import android.app.Dialog;
import android.graphics.Color;
import android.graphics.drawable.ColorDrawable;
import android.net.Uri;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.util.Log;
import android.view.KeyEvent;
import android.view.ViewGroup;
import android.view.Window;
import android.view.WindowManager;
import android.webkit.CookieManager;
import android.webkit.WebResourceError;
import android.webkit.WebResourceRequest;
import android.webkit.WebResourceResponse;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.FrameLayout;
import android.widget.Toast;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;

import java.net.URLDecoder;
import java.util.HashMap;
import java.util.Map;
import java.util.concurrent.atomic.AtomicBoolean;

/**
 * LaLuneTokenFetcherAndroid — открывает WebView с OAuth ВК и возвращает
 * вечный access_token через Callback.
 *
 * Флоу «двойного прохода» (порт поведения Desktop-версии LaLuneTokenFetcher):
 *
 *   Проход 1:
 *     WebView грузит https://oauth.vk.ru/authorize?...&response_type=token.
 *     VK логинит и редиректит на blank.html.
 *       - Если фрагмент содержит #access_token=... — сохраняем сразу.
 *       - Если фрагмент содержит #payload=... (silent_token, TTL 600s) —
 *         это НЕ то, что нам нужно. Закрываем окно, показываем тост
 *         «Получаем токен, подождите...» и СРАЗУ открываем новое окно
 *         с тем же URL.
 *
 *   Проход 2:
 *     VK уже знает, что юзер залогинен (cookies сохранены), показывает
 *     экран «Выберите аккаунт» → после выбора возвращает
 *     #access_token=... — вечный токен. Сохраняем.
 *
 *   Если и на втором проходе пришёл silent_token — показываем ошибку
 *   и ждём действий юзера (юзер может нажать «Войти» заново вручную).
 */
public final class LaLuneTokenFetcherAndroid {

    private static final String TAG = "LaLuneTokenFetcher";

    private static final String CLIENT_ID = "7793118";
    private static final String SCOPE = "1073737727";
    private static final String REDIRECT_URI = "https://oauth.vk.ru/blank.html";

    /**
     * URL страницы авторизации. Порядок параметров сохранён как в Desktop-версии
     * (VkAuthConstants.AuthUrl) — это важно, VK иногда чувствителен к порядку.
     */
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
    private static final long FIRST_LOAD_TIMEOUT_MS = 15_000L;

    /** Задержка перед авто-перезапуском WebView (чтобы юзер увидел тост). */
    private static final long RESTART_DELAY_MS = 1500L;

    /**
     * Десктопный UA — как в Desktop/Libs/update.go.
     */
    private static final String DESKTOP_UA =
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) " +
            "AppleWebKit/537.36 (KHTML, like Gecko) " +
            "Chrome/120.0.0.0 Safari/537.36";

    private LaLuneTokenFetcherAndroid() {}

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

    // ---------------------------------------------------------------------
    //  Session
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
        private volatile String lastLoggedUrl = "";

        /**
         * 0 = ещё не было silent_token,
         * 1 = первый silent_token получен, сейчас идёт второй проход.
         */
        private volatile int pass = 0;

        Session(Activity activity, Callback callback) {
            this.activity = activity;
            this.callback = callback;
        }

        void start() {
            handler = new Handler(Looper.getMainLooper());

            if (activity.isFinishing()
                    || (Build.VERSION.SDK_INT >= Build.VERSION_CODES.JELLY_BEAN_MR1
                        && activity.isDestroyed())) {
                callback.onError("Activity недоступна");
                return;
            }

            showDialogAndLoad();
            scheduleTimeout();
        }

        private void showDialogAndLoad() {
            Log.d(TAG, "showDialogAndLoad(): pass=" + pass);

            dialog = new Dialog(activity);
            dialog.requestWindowFeature(Window.FEATURE_NO_TITLE);
            Window window = dialog.getWindow();
            if (window != null) {
                window.setBackgroundDrawable(new ColorDrawable(Color.WHITE));
            }
            dialog.setCancelable(true);
            dialog.setCanceledOnTouchOutside(false);
            dialog.setOnCancelListener(d -> Log.d(TAG, "onCancel (ignored)"));
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
                Log.d(TAG, "dialog.show() OK (pass=" + pass + ")");
            } catch (Exception e) {
                Log.e(TAG, "dialog.show() failed: " + e.getMessage(), e);
                finishWithError("не удалось открыть окно: " + e.getMessage());
                return;
            }

            if (window != null) {
                window.setLayout(
                        ViewGroup.LayoutParams.MATCH_PARENT,
                        ViewGroup.LayoutParams.MATCH_PARENT);
            }

            Log.d(TAG, "loadUrl: " + AUTH_URL);
            firstLoadReceived = false;
            webView.loadUrl(AUTH_URL);

            schedulePolling();
            scheduleFirstLoadTimeout();
        }

        @SuppressLint("SetJavaScriptEnabled")
        private WebView buildWebView(Activity activity) {
            WebView view = new WebView(activity);
            view.setBackgroundColor(Color.WHITE);

            WebSettings settings = view.getSettings();
            settings.setJavaScriptEnabled(true);
            settings.setDomStorageEnabled(true);
            settings.setDatabaseEnabled(true);
            settings.setLoadWithOverviewMode(true);
            settings.setUseWideViewPort(true);
            settings.setUserAgentString(DESKTOP_UA);

            CookieManager.getInstance().setAcceptCookie(true);
            CookieManager.getInstance().setAcceptThirdPartyCookies(view, true);

            view.setWebViewClient(new WebViewClient() {
                @Override
                public boolean shouldOverrideUrlLoading(WebView wv, String url) {
                    handleUrl(url);
                    return false;
                }

                @Override
                public boolean shouldOverrideUrlLoading(WebView wv, WebResourceRequest request) {
                    handleUrl(request.getUrl().toString());
                    return false;
                }

                @Override
                public void onPageStarted(WebView wv, String url, android.graphics.Bitmap favicon) {
                    firstLoadReceived = true;
                    Log.d(TAG, "onPageStarted: " + url);
                    handleUrl(url);
                }

                @Override
                public void onPageFinished(WebView wv, String url) {
                    firstLoadReceived = true;
                    Log.d(TAG, "onPageFinished: " + url);
                    handleUrl(url);
                }

                @Override
                public void doUpdateVisitedHistory(WebView wv, String url, boolean isReload) {
                    handleUrl(url);
                }

                @Override
                public void onPageCommitVisible(WebView wv, String url) {
                    firstLoadReceived = true;
                    handleUrl(url);
                }

                @Override
                public void onReceivedError(WebView wv, WebResourceRequest request,
                                            WebResourceError error) {
                    Log.e(TAG, "onReceivedError: " + request.getUrl() + " -> " +
                            error.getDescription());
                }

                @Override
                public void onReceivedHttpError(WebView wv, WebResourceRequest request,
                                                WebResourceResponse response) {
                    Log.w(TAG, "onReceivedHttpError: " + request.getUrl() +
                            " -> " + response.getStatusCode());
                }
            });

            return view;
        }

        // -----------------------------------------------------------------
        //  Обработка URL
        // -----------------------------------------------------------------

        private void handleUrl(@Nullable String url) {
            if (finished.get() || url == null) return;
            logUrl(url);

            if (!isBlankRedirect(url)) return;

            String fragment = extractFragment(url);
            if (fragment == null || fragment.isEmpty()) return;

            // --- Случай 1: настоящий access_token ---
            String token = extractAccessToken(url);
            if (token != null && !token.isEmpty()) {
                Log.i(TAG, "access_token received (pass=" + pass + ") ✓");
                finishWithToken(token);
                return;
            }

            // --- Случай 2: silent_token (payload=...) ---
            if (fragment.contains("payload=")) {
                if (pass == 0) {
                    Log.w(TAG, "silent_token received on pass 1 — auto-restart");
                    pass = 1;

                    // Тост: «Получаем токен, подождите...»
                    try {
                        Toast.makeText(activity,
                                "Получаем токен, подождите...",
                                Toast.LENGTH_SHORT).show();
                    } catch (Exception ignored) {}

                    // Закрываем текущее окно и через небольшую паузу открываем новое.
                    closeCurrentDialog();
                    handler.postDelayed(() -> {
                        if (!finished.get()) showDialogAndLoad();
                    }, RESTART_DELAY_MS);
                } else {
                    // Второй раз тоже silent_token — сдаёмся.
                    Log.e(TAG, "silent_token received on pass 2 — giving up");
                    finishWithError(
                            "VK не выдал вечный токен. Нажмите «Войти» и попробуйте снова");
                }
                return;
            }

            // --- Случай 3: ошибка OAuth ---
            if (fragment.contains("error=")) {
                String desc = extractQueryParam(fragment, "error_description");
                if (desc == null) desc = extractQueryParam(fragment, "error");
                finishWithError("VK: " + (desc != null ? desc : "неизвестная ошибка"));
            }
        }

        /** Закрывает текущий диалог и WebView, не завершая сессию. */
        private void closeCurrentDialog() {
            if (webView != null) {
                try {
                    webView.stopLoading();
                    webView.loadUrl("about:blank");
                    webView.removeAllViews();
                    webView.destroy();
                } catch (Exception ignored) {}
                webView = null;
            }
            if (dialog != null) {
                try {
                    if (dialog.isShowing()) dialog.dismiss();
                } catch (Exception ignored) {}
                dialog = null;
            }
            // Сбрасываем поллинг на старый webView.
            if (pollRunnable != null) {
                handler.removeCallbacks(pollRunnable);
                pollRunnable = null;
            }
            if (firstLoadTimeoutRunnable != null) {
                handler.removeCallbacks(firstLoadTimeoutRunnable);
                firstLoadTimeoutRunnable = null;
            }
        }

        private static boolean isBlankRedirect(String url) {
            if (url == null) return false;
            Uri parsed;
            try {
                parsed = Uri.parse(url);
            } catch (Exception e) {
                return false;
            }
            String host = parsed.getHost();
            if (host == null) return false;
            boolean hostOk = false;
            for (String h : BLANK_HOSTS) {
                if (h.equalsIgnoreCase(host)) { hostOk = true; break; }
            }
            if (!hostOk) return false;
            return BLANK_PATH.equalsIgnoreCase(parsed.getPath());
        }

        @Nullable
        private static String extractFragment(String url) {
            int hash = url.indexOf('#');
            if (hash >= 0) return url.substring(hash + 1);
            int q = url.indexOf('?');
            if (q >= 0) return url.substring(q + 1);
            return null;
        }

        @Nullable
        private static String extractAccessToken(String url) {
            String fragment = extractFragment(url);
            if (fragment == null) return null;
            String token = extractQueryParam(fragment, "access_token");
            if (token == null || token.isEmpty()) return null;
            return token;
        }

        @Nullable
        private static String extractQueryParam(String query, String key) {
            if (query == null) return null;
            if (query.startsWith("#") || query.startsWith("?")) {
                query = query.substring(1);
            }
            for (String pair : query.split("&")) {
                if (pair.isEmpty()) continue;
                int eq = pair.indexOf('=');
                if (eq <= 0) continue;
                String k = pair.substring(0, eq);
                if (!k.equals(key)) continue;
                String v = pair.substring(eq + 1);
                try {
                    return URLDecoder.decode(v, "UTF-8");
                } catch (Exception e) {
                    return v;
                }
            }
            return null;
        }

        // -----------------------------------------------------------------
        //  Поллинг / таймеры
        // -----------------------------------------------------------------

        private void schedulePolling() {
            if (pollRunnable != null) {
                handler.removeCallbacks(pollRunnable);
            }
            pollRunnable = new Runnable() {
                @Override
                public void run() {
                    if (finished.get()) return;
                    WebView wv = webView;
                    if (wv == null) return;
                    String url = wv.getUrl();
                    if (url != null) handleUrl(url);
                    if (!finished.get() && webView == wv) {
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
            if (firstLoadTimeoutRunnable != null) {
                handler.removeCallbacks(firstLoadTimeoutRunnable);
            }
            firstLoadTimeoutRunnable = () -> {
                if (finished.get()) return;
                if (!firstLoadReceived) {
                    Log.e(TAG, "WebView did not load anything in "
                            + FIRST_LOAD_TIMEOUT_MS + "ms");
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
                } catch (Exception ignored) {}
                webView = null;
            }
            if (dialog != null) {
                try {
                    if (dialog.isShowing()) dialog.dismiss();
                } catch (Exception ignored) {}
                dialog = null;
            }
        }
    }
}