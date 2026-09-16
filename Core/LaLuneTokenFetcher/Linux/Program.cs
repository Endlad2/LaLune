// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// Linux-точка входа. Делегирует открытие WebView нативному C-хелперу
// (GTK + WebKitGTK), который читает URL из аргументов и печатает
// access_token в stdout, когда пользователь доходит до blank.html.
// Разбор URL и сохранение — через LaLuneTokenFetcher.Core.

using LaLuneTokenFetcher.Core;
using LaLuneTokenFetcher.Linux;

namespace LaLuneTokenFetcher.Linux;

internal static class Program
{
    private static int Main(string[] args)
    {
        if (args.Contains("--help") || args.Contains("-h"))
        {
            PrintHelp();
            return 0;
        }

        try
        {
            ITokenFetcher fetcher = new WebKitHelperTokenFetcher();
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
            "LaLuneTokenFetcher (Linux) — получает вечный токен ВКонтакте.\n" +
            "\n" +
            "Использование:\n" +
            "  LaLuneTokenFetcher             открыть WebView и получить токен\n" +
            "  LaLuneTokenFetcher --help      показать эту справку\n" +
            "\n" +
            "Токен сохраняется в ~/.la-lune/token.json");
    }
}
