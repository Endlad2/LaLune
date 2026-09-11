#!/usr/bin/env python3
"""
prepare_android_html.py

Подготавливает Android-версию фронтенда LaLune перед сборкой APK.

Что делает:
  1. Читает Frontend/app.html (общий Wails-шаблон).
  2. Заменяет плейсхолдеры {QTWEBCHANNEL_SCRIPT} и {API_SCRIPT}
     на единый тег <script src="android.js"></script>.
  3. Создаёт (если нужно) android.js — JS-мост между WebView и AndroidBridge.
  4. Копирует оба файла в Mobile/Android/app/src/main/assets/.

Запускать из корня проекта:
    python prepare_android_html.py
"""

import re
import shutil
import sys
from pathlib import Path

# ----------------------------- paths ------------------------------------

ROOT_DIR = Path(__file__).resolve().parent
FRONTEND_DIR = ROOT_DIR / "Frontend"
ANDROID_DIR = ROOT_DIR / "Mobile" / "Android"
ASSETS_DIR = ANDROID_DIR / "app" / "src" / "main" / "assets"

SRC_HTML = FRONTEND_DIR / "app.html"
DST_HTML = ASSETS_DIR / "app.html"
DST_JS = ASSETS_DIR / "android.js"

# ----------------------------- html -------------------------------------

# Заменяем ОБА тега <script src="{...}"></script> на один <script src="android.js"></script>.
# Поддерживаем оба возможных варианта записи: подряд и через перевод строки.
PLACEHOLDER_PATTERN = re.compile(
    r'<script\s+src="\{QTWEBCHANNEL_SCRIPT\}"></script>\s*'
    r'<script\s+src="\{API_SCRIPT\}"></script>',
    re.IGNORECASE,
)

ANDROID_SCRIPT_TAG = '<script src="android.js"></script>'

def build_android_html(src_path: Path) -> str:
    if not src_path.exists():
        raise FileNotFoundError(f"Не найден исходный HTML: {src_path}")

    content = src_path.read_text(encoding="utf-8")

    new_content, count = PLACEHOLDER_PATTERN.subn(ANDROID_SCRIPT_TAG, content)

    if count == 0:
        # Fallback: плейсхолдеры могут быть записаны по отдельности (напр. с другим
        # порядком атрибутов). Тогда чистим их построчно и вставляем тег перед </body>.
        content = re.sub(
            r'<script\s+src="\{QTWEBCHANNEL_SCRIPT\}"></script>',
            "",
            content,
            flags=re.IGNORECASE,
        )
        content = re.sub(
            r'<script\s+src="\{API_SCRIPT\}"></script>',
            "",
            content,
            flags=re.IGNORECASE,
        )
        new_content = content.replace("</body>", f"    {ANDROID_SCRIPT_TAG}\n</body>")
        print("  [WARN] Плейсхолдеры не найдены подряд — вставил тег вручную перед </body>")
    else:
        print(f"  [OK] Заменено {count} блок(ов) плейсхолдеров на <script src=\"android.js\">")

    return new_content

# ----------------------------- android.js --------------------------------

ANDROID_JS_CONTENT = r"""/*
 * android.js — JS-мост между WebView и Kotlin AndroidBridge.
 *
 * Переопределяет window.api (или создаёт его), чтобы фронтенд
 * (Frontend/app.html) работал одинаково и в Wails, и в Android.
 *
 * Точка входа со стороны Kotlin: window.lalune.<method>().
 * Все методы синхронные, возвращают строку/boolean — как ожидает фронт.
 */

(function () {
    "use strict";

    if (typeof window.lalune === "undefined") {
        console.error("[android.js] window.lalune не найден — AndroidBridge не подключён");
        return;
    }

    // Универсальная обёртка: ловит исключения, чтобы UI не падал молча.
    function safe(fn, fallback) {
        try {
            return fn();
        } catch (e) {
            console.error("[android.js] Ошибка вызова:", e);
            return fallback;
        }
    }

    var api = {
        // ---- конфиги ----
        GetConfigsJson: function () {
            return safe(function () { return window.lalune.getConfigs(); }, "[]");
        },
        SaveConfig: function (link) {
            return safe(function () { return window.lalune.saveConfig(link); }, false);
        },
        DeleteConfig: function (id) {
            return safe(function () { return window.lalune.deleteConfig(Number(id)); }, false);
        },

        // ---- настройки ----
        GetSettingsJson: function () {
            return safe(function () { return window.lalune.getSettings(); }, "{}");
        },
        SaveSettings: function (json) {
            return safe(function () { return window.lalune.saveSettings(json); }, false);
        },

        // ---- логи ----
        GetLogsJson: function () {
            return safe(function () { return window.lalune.getLogs(); }, "[]");
        },
        ClearLogs: function () {
            return safe(function () { return window.lalune.clearLogs(); }, false);
        },

        // ---- статус ----
        GetStatusJson: function () {
            return safe(function () { return window.lalune.getStatus(); }, '{"connected":false}');
        },

        // ---- подключение ----
        Connect: function (configId) {
            return safe(function () { return window.lalune.connect(Number(configId)); }, false);
        },
        Disconnect: function () {
            return safe(function () { return window.lalune.disconnect(); }, false);
        },

        // ---- обновления ----
        CheckUpdate: function () {
            return safe(function () { return window.lalune.checkUpdate(); }, '{"update":false,"version":""}');
        },
        UpdateCore: function () {
            return safe(function () { return window.lalune.updateCore(); }, false);
        },
        UpdateCoreAndWait: function () {
            return safe(function () { return window.lalune.updateCoreAndWait(); }, false);
        },
    };

    // Экспортируем в window — фронт обращается к window.api.*
    window.api = api;

    // На случай, если фронт использует Wails-стайл window.go.main.App.*
    window.go = {
        main: {
            App: api,
        },
    };

    console.log("[android.js] Мост инициализирован");
})();
"""

def write_android_js(dst_path: Path) -> None:
    dst_path.parent.mkdir(parents=True, exist_ok=True)
    dst_path.write_text(ANDROID_JS_CONTENT, encoding="utf-8")
    print(f"  [OK] Записан android.js → {dst_path}")

# ----------------------------- main --------------------------------------

def main() -> int:
    print("=== prepare_android_html.py ===")
    print(f"Корень проекта: {ROOT_DIR}")

    if not ANDROID_DIR.exists():
        print(f"[ERROR] Не найдена папка Android: {ANDROID_DIR}")
        return 1

    ASSETS_DIR.mkdir(parents=True, exist_ok=True)
    print(f"[OK] Папка assets: {ASSETS_DIR}")

    # 1) HTML
    print("\n[1/3] Обработка Frontend/app.html ...")
    try:
        html = build_android_html(SRC_HTML)
    except Exception as e:
        print(f"[ERROR] {e}")
        return 1

    DST_HTML.write_text(html, encoding="utf-8")
    print(f"  [OK] Записан app.html → {DST_HTML}")

    # 2) android.js
    print("\n[2/3] Генерация android.js ...")
    write_android_js(DST_JS)

    # 3) Проверка
    print("\n[3/3] Проверка результата:")
    for p in (DST_HTML, DST_JS):
        size = p.stat().st_size
        print(f"  {p.relative_to(ROOT_DIR)}  —  {size} байт")

    print("\n=== Готово. Можно собирать APK. ===")
    return 0

if __name__ == "__main__":
    sys.exit(main())
