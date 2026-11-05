// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// Единая (для Windows и Linux) точка входа LaLuneTokenFetcher.
// Получает VK access_token через Playwright (Chromium), сохраняет его в
// token.json (см. LaLuneTokenFetcher.Core) и печатает путь в stdout.
//
// Сессия VK сохраняется в <dir бинарника>/userdata — рядом с самим
// LaLuneTokenFetcher. При повторных запусках VK сразу показывает
// «Продолжить как <Имя>», и токен получается за пару секунд.
//
// Коды возврата:
//   0  — токен получен и сохранён
//   1  — прочая критическая ошибка
//   3  — токен не получен (тайм-аут / пользователь закрыл окно /
//         silent_token не удалось разменять)
//   4  — Chromium всё ещё недоступен после автоматической установки

using LaLuneTokenFetcher.Core;

namespace LaLuneTokenFetcher.Playwright;

internal static class Program
{
    /// <summary>
    /// Fallback-маркер для старых launcher/backend версий. Обычно до него
    /// дело не доходит: Chromium проверяется и устанавливается самим C#.
    /// </summary>
    public const string ChromiumMissingMarker = "LALUNE_CHROMIUM_MISSING";

    private static int Main(string[] args)
    {
        if (args.Contains("--help") || args.Contains("-h"))
        {
            PrintHelp();
            return 0;
        }

        try
        {
            EnsureChromiumInstalled();

            ITokenFetcher fetcher = new PlaywrightTokenFetcher();
            var token = fetcher.FetchTokenAsync().GetAwaiter().GetResult();

            if (string.IsNullOrEmpty(token))
            {
                Console.Error.WriteLine(
                    "[LaLune] Токен не получен (тайм-аут, отмена или не удалось " +
                    "разменять silent_token на access_token).");
                return 3;
            }

            var path = TokenStorage.Save(token);
            Console.WriteLine("[LaLune] Токен сохранён: " + path);
            return 0;
        }
        catch (PlaywrightTokenFetcher.ChromiumMissingException ex)
        {
            Console.Error.WriteLine("[LaLune] " + ChromiumMissingMarker + ": " + ex.Message);
            return 4;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine("[LaLune] Критическая ошибка: " + ex.Message);
            return 1;
        }
    }

    private static void EnsureChromiumInstalled()
    {
        if (IsChromiumInstalled())
        {
            Console.WriteLine("[LaLune] Playwright Chromium найден.");
            return;
        }

        Console.WriteLine("[LaLune] Playwright Chromium не найден. Устанавливаю автоматически...");

        // Запускаем встроенный installer Microsoft.Playwright напрямую из C#.
        // PowerShell/playwright.ps1 для установки браузера больше не нужен.
        var exitCode = Microsoft.Playwright.Program.Main(new[] {"install"});
        if (exitCode != 0)
        {
            throw new Exception($"Playwright exited with code {exitCode}");
        }

        if (!IsChromiumInstalled())
        {
            throw new PlaywrightTokenFetcher.ChromiumMissingException(
                "Playwright завершил установку, но Chromium executable не найден.");
        }

        Console.WriteLine("[LaLune] Playwright Chromium установлен.");
    }

    private static bool IsChromiumInstalled()
    {
        try
        {
            using var playwright = Microsoft.Playwright.Playwright
                .CreateAsync()
                .GetAwaiter()
                .GetResult();

            var executablePath = playwright.Chromium.ExecutablePath;
            return !string.IsNullOrWhiteSpace(executablePath)
                && File.Exists(executablePath);
        }
        catch
        {
            return false;
        }
    }

    private static void PrintHelp()
    {
        Console.WriteLine(
            "LaLuneTokenFetcher (Playwright) - получает токен доступа.\n" +
            "\n" +
            "Использование:\n" +
            "  LaLuneTokenFetcher             открывает Chromium и получает токен\n" +
            "  LaLuneTokenFetcher --help      показать эту справку\n" +
            "\n" +
            "Профиль VK сохраняется в <dir бинарника>/userdata — при повторных\n" +
            "запусках VK сразу предлагает «Продолжить как ...», и токен\n" +
            "получается без повторного ввода пароля.\n" +
            "\n" +
            "Токен сохраняется в .la-lune/token.json рядом с пользователем.\n" +
            "Если Playwright Chromium отсутствует, программа автоматически " +
            "установит его перед запуском OAuth.");
    }
}
