// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// Windows-точка входа. Использует WebView2 для получения токена ВК,
// делегируя разбор URL и сохранение в LaLuneTokenFetcher.Core.
//
// Здесь сознательно НЕ используется ApplicationConfiguration.Initialize():
// этот метод генерируется source generator'ом WinForms SDK, который может
// не сработать при наличии предупреждения MSB3277 (конфликт WindowsBase
// между NETCore.App.Ref 4.0 и WPF-сборкой WebView2 5.0), что приводит к
// ошибке CS0234. Вместо этого настройка WinForms выполняется вручную —
// тривиально, но надёжно и без зависимости от кодогенерации.

using LaLuneTokenFetcher.Core;
using LaLuneTokenFetcher.Windows;

namespace LaLuneTokenFetcher.Windows;

internal static class Program
{
    [STAThread]
    private static int Main(string[] args)
    {
        if (args.Contains("--help") || args.Contains("-h"))
        {
            PrintHelp();
            return 0;
        }

        // Ручная инициализация WinForms вместо ApplicationConfiguration.Initialize().
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        Application.SetHighDpiMode(HighDpiMode.PerMonitorV2);

        try
        {
            ITokenFetcher fetcher = new WebView2TokenFetcher();
            var token = fetcher.FetchTokenAsync().GetAwaiter().GetResult();

            if (string.IsNullOrEmpty(token))
            {
                Console.Error.WriteLine(
                    "[LaLune] Токен не получен (тайм-аут или окно закрыто).");
                return 3;
            }

            var path = TokenStorage.Save(token);
            Console.WriteLine("[LaLune] Токен сохранён: " + path);
            return 0;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine("[LaLune] Критическая ошибка: " + ex.Message);
            return 1;
        }
    }

    private static void PrintHelp()
    {
        Console.WriteLine(
            "LaLuneTokenFetcher (Windows) — получает вечный токен ВКонтакте.\n" +
            "\n" +
            "Использование:\n" +
            "  LaLuneTokenFetcher.exe             открыть WebView2 и получить токен\n" +
            "  LaLuneTokenFetcher.exe --help      показать эту справку\n" +
            "\n" +
            "Токен сохраняется в %APPDATA%\\.la-lune\\token.json");
    }
}
