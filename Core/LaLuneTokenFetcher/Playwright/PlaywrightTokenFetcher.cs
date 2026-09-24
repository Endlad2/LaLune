// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// Реализация ITokenFetcher на базе Playwright (Chromium).
//
// Логика:
//
//   1. Открываем persistent context (userDataDir = %APPDATA%\.la-lune\
//      vk-token-fetcher\userdata на Windows, ~/.la-lune/vk-token-fetcher/
//      userdata на Linux/macOS), чтобы cookies/localStorage сохранялись
//      между запусками и лежали в ЕДИНОМ месте — рядом с самим
//      vk-token-fetcher\, независимо от того, откуда запущен процесс.
//
//   2. Идём на VK OAuth URL.
//
//   3. Каждые 3 секунды опрашиваем page.Url:
//
//      a) Если URL — blank.html и в фрагменте есть access_token
//         (настоящий) → сохраняем, выходим.
//
//      b) Если URL — blank.html и в фрагменте есть payload=...
//         с type=silent_token → это НЕ то, что нужно. Идём на vk.com
//         на 2 секунды (чтобы VK проставил cookie активной сессии),
//         затем ПЕРЕЗАПУСКАЕМ цикл: снова открываем OAuth URL.
//         На втором проходе VK уже знает юзера → показывает
//         «Продолжить как <Имя>» → возвращает настоящий access_token.
//
//      c) Если в фрагменте есть error= → выходим с ошибкой.
//
//   4. Максимум 1 перезапуск после silent_token (итого 2 прохода).
//
//   5. Общий таймаут — 5 минут (VkAuthConstants.Timeout).
//
// Путь userdata НЕ зависит от AppContext.BaseDirectory: он всегда
// вычисляется от домашнего каталога пользователя, поэтому сессия
// сохраняется в одном и том же месте, даже если exe запущен из другой
// папки (тесты, отладка, ручной запуск).

using System.Text.RegularExpressions;
using LaLuneTokenFetcher.Core;
using Microsoft.Playwright;

namespace LaLuneTokenFetcher.Playwright;

public sealed class PlaywrightTokenFetcher : ITokenFetcher
{
    /// <summary>
    /// Бросается, когда Playwright установлен, но сам браузер Chromium —
    /// нет (обычно нужно `playwright install chromium`).
    /// </summary>
    public sealed class ChromiumMissingException : Exception
    {
        public ChromiumMissingException(string message) : base(message) { }
        public ChromiumMissingException(string message, Exception inner) : base(message, inner) { }
    }

    /// <summary>
    /// Интервал опроса URL. По ТЗ — 3 секунды.
    /// </summary>
    private const int PollIntervalMs = 3000;

    /// <summary>
    /// Сколько миллисекунд сидеть на vk.com, чтобы VK проставил cookie.
    /// По ТЗ — 2 секунды.
    /// </summary>
    private const int VkDotComWaitMs = 2000;

    /// <summary>
    /// Максимум перезапусков после silent_token.
    /// По ТЗ — 1 (итого не более 2 проходов через OAuth).
    /// </summary>
    private const int MaxSilentRestarts = 1;

    private static readonly Regex SilentTypeRegex =
        new(@"type[\\""':=]*silent_token", RegexOptions.Compiled | RegexOptions.IgnoreCase);

    public async Task<string?> FetchTokenAsync(CancellationToken cancellationToken = default)
    {
        var userDataDir = ResolveUserDataDir();
        Directory.CreateDirectory(userDataDir);

        // Логируем путь в stderr, чтобы Go-бэкенд показал его в [VK] логах.
        Console.Error.WriteLine("[LaLune] userdata dir: " + userDataDir);

        // Persistent context: сохраняет cookies/localStorage в userDataDir.
        // В отличие от LaunchAsync+NewContextAsync, это НЕ инкогнито —
        // всё пишется на диск и переиспользуется.
        var context = await LaunchPersistentContextAsync(userDataDir);

        try
        {
            var page = context.Pages.Count > 0
                ? context.Pages[0]
                : await context.NewPageAsync();

            var deadline = DateTime.UtcNow + VkAuthConstants.Timeout;
            var silentRestarts = 0;

            while (DateTime.UtcNow < deadline)
            {
                cancellationToken.ThrowIfCancellationRequested();

                // ----- Проход через OAuth -----
                await page.GotoAsync(VkAuthConstants.AuthUrl, new PageGotoOptions
                {
                    WaitUntil = WaitUntilState.DOMContentLoaded,
                    Timeout = (float)VkAuthConstants.Timeout.TotalMilliseconds,
                });

                var passResult = await WaitForResultAsync(page, deadline, cancellationToken);
                switch (passResult.Kind)
                {
                    case ResultKind.AccessToken:
                        return passResult.Token;

                    case ResultKind.SilentToken:
                        if (silentRestarts >= MaxSilentRestarts)
                        {
                            // Silent и на втором проходе — сдаёмся.
                            return null;
                        }
                        silentRestarts++;

                        // Идём на vk.com на 2 сек, чтобы VK проставил cookie
                        // активной сессии. Затем внешний while повторит OAuth.
                        await page.GotoAsync("https://vk.com/", new PageGotoOptions
                        {
                            WaitUntil = WaitUntilState.DOMContentLoaded,
                            Timeout = 30_000,
                        });
                        await page.WaitForTimeoutAsync(VkDotComWaitMs);
                        break;

                    case ResultKind.OAuthError:
                        return null;

                    case ResultKind.Timeout:
                        return null;
                }
            }

            return null;
        }
        finally
        {
            // Persistent context: CloseAsync() сохраняет профиль на диск.
            try { await context.CloseAsync(); } catch { /* ignore */ }
        }
    }

    /// <summary>
    /// Ждёт, пока URL станет интересным. Проверяет каждые 3 секунды.
    /// </summary>
    private static async Task<PassResult> WaitForResultAsync(
        IPage page,
        DateTime deadline,
        CancellationToken cancellationToken)
    {
        while (DateTime.UtcNow < deadline)
        {
            cancellationToken.ThrowIfCancellationRequested();

            var url = page.Url;

            if (VkTokenParser.IsBlankRedirect(url))
            {
                var fragment = ExtractFragment(url);

                if (!string.IsNullOrEmpty(fragment))
                {
                    // 1) Настоящий access_token.
                    var token = VkTokenParser.ExtractAccessToken(url);
                    if (!string.IsNullOrEmpty(token))
                    {
                        return PassResult.AccessToken(token);
                    }

                    // 2) silent_token — payload с type=silent_token.
                    if (IsSilentToken(fragment))
                    {
                        return PassResult.SilentToken();
                    }

                    // 3) Ошибка OAuth.
                    if (fragment.Contains("error=", StringComparison.Ordinal))
                    {
                        return PassResult.OAuthError();
                    }
                }
            }

            await page.WaitForTimeoutAsync(PollIntervalMs);
        }

        return PassResult.Timeout();
    }

    /// <summary>
    /// Достаёт фрагмент из URL (#... или ?...) и URL-декодирует его,
    /// чтобы `payload=%7B%22type%22...` превратился в `payload={"type"...`.
    /// </summary>
    private static string ExtractFragment(string url)
    {
        int hash = url.IndexOf('#');
        if (hash >= 0)
        {
            var raw = url.Substring(hash + 1);
            return Uri.UnescapeDataString(raw);
        }

        int q = url.IndexOf('?');
        if (q >= 0)
        {
            var raw = url.Substring(q + 1);
            return Uri.UnescapeDataString(raw);
        }

        return string.Empty;
    }

    /// <summary>
    /// silent_token определяется по payload=... с type=silent_token.
    /// Проверяем и по наличию "payload=", и по "type":"silent_token"
    /// (после URL-декодирования кавычки станут обычными).
    /// </summary>
    private static bool IsSilentToken(string fragment)
    {
        if (!fragment.Contains("payload=", StringComparison.Ordinal))
        {
            return false;
        }
        return SilentTypeRegex.IsMatch(fragment);
    }

    /// <summary>
    /// Путь профиля: %APPDATA%\.la-lune\vk-token-fetcher\userdata (Windows)
    /// или ~/.la-lune/vk-token-fetcher/userdata (Linux/macOS).
    ///
    /// НЕ зависит от AppContext.BaseDirectory — единый путь для всех
    /// запусков, независимо от того, откуда стартовал процесс.
    /// </summary>
    private static string ResolveUserDataDir()
    {
        string baseDir;

        if (OperatingSystem.IsWindows())
        {
            var appData = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
            if (string.IsNullOrEmpty(appData))
            {
                appData = Environment.GetEnvironmentVariable("APPDATA")
                          ?? Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
            }
            baseDir = Path.Combine(appData, ".la-lune");
        }
        else
        {
            var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
            if (string.IsNullOrEmpty(home))
            {
                home = Environment.GetEnvironmentVariable("HOME") ?? ".";
            }
            baseDir = Path.Combine(home, ".la-lune");
        }

        return Path.Combine(baseDir, "vk-token-fetcher", "userdata");
    }

    private static async Task<IBrowserContext> LaunchPersistentContextAsync(string userDataDir)
    {
        IPlaywright playwright;
        try
        {
            playwright = await Microsoft.Playwright.Playwright.CreateAsync();
        }
        catch (Exception ex)
        {
            throw new ChromiumMissingException(
                "Playwright не инициализирован: " + ex.Message, ex);
        }

        try
        {
            var context = await playwright.Chromium.LaunchPersistentContextAsync(
                userDataDir,
                new BrowserTypeLaunchPersistentContextOptions
                {
                    Headless = false,
                    Args = new[]
                    {
                        "--disable-blink-features=AutomationControlled",
                    },
                    Locale = "ru-RU",
                    TimezoneId = "Europe/Moscow",
                });

            _ = playwright; // держим ссылку, чтобы GC не собрал playwright раньше context
            return context;
        }
        catch (PlaywrightException ex) when (IsBrowserMissing(ex))
        {
            throw new ChromiumMissingException(
                "Chromium не установлен. Запустите `playwright install chromium`.", ex);
        }
    }

    private static bool IsBrowserMissing(PlaywrightException ex)
    {
        var msg = ex.Message ?? string.Empty;
        return msg.Contains("Executable doesn't exist", StringComparison.OrdinalIgnoreCase)
            || msg.Contains("please run the following command", StringComparison.OrdinalIgnoreCase)
            || msg.Contains("playwright install", StringComparison.OrdinalIgnoreCase);
    }

    // -----------------------------------------------------------------
    //  Внутренний тип результата одного прохода
    // -----------------------------------------------------------------

    private enum ResultKind { AccessToken, SilentToken, OAuthError, Timeout }

    private readonly struct PassResult
    {
        public ResultKind Kind { get; }
        public string? Token { get; }

        private PassResult(ResultKind kind, string? token)
        {
            Kind = kind;
            Token = token;
        }

        public static PassResult AccessToken(string token) => new(ResultKind.AccessToken, token);
        public static PassResult SilentToken() => new(ResultKind.SilentToken, null);
        public static PassResult OAuthError() => new(ResultKind.OAuthError, null);
        public static PassResult Timeout() => new(ResultKind.Timeout, null);
    }
}
