// SPDX-FileCopyrightText: 2026 luminescq
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// la-lune-webview-helper — крошечный GTK/WebKitGTK-хелпер, который
// открывает окно авторизации ВКонтакте и печатает access_token в stdout,
// когда WebKit переходит на blank.html.
//
// Зачем: Microsoft.Web.WebView2 работает только на Windows. На Linux
// аналог — WebKitGTK, но .NET-биндинги к нему давно заброшены. Проще
// держать 200 строк нативного C и вызывать их из C# как подпроцесс.
//
// Использование:
//   la-lune-webview-helper <auth-url>
//
// Вывод:
//   stdout: одна строка "TOKEN:<access_token>" при успехе.
//   stderr: диагностика, включая "[helper] URL: <url>" при каждой смене URL
//           и "[helper] URL: <url>" раз в 3 секунды, чтобы C#-сторона
//           перекладывала это в свой stdout.
//   Код возврата: 0 — токен получен, 1 — ошибка, 3 — тайм-аут/закрытие.
//
// Сборка (Debian/Ubuntu):
//   sudo apt install libgtk-3-dev libwebkit2gtk-4.1-dev
//   gcc -O2 -o la-lune-webview-helper la-lune-webview-helper.c \
//       $(pkg-config --cflags --libs gtk+-3.0 webkit2gtk-4.1)
//
// Программа использует:
//   - notify::uri — смена URL (быстрый перехват);
//   - load-changed — завершение загрузки (дополнительный перехват);
//   - g_timeout_add(3000) — раз в 3 секунды читает webkit_web_view_get_uri()
//     и печатает его в stderr, чтобы пользователь видел динамику.

#define _GNU_SOURCE

#include <gtk/gtk.h>
#include <webkit2/webkit2.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// Тайм-аут ожидания токена (в миллисекундах) — как в оригинале, 5 минут.
#define AUTH_TIMEOUT_MS (5 * 60 * 1000)

// Интервал опроса URL (мс). Пользователь просил 3 секунды.
#define POLL_INTERVAL_MS 3000

typedef struct {
    GtkWidget *window;
    GtkWidget *web_view;
    guint poll_timer_id;
    guint timeout_id;
    gboolean finished;
    char *last_logged_url;
} AppState;

// Проверяет, является ли URL редиректом VK на blank.html.
// Возвращает TRUE для https://oauth.vk.ru/blank.html и oauth.vk.com/blank.html.
static gboolean is_blank_redirect(const char *url)
{
    if (url == NULL) return FALSE;
    if (g_str_has_prefix(url, "https://oauth.vk.ru/blank.html") ||
        g_str_has_prefix(url, "https://oauth.vk.com/blank.html")) {
        return TRUE;
    }
    return FALSE;
}

// Извлекает access_token из фрагмента URL.
// Фрагмент вида "#access_token=...&expires_in=0&user_id=...".
// Возвращает NULL, если токена нет.
static char *extract_access_token(const char *url)
{
    if (url == NULL) return NULL;

    const char *hash = strchr(url, '#');
    if (hash == NULL) return NULL;
    hash++; // пропускаем '#'

    // Копируем фрагмент, чтобы не портить исходную строку.
    char *fragment = g_strdup(hash);
    if (fragment == NULL) return NULL;

    char *token = NULL;
    char **pairs = g_strsplit(fragment, "&", -1);
    for (int i = 0; pairs[i] != NULL; i++) {
        char *eq = strchr(pairs[i], '=');
        if (eq == NULL) continue;
        *eq = '\0';
        const char *key = pairs[i];
        const char *value = eq + 1;
        if (g_strcmp0(key, "access_token") == 0) {
            token = g_uri_unescape_string(value, NULL);
            if (token == NULL) token = g_strdup(value);
            break;
        }
    }

    g_strfreev(pairs);
    g_free(fragment);
    return token;
}

// Печатает URL в stderr, если он изменился с прошлого раза.
// C#-сторона читает stderr и перекладывает в свой stdout.
static void log_url_if_changed(AppState *state, const char *url)
{
    if (url == NULL) return;
    if (state->last_logged_url != NULL &&
        g_strcmp0(state->last_logged_url, url) == 0) {
        return;
    }
    g_free(state->last_logged_url);
    state->last_logged_url = g_strdup(url);
    fprintf(stderr, "[helper] URL: %s\n", url);
    fflush(stderr);
}

// Печатает токен и завершает приложение.
static void finish_with_token(AppState *state, const char *token)
{
    if (state->finished) return;
    state->finished = TRUE;

    if (token != NULL) {
        printf("TOKEN:%s\n", token);
    } else {
        printf("ERROR:token not found\n");
    }
    fflush(stdout);

    if (state->poll_timer_id != 0) {
        g_source_remove(state->poll_timer_id);
        state->poll_timer_id = 0;
    }
    if (state->timeout_id != 0) {
        g_source_remove(state->timeout_id);
        state->timeout_id = 0;
    }

    if (state->window != NULL) {
        gtk_widget_destroy(state->window);
    }
}

// Опрос текущего URL WebView раз в 3 секунды.
// Печатает URL в stderr, а если это blank.html — вытаскивает токен.
static gboolean poll_url(gpointer user_data)
{
    AppState *state = (AppState *)user_data;
    if (state->finished) return G_SOURCE_REMOVE;

    const gchar *url = webkit_web_view_get_uri(WEBKIT_WEB_VIEW(state->web_view));
    log_url_if_changed(state, url);

    if (url != NULL && is_blank_redirect(url)) {
        char *token = extract_access_token(url);
        finish_with_token(state, token);
        g_free(token);
        return G_SOURCE_REMOVE;
    }
    return G_SOURCE_CONTINUE;
}

// Реакция на смену URL (быстрее, чем таймер).
static void on_uri_changed(GObject *object, GParamSpec *pspec, gpointer user_data)
{
    (void)pspec;
    AppState *state = (AppState *)user_data;
    if (state->finished) return;

    const gchar *url = webkit_web_view_get_uri(WEBKIT_WEB_VIEW(object));
    log_url_if_changed(state, url);

    if (url != NULL && is_blank_redirect(url)) {
        char *token = extract_access_token(url);
        finish_with_token(state, token);
        g_free(token);
    }
}

// Реакция на завершение загрузки — тоже проверяем URL.
static void on_load_changed(WebKitWebView *web_view, WebKitLoadEvent event, gpointer user_data)
{
    (void)web_view;
    if (event != WEBKIT_LOAD_FINISHED) return;
    AppState *state = (AppState *)user_data;
    if (state->finished) return;

    const gchar *url = webkit_web_view_get_uri(web_view);
    log_url_if_changed(state, url);

    if (url != NULL && is_blank_redirect(url)) {
        char *token = extract_access_token(url);
        finish_with_token(state, token);
        g_free(token);
    }
}

// Пользователь закрыл окно до получения токена.
static gboolean on_window_delete(GtkWidget *widget, GdkEvent *event, gpointer user_data)
{
    (void)widget; (void)event;
    AppState *state = (AppState *)user_data;
    if (!state->finished) {
        state->finished = TRUE;
        printf("ERROR:window closed\n");
        fflush(stdout);
    }
    gtk_main_quit();
    return FALSE;
}

static gboolean on_timeout(gpointer user_data)
{
    AppState *state = (AppState *)user_data;
    if (state->finished) return G_SOURCE_REMOVE;

    fprintf(stderr, "[helper] тайм-аут ожидания токена\n");
    printf("ERROR:timeout\n");
    fflush(stdout);
    state->finished = TRUE;
    gtk_widget_destroy(state->window);
    return G_SOURCE_REMOVE;
}

static void on_destroy(GtkWidget *widget, gpointer user_data)
{
    (void)widget;
    AppState *state = (AppState *)user_data;
    if (!state->finished) {
        state->finished = TRUE;
        printf("ERROR:window closed\n");
        fflush(stdout);
    }
    gtk_main_quit();
}

int main(int argc, char **argv)
{
    if (argc < 2) {
        fprintf(stderr, "Использование: %s <auth-url>\n", argv[0]);
        return 1;
    }

    const char *auth_url = argv[1];

    if (!gtk_init_check(NULL, NULL)) {
        fprintf(stderr, "[helper] GTK не инициализировался (нет DISPLAY?).\n");
        return 1;
    }

    AppState state = {0};
    state.last_logged_url = NULL;

    state.window = gtk_window_new(GTK_WINDOW_TOPLEVEL);
    gtk_window_set_title(GTK_WINDOW(state.window), "Авторизация ВКонтакте — LaLune");
    gtk_window_set_default_size(GTK_WINDOW(state.window), 500, 700);
    gtk_window_set_position(GTK_WINDOW(state.window), GTK_WIN_POS_CENTER);
    gtk_container_set_border_width(GTK_CONTAINER(state.window), 0);
    g_signal_connect(state.window, "delete-event", G_CALLBACK(on_window_delete), &state);
    g_signal_connect(state.window, "destroy", G_CALLBACK(on_destroy), &state);

    state.web_view = webkit_web_view_new();
    gtk_container_add(GTK_CONTAINER(state.window), state.web_view);

    g_signal_connect(state.web_view, "notify::uri", G_CALLBACK(on_uri_changed), &state);
    g_signal_connect(state.web_view, "load-changed", G_CALLBACK(on_load_changed), &state);

    gtk_widget_show_all(state.window);

    webkit_web_view_load_uri(WEBKIT_WEB_VIEW(state.web_view), auth_url);

    // Печатаем стартовый URL сразу, чтобы C#-сторона видела первую строку.
    log_url_if_changed(&state, auth_url);

    state.poll_timer_id = g_timeout_add(POLL_INTERVAL_MS, poll_url, &state);
    state.timeout_id = g_timeout_add(AUTH_TIMEOUT_MS, on_timeout, &state);

    gtk_main();

    g_free(state.last_logged_url);
    return 0;
}
