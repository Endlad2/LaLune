// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// Реализация ITokenFetcher на базе Playwright (Chromium).
// Логика та же, что была у WebView2/WebKit-вариантов: открыть страницу
// авторизации VK, дождаться редиректа на blank.html с access_token в URL,
// вернуть токен. Меняется только движок — теперь Playwright.

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

    public async Task<string?> FetchTokenAsync(CancellationToken cancellationToken = default)
    {
        using var playwright = await CreatePlaywrightAsync();

        await using var browser = await LaunchChromiumAsync(playwright);

        var context = await browser.NewContextAsync(new BrowserNewContextOptions
        {
            // Язык/локаль — как у обычного пользователя, без автоматизации.
            Locale = "ru-RU",
            TimezoneId = "Europe/Moscow",
        });

        var page = await context.NewPageAsync();

        await page.GotoAsync(VkAuthConstants.AuthUrl, new PageGotoOptions
        {
            WaitUntil = WaitUntilState.DOMContentLoaded,
            Timeout = (float)VkAuthConstants.Timeout.TotalMilliseconds,
        });

        var deadline = DateTime.UtcNow + VkAuthConstants.Timeout;

        while (DateTime.UtcNow < deadline)
        {
            cancellationToken.ThrowIfCancellationRequested();

            var url = page.Url;
            var token = VkTokenParser.ExtractAccessToken(url);
            if (!string.IsNullOrEmpty(token))
            {
                return token;
            }

            await page.WaitForTimeoutAsync(VkAuthConstants.PollIntervalMs);
        }

        return null;
    }

    private static async Task<IPlaywright> CreatePlaywrightAsync()
    {
        try
        {
            return await Microsoft.Playwright.Playwright.CreateAsync();
        }
        catch (Exception ex)
        {
            throw new ChromiumMissingException(
                "Playwright не инициализирован: " + ex.Message, ex);
        }
    }

    private static async Task<IBrowser> LaunchChromiumAsync(IPlaywright playwright)
    {
        try
        {
            return await playwright.Chromium.LaunchAsync(new BrowserTypeLaunchOptions
            {
                Headless = false,
                // Отключаем флаг автоматизации, чтобы страница не видела
                // navigator.webdriver.
                Args = new[]
                {
                    "--disable-blink-features=AutomationControlled",
                },
            });
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
}