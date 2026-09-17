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

import java.io.BufferedReader;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.net.HttpURLConnection;
import java.net.URL;
import java.net.URLDecoder;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * LaLuneTokenFetcherAndroid — открывает WebView с OAuth ВК и возвращает
 * вечный access_token через Callback.
 *
 * Флоу (порт логики CSQTT VkAuthWebViewManager + VkTokenScraper):
 *
 *   1. Открываем WebView на https://vk.ru/. Юзер логинится.
 *   2. Как только видим, что юзер залогинен (URL содержит /feed, /im, /messages
 *      или есть cookie remixsid), запускаем HTTP-скрапер.
 *   3. Скрапер собирает cookies со всех VK-доменов и делает GET на
 *      oauth.vk.com/authorize?...&response_type=token.
 *   4. Вручную обходим до 15 редиректов, вытаскивая access_token из фрагмента
 *      или из location.href = "..." в HTML.
 *   5. Возвращаем вечный access_token (expires_in=0) через Callback.
 *
 * silent_token (VK ID flow) НЕ обрабатываем — у него TTL 600 секунд.
 */
public final class LaLuneTokenFetcherAndroid {

    private static final String TAG = "LaLuneTokenFetcher";

    // --- OAuth-параметры VK (те же, что у CSQTT и у Desktop-версии) ---
    private static final String CLIENT_ID = "7793118";
    private static final String SCOPE = "1073737727";
    private static final String REDIRECT_URI = "https://oauth.vk.ru/blank.html";

    /** URL, с которого стартует WebView (логин). */
    private static final String VK_LOGIN_URL = "https://vk.ru/";

    /** URL, с которого стартует HTTP-скрапер (как у CSQTT). */
    private static final String SCRAPER_AUTH_URL =
            "https://oauth.vk.com/authorize?" +
            "client_id=" + CLIENT_ID + "&" +
            "display=mobile&" +
            "redirect_uri=" + Uri.encode(REDIRECT_URI) + "&" +
            "response_type=token&" +
            "scope=" + SCOPE + "&" +
            "v=5.199&" +
            "revoke=1";

    /** Домены, с которых собираем cookies перед скрапингом. */
    private static final String[] COOKIE_DOMAINS = {
            "https://vk.com/",
            "https://vk.ru/",
            "https://id.vk.ru/",
            "https://id.vk.com/",
            "https://login.vk.com/",
            "https://login.vk.ru/",
            "https://m.vk.com/",
            "https://m.vk.ru/",
    };

    private static final int MAX_OAUTH_HOPS = 15;
    private static final long POLL_INTERVAL_MS = 1000L;
    private static final long TIMEOUT_MS = 5 * 60 * 1000L;
    private static final long FIRST_LOAD_TIMEOUT_MS = 15_000L;

    /** Как у CSQTT — мобильный UA. */
    private static final String MOBILE_UA =
            "Mozilla/5.0 (Linux; Android 13; Mobile) " +
            "AppleWebKit/537.36 (KHTML, like Gecko) " +
            "Chrome/120.0.0.0 Mobile Safari/537.36";

    private LaLuneTokenFetcherAndroid() {}

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
        private volatile boolean scrapeStarted = false;
        private volatile boolean nonPermanentRetried = false;
        private String lastLoggedUrl = "";

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

            Log.d(TAG, "start(): creating dialog");

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
                Log.d(TAG, "dialog.show() OK");
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

            Log.d(TAG, "loadUrl: " + VK_LOGIN_URL);
            webView.loadUrl(VK_LOGIN_URL);

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
            settings.setUserAgentString(MOBILE_UA);

            CookieManager.getInstance().setAcceptCookie(true);
            CookieManager.getInstance().setAcceptThirdPartyCookies(view, true);

            view.setWebViewClient(new WebViewClient() {
                @Override
                public void onPageStarted(WebView wv, String url, Bitmap favicon) {
                    firstLoadReceived = true;
                    Log.d(TAG, "onPageStarted: " + url);
                }

                @Override
                public void onPageFinished(WebView wv, String url) {
                    firstLoadReceived = true;
                    Log.d(TAG, "onPageFinished: " + url);
                    logUrl(url);
                    maybeStartScraper(url);
                }

                @Override
                public void doUpdateVisitedHistory(WebView wv, String url, boolean isReload) {
                    logUrl(url);
                    maybeStartScraper(url);
                }

                @Override
                public void onPageCommitVisible(WebView wv, String url) {
                    firstLoadReceived = true;
                    logUrl(url);
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

        /** Проверяет, залогинен ли юзер, и запускает скрапер. */
        private void maybeStartScraper(@Nullable String url) {
            if (finished.get() || scrapeStarted) return;
            if (url == null) return;

            boolean loggedIn = isVkLoggedInByCookies()
                    || url.contains("/feed")
                    || url.contains("/im")
                    || url.contains("/messages")
                    || url.contains("/al_feed")
                    || (url.startsWith("https://vk.ru/") && url.length() < 40)
                    || (url.startsWith("https://vk.com/") && url.length() < 40);

            if (!loggedIn) return;

            scrapeStarted = true;
            Log.i(TAG, "User is logged in — starting HTTP scraper");

            // Собираем cookies и запускаем скрапер в фоне.
            final String cookies = collectCookies();
            Log.d(TAG, "Cookies collected, length=" + cookies.length());

            new Thread(() -> {
                ScrapeResult result = scrapeAccessToken(cookies, MOBILE_UA);
                handler.post(() -> {
                    if (finished.get()) return;

                    if (result.token != null && !result.token.isEmpty()) {
                        if (result.expiresIn == 0L) {
                            Log.i(TAG, "Permanent access_token received ✓");
                            finishWithToken(result.token);
                        } else if (!nonPermanentRetried) {
                            nonPermanentRetried = true;
                            scrapeStarted = false;
                            Log.w(TAG, "Non-permanent token (expires_in=" +
                                    result.expiresIn + "), retrying scraper once");
                            // Дадим WebView загрузиться заново и попробуем ещё раз.
                            maybeStartScraper(url);
                        } else {
                            finishWithError(
                                    "VK выдал токен с ограниченным сроком действия");
                        }
                    } else {
                        Log.e(TAG, "Scraper failed: " + result.error);
                        // Не падаем сразу — дадим ещё шанс, когда URL обновится.
                        scrapeStarted = false;
                    }
                });
            }, "vk-token-scraper").start();
        }

        private boolean isVkLoggedInByCookies() {
            CookieManager cm = CookieManager.getInstance();
            for (String domain : COOKIE_DOMAINS) {
                try {
                    String c = cm.getCookie(domain);
                    if (c != null && c.contains("remixsid")) return true;
                } catch (Exception ignored) {}
            }
            return false;
        }

        private String collectCookies() {
            CookieManager cm = CookieManager.getInstance();
            StringBuilder sb = new StringBuilder();
            for (String domain : COOKIE_DOMAINS) {
                try {
                    String c = cm.getCookie(domain);
                    if (c != null && !c.isEmpty()) {
                        if (sb.length() > 0) sb.append("; ");
                        sb.append(c);
                    }
                } catch (Exception ignored) {}
            }
            return sb.toString();
        }

        // -----------------------------------------------------------------
        //  HTTP-скрапер (порт VkTokenScraper.kt)
        // -----------------------------------------------------------------

        private static final class ScrapeResult {
            @Nullable String token;
            long expiresIn;
            @Nullable String error;
        }

        private static final Pattern JS_LOCATION_RE =
                Pattern.compile("location\\.href\\s*=\\s*[\"']([^\"']+)[\"']");
        private static final Pattern OAUTH_GRANT_RE =
                Pattern.compile("(https://login\\.vk\\.(?:com|ru)/\\?act=grant_access[^\"'\\s<]+)");

        private ScrapeResult scrapeAccessToken(String cookies, String userAgent) {
            ScrapeResult result = new ScrapeResult();
            String endpoint = SCRAPER_AUTH_URL;
            int hops = MAX_OAUTH_HOPS;

            while (hops-- > 0) {
                HttpURLConnection conn = null;
                try {
                    conn = (HttpURLConnection) new URL(endpoint).openConnection();
                    conn.setInstanceFollowRedirects(false);
                    conn.setRequestMethod("GET");
                    conn.setRequestProperty("Cookie", cookies);
                    conn.setRequestProperty("User-Agent", userAgent);
                    conn.setRequestProperty("Accept",
                            "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8");
                    conn.setConnectTimeout(15_000);
                    conn.setReadTimeout(15_000);

                    int code = conn.getResponseCode();

                    // --- Редирект ---
                    if (code == 301 || code == 302 || code == 303 || code == 307 || code == 308) {
                        String next = conn.getHeaderField("Location");
                        if (next == null || next.isEmpty()) {
                            result.error = "redirect without Location (HTTP " + code + ")";
                            return result;
                        }
                        ScrapeResult parsed = parseFragment(next);
                        if (parsed != null) return parsed;
                        endpoint = next;
                        continue;
                    }

                    // --- 200 OK: парсим HTML ---
                    if (code == 200) {
                        String html = readStream(conn.getInputStream());

                        Matcher jsMatch = JS_LOCATION_RE.matcher(html);
                        if (jsMatch.find()) {
                            String target = jsMatch.group(1);
                            ScrapeResult parsed = parseFragment(target);
                            if (parsed != null) return parsed;
                            endpoint = target.replace("&amp;", "&");
                            continue;
                        }

                        Matcher grantMatch = OAUTH_GRANT_RE.matcher(html);
                        if (grantMatch.find()) {
                            endpoint = grantMatch.group(1).replace("&amp;", "&");
                            continue;
                        }

                        result.error = "no redirect found in HTML (HTTP 200)";
                        return result;
                    }

                    result.error = "unexpected HTTP " + code;
                    return result;
                } catch (Exception e) {
                    result.error = "network: " + e.getMessage();
                    return result;
                } finally {
                    if (conn != null) {
                        try { conn.disconnect(); } catch (Exception ignored) {}
                    }
                }
            }

            result.error = "too many redirects (max " + MAX_OAUTH_HOPS + ")";
            return result;
        }

        @Nullable
        private static ScrapeResult parseFragment(String urlStr) {
            if (urlStr == null || !urlStr.contains("access_token=")) return null;

            String fragment;
            try {
                Uri uri = Uri.parse(urlStr);
                fragment = uri.getEncodedFragment();
                if (fragment == null) fragment = uri.getEncodedQuery();
                if (fragment == null) {
                    int hash = urlStr.indexOf('#');
                    if (hash >= 0) fragment = urlStr.substring(hash + 1);
                }
            } catch (Exception e) {
                int hash = urlStr.indexOf('#');
                fragment = hash >= 0 ? urlStr.substring(hash + 1) : urlStr;
            }
            if (fragment == null) return null;

            Map<String, String> params = new HashMap<>();
            for (String part : fragment.split("&")) {
                int eq = part.indexOf('=');
                if (eq <= 0) continue;
                String k = part.substring(0, eq);
                String v = part.substring(eq + 1);
                try {
                    v = URLDecoder.decode(v, "UTF-8");
                } catch (Exception ignored) {}
                params.put(k, v);
            }

            String token = params.get("access_token");
            if (token == null || token.isEmpty()) return null;

            long expires = 0L;
            try { expires = Long.parseLong(params.get("expires_in")); } catch (Exception ignored) {}

            ScrapeResult r = new ScrapeResult();
            r.token = token;
            r.expiresIn = expires;
            return r;
        }

        private static String readStream(InputStream is) throws Exception {
            StringBuilder sb = new StringBuilder();
            try (BufferedReader br = new BufferedReader(new InputStreamReader(is, "UTF-8"))) {
                String line;
                while ((line = br.readLine()) != null) {
                    sb.append(line).append('\n');
                }
            }
            return sb.toString();
        }

        // -----------------------------------------------------------------
        //  Поллинг / таймеры
        // -----------------------------------------------------------------

        private void schedulePolling() {
            pollRunnable = new Runnable() {
                @Override
                public void run() {
                    if (finished.get()) return;
                    WebView wv = webView;
                    if (wv == null) {
                        handler.postDelayed(this, POLL_INTERVAL_MS);
                        return;
                    }
                    String url = wv.getUrl();
                    if (url != null) {
                        logUrl(url);
                        maybeStartScraper(url);
                    }
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
