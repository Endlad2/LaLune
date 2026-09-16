// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// Сохранение токена в файл.
//   Windows: %APPDATA%\.la-lune\token.json
//   Linux:   ~/.la-lune/token.json
// На Linux файл получает права 0600 (только владелец).

using System.Text.Json;

namespace LaLuneTokenFetcher.Core;

public sealed class TokenStorage
{
    private const string DirName = ".la-lune";
    private const string FileName = "token.json";

    /// <summary>
    /// Возвращает путь к каталогу .la-lune для текущей ОС.
    /// </summary>
    public static string ResolveDirectory()
    {
        if (OperatingSystem.IsWindows())
        {
            var appData = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
            if (string.IsNullOrEmpty(appData))
            {
                appData = Environment.GetEnvironmentVariable("APPDATA")
                          ?? Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
            }
            return Path.Combine(appData, DirName);
        }

        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        if (string.IsNullOrEmpty(home))
        {
            home = Environment.GetEnvironmentVariable("HOME") ?? ".";
        }
        return Path.Combine(home, DirName);
    }

    /// <summary>
    /// Сохраняет токен и возвращает полный путь к файлу.
    /// </summary>
    public static string Save(string token)
    {
        if (string.IsNullOrWhiteSpace(token))
            throw new ArgumentException("Пустой токен.", nameof(token));

        var dir = ResolveDirectory();
        Directory.CreateDirectory(dir);

        var path = Path.Combine(dir, FileName);
        var payload = new TokenFile
        {
            Token = token.Trim(),
            SavedAt = DateTimeOffset.UtcNow.ToString("O"),
        };

        var json = JsonSerializer.Serialize(payload, new JsonSerializerOptions
        {
            WriteIndented = true,
        });

        File.WriteAllText(path, json);

        if (!OperatingSystem.IsWindows())
        {
            try
            {
                File.SetUnixFileMode(
                    path,
                    UnixFileMode.UserRead | UnixFileMode.UserWrite);
            }
            catch
            {
                // best-effort: файловая система может не поддерживать UnixFileMode
            }
        }

        return path;
    }

    private sealed class TokenFile
    {
        public string Token { get; set; } = string.Empty;
        public string SavedAt { get; set; } = string.Empty;
    }
}
