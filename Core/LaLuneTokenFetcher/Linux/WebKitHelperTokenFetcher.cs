// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// Реализация ITokenFetcher для Linux: запускает нативный хелпер
// la-lune-webview-helper (GTK + WebKitGTK), который открывает окно
// авторизации и печатает access_token в stdout.
//
// Хелпер сам опрашивает URL раз в 3 секунды и печатает каждый новый URL
// в stderr с префиксом [helper] URL: — чтобы пользователь видел динамику,
// как в Windows-версии. C#-сторона повторяет эту же логику: читает
// stderr построчно, перекладывает в stdout с префиксом [LaLune] URL:,
// и ждёт строку TOKEN:<access_token> в stdout.
//
// Формат общения с хелпером:
//   argv[1] = URL страницы авторизации
//   stdout  = одна строка "TOKEN:<access_token>" при успехе
//             или "ERROR:<сообщение>" при ошибке
//   stderr  = диагностика, включая "[helper] URL: <url>" раз в 3 сек
//   exit 0  — токен получен
//   exit 3  — тайм-аут / окно закрыто
//
// Хелпер ищется рядом с бинарником; если его нет — понятная ошибка.

using System.Diagnostics;
using LaLuneTokenFetcher.Core;

namespace LaLuneTokenFetcher.Linux;

public sealed class WebKitHelperTokenFetcher : ITokenFetcher
{
    private const string HelperName = "la-lune-webview-helper";

    public async Task<string?> FetchTokenAsync(
        CancellationToken cancellationToken = default)
    {
        var helperPath = ResolveHelperPath();
        if (helperPath == null)
        {
            throw new FileNotFoundException(
                $"Не найден нативный хелпер '{HelperName}'. " +
                "Соберите его из native/la-lune-webview-helper.c и положите " +
                "рядом с бинарником, либо пересоберите проект через " +
                "build.sh — он собирает хелпер автоматически.");
        }

        var psi = new ProcessStartInfo
        {
            FileName = helperPath,
            ArgumentList = { VkAuthConstants.AuthUrl },
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = false,
        };

        using var process = new Process { StartInfo = psi };
        process.Start();

        using var cts = CancellationTokenSource.CreateLinkedTokenSource(
            cancellationToken);
        cts.CancelAfter(VkAuthConstants.Timeout);

        string? token = null;

        // Параллельно читаем stdout (TOKEN:...) и stderr ([helper] URL: ...).
        var stdoutTask = Task.Run(async () =>
        {
            string? line;
            while ((line = await process.StandardOutput.ReadLineAsync()) != null)
            {
                var trimmed = line.Trim();
                if (trimmed.StartsWith("TOKEN:", StringComparison.Ordinal))
                {
                    token = trimmed.Substring("TOKEN:".Length).Trim();
                }
                else if (trimmed.StartsWith("ERROR:", StringComparison.Ordinal))
                {
                    Console.Error.WriteLine(
                        "[LaLune] Хелпер сообщил об ошибке: " +
                        trimmed.Substring("ERROR:".Length).Trim());
                }
            }
        }, cts.Token);

        var stderrTask = Task.Run(async () =>
        {
            string? line;
            while ((line = await process.StandardError.ReadLineAsync()) != null)
            {
                var trimmed = line.Trim();
                // Хелпер печатает "[helper] URL: ..." — перекладываем
                // в stdout с нашим префиксом, чтобы пользователь видел
                // динамику так же, как в Windows-версии.
                const string helperPrefix = "[helper] URL:";
                if (trimmed.StartsWith(helperPrefix, StringComparison.Ordinal))
                {
                    var url = trimmed.Substring(helperPrefix.Length).Trim();
                    Console.WriteLine("[LaLune] URL: " + url);
                }
                else
                {
                    // Прочая диагностика — как есть, чтобы не терять.
                    Console.Error.WriteLine(trimmed);
                }
            }
        }, cts.Token);

        try
        {
            await process.WaitForExitAsync(cts.Token);
        }
        catch (OperationCanceledException)
        {
            TryKill(process);
            return null;
        }

        // Дожидаемся окончания чтения (после exit потоки закроются сами).
        try { await stdoutTask; } catch { /* игнорируем отмену */ }
        try { await stderrTask; } catch { /* игнорируем отмену */ }

        return token;
    }

    private static string? ResolveHelperPath()
    {
        // 1. Рядом с бинарником (AppContext.BaseDirectory).
        var baseDir = AppContext.BaseDirectory;
        var candidate = Path.Combine(baseDir, HelperName);
        if (File.Exists(candidate)) return candidate;

        // 2. В native/ относительно выходной папки — на случай запуска
        //    через `dotnet run` без публикации.
        candidate = Path.Combine(baseDir, "native", HelperName);
        if (File.Exists(candidate)) return candidate;

        return null;
    }

    private static void TryKill(Process p)
    {
        try
        {
            if (!p.HasExited) p.Kill(entireProcessTree: true);
        }
        catch
        {
            // best-effort
        }
    }
}
