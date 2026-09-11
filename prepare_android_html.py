#!/usr/bin/env python3
"""
prepare_android_html.py

Подготавливает Android-версию фронтенда LaLune перед сборкой APK.

Что делает:
  1. Читает Frontend/app.html (общий Wails-шаблон).
  2. Заменяет ОБА плейсхолдера:
       {QTWEBCHANNEL_SCRIPT}  -> удаляется
       {API_SCRIPT}           -> заменяется на <script src="android.js"></script>
  3. Копирует Frontend/android.js в assets/android.js (как есть).
  4. Копирует готовый app.html в assets/app.html.

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
SRC_JS = FRONTEND_DIR / "android.js"
DST_HTML = ASSETS_DIR / "app.html"
DST_JS = ASSETS_DIR / "android.js"

# ----------------------------- html -------------------------------------

ANDROID_SCRIPT_TAG = '<script src="android.js"></script>'

# Плейсхолдеры Wails-сборки. Могут идти подряд, могут — раздельно.
# Заменяем оба на один <script src="android.js">.
PAIR_PATTERN = re.compile(
    r'<script\s+src="\{QTWEBCHANNEL_SCRIPT\}"></script>\s*'
    r'<script\s+src="\{API_SCRIPT\}"></script>',
    re.IGNORECASE,
)

SINGLE_QTWEB = re.compile(
    r'<script\s+src="\{QTWEBCHANNEL_SCRIPT\}"></script>',
    re.IGNORECASE,
)

SINGLE_API = re.compile(
    r'<script\s+src="\{API_SCRIPT\}"></script>',
    re.IGNORECASE,
)

def build_android_html(src_path: Path) -> str:
    if not src_path.exists():
        raise FileNotFoundError(f"Не найден исходный HTML: {src_path}")

    content = src_path.read_text(encoding="utf-8")

    # Сначала пробуем заменить оба подряд — самый частый случай.
    content, pair_count = PAIR_PATTERN.subn(ANDROID_SCRIPT_TAG, content)

    if pair_count > 0:
        print(f"  [OK] Заменён блок плейсхолдеров ({pair_count} шт.) на {ANDROID_SCRIPT_TAG}")
        return content

    # Fallback: плейсхолдеры могут быть раздельно (или в другом порядке).
    had_any = False

    if SINGLE_API.search(content):
        content = SINGLE_API.sub(ANDROID_SCRIPT_TAG, content, count=1)
        had_any = True
        print(f"  [OK] {{API_SCRIPT}} -> {ANDROID_SCRIPT_TAG}")

    if SINGLE_QTWEB.search(content):
        content = SINGLE_QTWEB.sub("", content)
        had_any = True
        print("  [OK] {{QTWEBCHANNEL_SCRIPT}} удалён")

    if not had_any:
        # Плейсхолдеров вообще нет — вставим тег перед </body>,
        # чтобы фронт всё равно подхватил android.js.
        if "</body>" in content:
            content = content.replace(
                "</body>",
                f"    {ANDROID_SCRIPT_TAG}\n</body>",
            )
            print("  [WARN] Плейсхолдеры не найдены — вставил тег перед </body>")
        else:
            print("  [WARN] Плейсхолдеры не найдены и </body> отсутствует — ничего не вставлено")

    return content

# ----------------------------- main --------------------------------------

def main() -> int:
    print("=== prepare_android_html.py ===")
    print(f"Корень проекта: {ROOT_DIR}")

    if not ANDROID_DIR.exists():
        print(f"[ERROR] Не найдена папка Android: {ANDROID_DIR}")
        return 1

    if not SRC_JS.exists():
        print(f"[ERROR] Не найден Frontend/android.js: {SRC_JS}")
        print("        Создай его в Frontend/ — это JS-мост + UI-логика для Android.")
        return 1

    ASSETS_DIR.mkdir(parents=True, exist_ok=True)
    print(f"[OK] Папка assets: {ASSETS_DIR}")

    # 1) HTML — подставляем тег <script src="android.js">
    print("\n[1/2] Обработка Frontend/app.html ...")
    try:
        html = build_android_html(SRC_HTML)
    except Exception as e:
        print(f"[ERROR] {e}")
        return 1

    DST_HTML.write_text(html, encoding="utf-8")
    print(f"  [OK] Записан app.html → {DST_HTML}")

    # 2) JS — просто копируем Frontend/android.js в assets/
    print("\n[2/2] Копирование Frontend/android.js ...")
    shutil.copy2(SRC_JS, DST_JS)
    print(f"  [OK] Записан android.js → {DST_JS}")

    # Проверка
    print("\nПроверка результата:")
    for p in (DST_HTML, DST_JS):
        size = p.stat().st_size
        print(f"  {p.relative_to(ROOT_DIR)}  —  {size} байт")

    print("\n=== Готово. Можно собирать APK. ===")
    return 0

if __name__ == "__main__":
    sys.exit(main())
