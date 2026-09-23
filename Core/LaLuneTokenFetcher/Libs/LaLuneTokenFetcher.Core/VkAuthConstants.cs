// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// Константы и правила авторизации ВКонтакте — единый источник правды
// для Windows- и Linux-сборок. Значения идентичны тем, что используются
// во Flutter-приложении FOCSQ (frontend/lib/service/vk/token.dart).

namespace LaLuneTokenFetcher.Core;

/// <summary>
/// Параметры OAuth-запроса VK. Все строки — точные копии из FOCSQ.
/// </summary>
public static class VkAuthConstants
{
    public const string ClientId = "2274003";
    public const string Scope = "1073737727";
    public const string RedirectUri = "https://oauth.vk.ru/blank.html";

    /// <summary>
    /// URL страницы авторизации. Порядок параметров сохранён как в оригинале,
    /// чтобы поведение VK-редиректа не отличалось.
    /// </summary>
    public const string AuthUrl =
        "https://oauth.vk.ru/authorize?" +
        "client_id=" + ClientId + "&" +
        "scope=" + Scope + "&" +
        "redirect_uri=" + "https%3A%2F%2Foauth.vk.ru%2Fblank.html" + "&" +
        "display=page&" +
        "response_type=token&" +
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
