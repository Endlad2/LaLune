// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// Константы и правила авторизации ВКонтакте — единый источник правды
// для всех платформ (Playwright).
//
// ВАЖНО: ранее здесь использовался хост oauth.vk.ru и display=page, из-за
// чего VK отвечал:
//   {"error":"invalid_request",
//    "error_description":"incorrect app. Unavailable for apps with direct auth."}
// Это означало, что для приложения 2274003 не разрешён implicit-flow
// (response_type=token) на указанном хосте/redirect_uri.
//
// Рабочая конфигурация (как в оригинальном Flutter-клиенте FOCSQ):
//   host          = https://oauth.vk.com
//   redirect_uri  = https://oauth.vk.com/blank.html
//   display       = mobile
//   response_type = token
// При успешном входе VK редиректит на blank.html и кладёт access_token
// во фрагмент URL, который читает Playwright.

namespace LaLuneTokenFetcher.Core;

/// <summary>
/// Параметры OAuth-запроса VK. Все строки — точные копии из FOCSQ.
/// </summary>
public static class VkAuthConstants
{
    public const string ClientId = "2274003";
    public const string Scope = "1073737727";
    public const string RedirectUri = "https://oauth.vk.com/blank.html";

    /// <summary>
    /// URL страницы авторизации. Используем oauth.vk.com (совпадает с
    /// redirect_uri) и display=mobile — это снимает ошибку
    /// "incorrect app. Unavailable for apps with direct auth.".
    /// </summary>
    public const string AuthUrl =
        "https://oauth.vk.com/authorize?" +
        "client_id=" + ClientId + "&" +
        "scope=" + Scope + "&" +
        "redirect_uri=" + "https%3A%2F%2Foauth.vk.com%2Fblank.html" + "&" +
        "display=mobile&" +
        "response_type=token&" +
        "v=5.199";

    /// <summary>Хосты, на которые VK редиректит после успешного входа.</summary>
    public static readonly string[] BlankHosts = { "oauth.vk.com", "oauth.vk.ru" };

    /// <summary>Путь страницы-заглушки, на которую приходит access_token во фрагменте.</summary>
    public const string BlankPath = "/blank.html";

    /// <summary>Тайм-аут ожидания токена — как в оригинальном Flutter-коде (5 минут).</summary>
    public static readonly TimeSpan Timeout = TimeSpan.FromMinutes(5);

    /// <summary>Интервал опроса window.location.href, мс. В оригинале — 500.</summary>
    public const int PollIntervalMs = 500;
}