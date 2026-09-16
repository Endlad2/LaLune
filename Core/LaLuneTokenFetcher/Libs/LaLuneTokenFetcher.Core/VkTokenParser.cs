// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// Разбор URL редиректа VK и извлечение access_token из фрагмента.
// Логика идентична оригинальному Flutter-коду:
//   parsed.host == "oauth.vk.ru" || "oauth.vk.com"
//   parsed.path == "/blank.html"
//   token = queryParameters["access_token"] после замены '#' на '?'

namespace LaLuneTokenFetcher.Core;

public static class VkTokenParser
{
    /// <summary>
    /// Проверяет, что URL — это редирект VK на blank.html.
    /// </summary>
    public static bool IsBlankRedirect(string url)
    {
        if (string.IsNullOrEmpty(url)) return false;
        if (!Uri.TryCreate(url, UriKind.Absolute, out var parsed)) return false;

        var hostOk = Array.Exists(
            VkAuthConstants.BlankHosts,
            h => string.Equals(h, parsed.Host, StringComparison.OrdinalIgnoreCase));
        if (!hostOk) return false;

        return string.Equals(
            parsed.AbsolutePath,
            VkAuthConstants.BlankPath,
            StringComparison.OrdinalIgnoreCase);
    }

    /// <summary>
    /// Извлекает access_token из URL редиректа. Возвращает null, если токена нет.
    /// </summary>
    public static string? ExtractAccessToken(string url)
    {
        if (!IsBlankRedirect(url)) return null;

        // Фрагмент "#access_token=...&expires_in=0&user_id=..." — заменяем '#' на '?',
        // чтобы Uri корректно распарсил query.
        var normalized = url.Replace('#', '?');
        if (!Uri.TryCreate(normalized, UriKind.Absolute, out var parsed)) return null;

        var token = ExtractQueryParam(parsed.Query, "access_token");
        return string.IsNullOrEmpty(token) ? null : token;
    }

    /// <summary>
    /// Извлекает значение параметра из query-строки ("a=1&b=2").
    /// </summary>
    public static string? ExtractQueryParam(string query, string key)
    {
        if (string.IsNullOrEmpty(query)) return null;
        query = query.TrimStart('?');

        foreach (var pair in query.Split('&', StringSplitOptions.RemoveEmptyEntries))
        {
            var eq = pair.IndexOf('=');
            if (eq <= 0) continue;
            var k = pair.Substring(0, eq);
            if (!string.Equals(k, key, StringComparison.Ordinal)) continue;
            var v = pair.Substring(eq + 1);
            return Uri.UnescapeDataString(v);
        }
        return null;
    }
}
