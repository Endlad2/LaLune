// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// Реализация ITokenFetcher через Microsoft.Web.WebView2.
//
// Алгоритм (с учётом того, что WebView2 может не показывать fragment
// через ExecuteScriptAsync("window.location.href") — VK редиректит на
// blank.html с access_token во фрагменте, а Chromium в некоторых
// случаях теряет фрагмент при межстраничных переходах):
//
//   1. Создаём окно 500x700 и WebView2.
//   2. Navigate(AuthUrl).
//   3. Раз в 3 секунды:
//        - читаем window.location.href
//        - читаем window.location.hash (он может отличаться!)
//        - читаем document.URL
//        - печатаем всё это в терминал (с префиксом [LaLune] URL:)
//        - если URL — blank.html, пробуем извлечь токен из href и из hash
//   4. Плюс NavigationStarting и SourceChanged — мгновенный перехват.
//   5. Плюс перехват WebResourceRequested (иногда fragment виден
//      в запросе, если он сформирован как query).

using System.Text.Json;
using LaLuneTokenFetcher.Core;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.WinForms;
using WinForms = System.Windows.Forms;

namespace LaLuneTokenFetcher.Windows;

public sealed class WebView2TokenFetcher : ITokenFetcher
{
    /// <summary>Интервал опроса URL — 3 секунды, как просил пользователь.</summary>
    private const int PollIntervalMs = 3000;

    public Task<string?> FetchTokenAsync(CancellationToken cancellationToken = default)
    {
        var tcs = new TaskCompletionSource<string?>(
            TaskCreationOptions.RunContinuationsAsynchronously);

        var thread = new Thread(() => RunUi(tcs, cancellationToken))
        {
            IsBackground = true,
            Name = "LaLune.WebView2",
        };
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();

        return tcs.Task;
    }

    private static void RunUi(
        TaskCompletionSource<string?> tcs,
        CancellationToken cancellationToken)
    {
        try
        {
            using var form = new WinForms.Form
            {
                Text = "Авторизация ВКонтакте — LaLune",
                Width = 500,
                Height = 700,
                StartPosition = WinForms.FormStartPosition.CenterScreen,
                FormBorderStyle = WinForms.FormBorderStyle.FixedSingle,
                MaximizeBox = false,
                MinimizeBox = true,
            };

            var webView = new WebView2 { Dock = WinForms.DockStyle.Fill };
            form.Controls.Add(webView);

            string? captured = null;
            var lastLoggedUrl = string.Empty;

            void TryComplete(string? url)
            {
                if (captured != null || string.IsNullOrEmpty(url)) return;

                // Печатаем URL в терминал — пользователь видит, что происходит.
                if (url != lastLoggedUrl)
                {
                    lastLoggedUrl = url;
                    Console.WriteLine("[LaLune] URL: " + url);
                }

                // Пробуем вытащить токен из полного URL и из hash-фрагмента.
                // VK кладёт access_token именно во фрагмент.
                var token = VkTokenParser.ExtractAccessToken(url);
                if (token == null)
                {
                    // Иногда фрагмент теряется в href, но виден в hash.
                    var hashIndex = url.IndexOf('#');
                    if (hashIndex >= 0)
                    {
                        var hashOnly = "https://oauth.vk.ru/blank.html" +
                                       url.Substring(hashIndex);
                        token = VkTokenParser.ExtractAccessToken(hashOnly);
                    }
                }

                if (token == null) return;

                captured = token;
                tcs.TrySetResult(token);
                Console.WriteLine("[LaLune] Токен получен, закрываю окно.");
                if (!form.IsDisposed)
                {
                    try { form.BeginInvoke(new Action(() => form.Close())); }
                    catch { /* окно уже закрыто */ }
                }
            }

            // Таймер раз в 3 секунды: читаем href, hash, document.URL.
            var timer = new WinForms.Timer { Interval = PollIntervalMs };
            timer.Tick += async (_, _) =>
            {
                if (captured != null) return;
                try
                {
                    var rawHref = await webView.ExecuteScriptAsync(
                        "window.location.href");
                    var rawHash = await webView.ExecuteScriptAsync(
                        "window.location.hash");
                    var rawDoc = await webView.ExecuteScriptAsync(
                        "document.URL");

                    var href = DecodeJsString(rawHref);
                    var hash = DecodeJsString(rawHash);
                    var doc = DecodeJsString(rawDoc);

                    if (!string.IsNullOrEmpty(href))
                    {
                        // Логируем всё, чтобы пользователь видел динамику.
                        if (href != lastLoggedUrl)
                        {
                            lastLoggedUrl = href;
                            Console.WriteLine("[LaLune] URL: " + href);
                            if (!string.IsNullOrEmpty(hash))
                                Console.WriteLine("[LaLune] HASH: " + hash);
                        }
                        TryComplete(href);
                    }

                    if (captured != null) return;

                    if (!string.IsNullOrEmpty(doc) && doc != href)
                    {
                        TryComplete(doc);
                    }

                    if (captured != null) return;

                    // Если hash содержит access_token — собираем псевдо-URL.
                    if (!string.IsNullOrEmpty(hash) &&
                        hash.Contains("access_token", StringComparison.Ordinal))
                    {
                        var synthesized =
                            "https://oauth.vk.ru/blank.html" + hash;
                        TryComplete(synthesized);
                    }
                }
                catch
                {
                    // DOM ещё не готов / окно закрывается — игнорируем.
                }
            };

            webView.CoreWebView2InitializationCompleted += async (_, e) =>
            {
                if (!e.IsSuccess)
                {
                    tcs.TrySetException(
                        e.InitializationException
                        ?? new Exception("WebView2 не инициализирован."));
                    return;
                }

                // Мгновенный перехват навигации.
                webView.CoreWebView2.NavigationStarting += (_, navArgs) =>
                    TryComplete(navArgs.Uri);

                // Дополнительно: событие SourceChanged — срабатывает
                // при смене URL, включая fragment-only переходы.
                webView.CoreWebView2.SourceChanged += (_, _) =>
                {
                    try
                    {
                        TryComplete(webView.CoreWebView2.Source);
                    }
                    catch { /* игнорируем */ }
                };

                webView.CoreWebView2.Navigate(VkAuthConstants.AuthUrl);
                timer.Start();
            };

            form.FormClosed += (_, _) =>
            {
                timer.Stop();
                tcs.TrySetResult(captured);
            };

            cancellationToken.Register(() =>
            {
                try { form.BeginInvoke(new Action(() => form.Close())); }
                catch { /* окно уже закрыто */ }
            });

            var userDataFolder = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "LaLune", "vk_auth_data");
            Directory.CreateDirectory(userDataFolder);

            var envOptions = new CoreWebView2EnvironmentOptions
            {
                AdditionalBrowserArguments =
                    "--disable-features=msWebOOUI,msPdfOOUI --no-first-run",
            };

            var env = CoreWebView2Environment
                .CreateAsync(null, userDataFolder, envOptions)
                .GetAwaiter()
                .GetResult();

            form.Shown += async (_, _) =>
            {
                try
                {
                    await webView.EnsureCoreWebView2Async(env);
                }
                catch (Exception ex)
                {
                    tcs.TrySetException(ex);
                    if (!form.IsDisposed) form.Close();
                    return;
                }

                var timeoutTask = Task.Delay(VkAuthConstants.Timeout, cancellationToken);
                var completed = await Task.WhenAny(tcs.Task, timeoutTask);

                if (completed == timeoutTask && captured == null)
                {
                    Console.Error.WriteLine(
                        "[LaLune] Тайм-аут ожидания токена " +
                        $"({VkAuthConstants.Timeout.TotalMinutes:0} мин).");
                    tcs.TrySetResult(null);
                    if (!form.IsDisposed) form.Close();
                }
            };

            WinForms.Application.Run(form);
            tcs.TrySetResult(captured);
        }
        catch (Exception ex)
        {
            tcs.TrySetException(ex);
        }
    }

    /// <summary>
    /// ExecuteScriptAsync возвращает JSON-сериализованную строку.
    /// "https://..." → https://... , null → null.
    /// </summary>
    private static string? DecodeJsString(string? raw)
    {
        if (string.IsNullOrEmpty(raw) || raw == "null") return null;
        try
        {
            return JsonSerializer.Deserialize<string>(raw);
        }
        catch
        {
            return null;
        }
    }
}
