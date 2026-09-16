// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// Абстракция получения токена. Реализации — Windows (WebView2) и Linux
// (обёртка над нативным C-хелпером).

namespace LaLuneTokenFetcher.Core;

public interface ITokenFetcher
{
    /// <summary>
    /// Открывает WebView с авторизацией VK и ждёт появления access_token
    /// в URL. Возвращает токен или null (тайм-аут / пользователь закрыл окно).
    /// </summary>
    Task<string?> FetchTokenAsync(CancellationToken cancellationToken = default);
}
