// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// Константы и правила авторизации ВКонтакте — единый источник правды
// для всех платформ (Playwright).
//
// Рабочая конфигурация (совпадает с оригинальным Flutter-клиентом FOCSQ,
// см. service/vk/token.dart):
//
//   client_id     = 7793118
//   host          = https://oauth.vk.ru
//   redirect_uri  = https://oauth.vk.ru/blank.html
//   display       = page
//   response_type = token
//   revoke        = 1
//   v             = 5.199
//
// ПОЧЕМУ ИМЕННО 7793118:
//   Это официальное приложение VK для Android. Для него разрешён
//   implicit-flow (response_type=token), и VK не отвечает ошибкой
//   "incorrect app. Unavailable for apps with direct auth.".
//
// ПОЧЕМУ НЕ 2274003:
//   Раньше здесь использовался client_id=2274003 (и хост oauth.vk.com,
//   display=mobile). Это давало ошибку:
//
//     {"error":"invalid_request",
//      "error_description":"incorrect app. Unavailable for apps with direct auth."}
//
//   Для приложения 2274003 VK не разрешает implicit-flow на указанном
//   redirect_uri, поэтому любой заход в WebView/Playwright сразу получал
//   эту ошибку. Возврат к 7793118 + oauth.vk.ru + display=page (как в
//   рабочем Flutter-клиенте) устраняет её.

namespace LaLuneTokenFetcher.Core;

/// <summary>
/// Параметры OAuth-запроса VK. Все строки — точные копии из FOCSQ
/// (service/vk/token.dart).
/// </summary>
public static class VkAuthConstants
{
    public const string ClientId = "7793118";
    public const string Scope = "1073737727";
    public const string RedirectUri = "https://oauth.vk.ru/blank.html";

    /// <summary>
    /// URL страницы авторизации. Используем oauth.vk.ru (совпадает с
    /// redirect_uri), display=page, revoke=1 — как в рабочем Flutter-клиенте.
    /// </summary>
    public const string AuthUrl =
        "https://oauth.vk.ru/authorize?" +
        "client_id=" + ClientId + "&" +
        "scope=" + Scope + "&" +
        "redirect_uri=" + "https%3A%2F%2Foauth.vk.ru%2Fblank.html" + "&" +
        "display=page&" +
        "response_type=token&" +
        "revoke=1&" +
        "v=5.199";

    /// <summary>Хосты, на которые VK редиректит после успешного входа.</summary>
    public static readonly string[] BlankHosts = { "oauth.vk.ru", "oauth.vk.com" };

    /// <summary>Путь страницы-заглушки, на которую приходит access_token во фрагменте.</summary>
    public const string BlankPath = "/blank.html";

    /// <summary>Тайм-аут ожидания токена — как в оригинальном Flutter-коде (5 минут).</summary>
    public static readonly TimeSpan Timeout = TimeSpan.FromMinutes(5);

    /// <summary>Интервал опроса window.location.href, мс. В оригинале — 500.</summary>
    public const int PollIntervalMs = 500;
}
