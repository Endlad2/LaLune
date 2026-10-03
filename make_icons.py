#!/usr/bin/env python3
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
#
# make_icons.py — генератор иконок для LaLune.
#
# Берёт Assets/icon.png (1024×1024) и делает:
#   1. Assets/icon_foreground.png          — для adaptive-icon Android
#      (символ по центру, отступ 25% от краёв, прозрачный фон)
#   2. Frontend/windows/runner/resources/app_icon.ico
#      (многоразмерный ICO: 16, 24, 32, 48, 64, 128, 256)
#   3. icon.ico                            — в корне репо
#      (качается install.ps1 для ярлыков Desktop / Start Menu)
#
# После этого запусти flutter_launcher_icons для Android/iOS:
#     cd Frontend && flutter pub run flutter_launcher_icons
#
# Использование:
#   python make_icons.py
#   python make_icons.py --source Assets/icon.png
#
# Требования:
#   pip install Pillow

import argparse
import sys
from pathlib import Path

try:
    from PIL import Image
except ImportError:
    print("[make_icons] Pillow не установлен. Установи: pip install Pillow",
          file=sys.stderr)
    sys.exit(1)

ROOT = Path(__file__).resolve().parent

# ────────────────────────────────────────────────────────────────
#  Настройки
# ────────────────────────────────────────────────────────────────

DEFAULT_SOURCE = ROOT / "Assets" / "icon.png"
FOREGROUND_OUT = ROOT / "Assets" / "icon_foreground.png"
ICO_WINDOWS_OUT = ROOT / "Frontend" / "windows" / "runner" / "resources" / "app_icon.ico"
ICO_ROOT_OUT = ROOT / "icon.ico"

# Отступ для adaptive-icon Android.
# Google требует: safe zone 66dp в центре 108dp → примерно 25% от краёв.
FOREGROUND_PADDING_RATIO = 0.25

# Размеры для .ico (Windows сам выберет нужный).
ICO_SIZES = [16, 24, 32, 48, 64, 128, 256]

# ────────────────────────────────────────────────────────────────
#  Логирование
# ────────────────────────────────────────────────────────────────

def log(msg: str) -> None:
    print(f"[make_icons] {msg}", flush=True)

def fail(msg: str, code: int = 1) -> None:
    print(f"[make_icons][ERROR] {msg}", file=sys.stderr, flush=True)
    sys.exit(code)

# ────────────────────────────────────────────────────────────────
#  Шаги
# ────────────────────────────────────────────────────────────────

def make_foreground(src: Image.Image) -> None:
    """
    Готовит foreground для adaptive-icon Android.

    Берём исходник (обычно с фоном), уменьшаем до 75% и центруем
    на прозрачном холсте того же размера. Так требует Google:
    safe zone — центральные 66dp из 108dp.

    ВАЖНО: если исходник УЖЕ с прозрачным фоном и символом по центру
    (как ожидает flutter_launcher_icons), то этот шаг может обрезать
    символ слишком сильно. Проверь результат визуально.
    """
    size = src.size[0]
    inner = int(size * (1.0 - 2 * FOREGROUND_PADDING_RATIO))

    # Конвертируем в RGBA (на случай индекса/палитры).
    src_rgba = src.convert("RGBA")

    # Ресайзим с сохранением пропорций.
    inner_img = src_rgba.copy()
    inner_img.thumbnail((inner, inner), Image.LANCZOS)

    # Холст с прозрачным фоном.
    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))

    # Центрируем.
    x = (size - inner_img.size[0]) // 2
    y = (size - inner_img.size[1]) // 2
    canvas.paste(inner_img, (x, y), inner_img)

    canvas.save(FOREGROUND_OUT, "PNG", optimize=True)
    log(f"foreground: {FOREGROUND_OUT.relative_to(ROOT)} ({canvas.size[0]}×{canvas.size[1]})")

def make_ico(src: Image.Image, dest: Path) -> None:
    """Сохраняет многоразмерный .ico."""
    dest.parent.mkdir(parents=True, exist_ok=True)

    # ICO требует RGBA или RGB. Приводим к RGBA (для прозрачности).
    src_rgba = src.convert("RGBA")

    # Pillow сам сгенерирует из одного изображения все sizes.
    src_rgba.save(
        dest,
        format="ICO",
        sizes=[(s, s) for s in ICO_SIZES],
    )
    size_kb = dest.stat().st_size / 1024
    log(f"ico: {dest.relative_to(ROOT)} ({size_kb:.1f} KB, sizes={ICO_SIZES})")

# ────────────────────────────────────────────────────────────────
#  Main
# ────────────────────────────────────────────────────────────────

def main() -> int:
    parser = argparse.ArgumentParser(description="Генератор иконок LaLune")
    parser.add_argument(
        "--source",
        default=str(DEFAULT_SOURCE),
        help=f"путь к исходному PNG (по умолчанию: {DEFAULT_SOURCE.relative_to(ROOT)})",
    )
    args = parser.parse_args()

    src_path = Path(args.source)
    if not src_path.is_absolute():
        src_path = ROOT / src_path

    if not src_path.exists():
        fail(f"исходник не найден: {src_path}")

    log(f"источник: {src_path.relative_to(ROOT)}")

    # Открываем.
    try:
        src = Image.open(src_path)
    except Exception as e:
        fail(f"не могу открыть PNG: {e}")

    log(f"размер: {src.size[0]}×{src.size[1]}, режим: {src.mode}")

    if src.size[0] != src.size[1]:
        log(f"WARN: изображение не квадратное ({src.size[0]}×{src.size[1]}), "
            "flutter_launcher_icons всё равно возьмёт его, но лучше "
            "использовать 1024×1024")

    # 1. Foreground для adaptive-icon.
    make_foreground(src)

    # 2. Windows .ico.
    make_ico(src, ICO_WINDOWS_OUT)

    # 3. Корневой icon.ico (для ярлыков Windows через install.ps1).
    make_ico(src, ICO_ROOT_OUT)

    print()
    log("готово.")
    print()
    print("  Дальше:")
    print("    cd Frontend")
    print("    flutter pub get")
    print("    flutter pub run flutter_launcher_icons")
    print()
    print("  Это перезапишет Android mipmap-*/ и iOS AppIcon.appiconset/.")
    print()

    return 0

if __name__ == "__main__":
    sys.exit(main())
