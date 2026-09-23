#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 luminescq
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
#
# build_token_grabber.py — сборка LaLuneTokenFetcher (Playwright).
#
# Корень проекта — папка с этим скриптом (рядом с Core/, Desktop/, ...).
# Результат складывается в Core/LaLuneTokenFetcher/output/.
#
# Использование:
#   python build_token_grabber.py --platform=Windows
#   python build_token_grabber.py --platform=Linux
#   python build_token_grabber.py --platform=Windows --clean
#
# Что делает:
#   1. Проверяет наличие dotnet SDK.
#   2. Запускает dotnet publish для единого Playwright-проекта с нужным RID.
#   3. Копирует файлы в Core/LaLuneTokenFetcher/output/LaLuneTokenFetcher/,
#      предварительно очищая папку (если передан --clean) или перезаписывая.
#
# Требования:
#   - Python 3.8+
#   - .NET 8 SDK
#   - Chromium устанавливается в рантайме через `playwright install chromium`
#     (это делает Go-бэкенд LaLune, см. Desktop/Libs/vkplaywright.go).

import argparse
import shutil
import subprocess
import sys
from pathlib import Path

# Корень проекта — папка с этим скриптом. Результат — в Core/LaLuneTokenFetcher/.
PROJECT_ROOT = Path(__file__).resolve().parent
GRABBER_ROOT = PROJECT_ROOT / "Core" / "LaLuneTokenFetcher"
PLAYWRIGHT_PROJECT = GRABBER_ROOT / "Playwright" / "LaLuneTokenFetcher.Playwright.csproj"
OUTPUT_DIR = GRABBER_ROOT / "output" / "LaLuneTokenFetcher"

PLATFORMS = {
    "Windows": {
        "rid": "win-x64",
        "publish_subdir": Path("bin") / "Release" / "net8.0" / "win-x64" / "publish",
        "binary_name": "LaLuneTokenFetcher.exe",
    },
    "Linux": {
        "rid": "linux-x64",
        "publish_subdir": Path("bin") / "Release" / "net8.0" / "linux-x64" / "publish",
        "binary_name": "LaLuneTokenFetcher",
    },
}

def log(msg: str) -> None:
    print(f"[build] {msg}", flush=True)

def fail(msg: str, code: int = 1) -> None:
    print(f"[build] ошибка: {msg}", file=sys.stderr, flush=True)
    sys.exit(code)

def run(cmd: list[str], cwd: Path | None = None) -> None:
    log("$ " + " ".join(str(c) for c in cmd))
    result = subprocess.run(cmd, cwd=cwd)
    if result.returncode != 0:
        fail(f"команда завершилась с кодом {result.returncode}")

def which(name: str) -> str | None:
    return shutil.which(name)

def check_dotnet() -> None:
    if which("dotnet") is None:
        fail("dotnet SDK не найден в PATH. Установите .NET 8 SDK: "
             "https://dotnet.microsoft.com/download/dotnet/8.0")

def clean_output() -> None:
    if OUTPUT_DIR.exists():
        log(f"удаляю {OUTPUT_DIR}")
        shutil.rmtree(OUTPUT_DIR)
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

def copy_tree(src: Path, dst: Path) -> None:
    """Рекурсивно копирует содержимое src в dst, создавая dst."""
    dst.mkdir(parents=True, exist_ok=True)
    for entry in src.iterdir():
        target = dst / entry.name
        if entry.is_dir():
            shutil.copytree(entry, target, dirs_exist_ok=True)
        else:
            shutil.copy2(entry, target)

def build(platform: str, clean: bool) -> None:
    cfg = PLATFORMS.get(platform)
    if cfg is None:
        fail(f"неизвестная платформа: {platform}. "
             f"Допустимые значения: {', '.join(PLATFORMS.keys())}")

    log(f"корень проекта: {PROJECT_ROOT}")
    log(f"исходники:      {GRABBER_ROOT}")
    log(f"платформа:      {platform}")
    log(f"проект:         {PLAYWRIGHT_PROJECT}")

    if not PLAYWRIGHT_PROJECT.exists():
        fail(f"не найден .csproj: {PLAYWRIGHT_PROJECT}")

    check_dotnet()

    # Собираем единый Playwright-проект (self-contained настройки в .csproj).
    run([
        "dotnet", "publish",
        str(PLAYWRIGHT_PROJECT),
        "-c", "Release",
        "-r", cfg["rid"],
    ])

    publish_dir = PLAYWRIGHT_PROJECT.parent / cfg["publish_subdir"]
    if not publish_dir.exists():
        fail(f"папка публикации не найдена: {publish_dir}")

    if clean:
        clean_output()
    else:
        OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

    log(f"копирую файлы из {publish_dir} в {OUTPUT_DIR}")
    copy_tree(publish_dir, OUTPUT_DIR)

    # Содержимое output/.
    log("содержимое output/LaLuneTokenFetcher/:")
    for entry in sorted(OUTPUT_DIR.iterdir()):
        if entry.is_file():
            size_mb = entry.stat().st_size / (1024 * 1024)
            print(f"  {entry.name}  ({size_mb:.2f} МБ)")
        else:
            print(f"  {entry.name}/")

    # Финальная проверка.
    binary = OUTPUT_DIR / cfg["binary_name"]
    print()
    log("готово.")
    if binary.exists():
        print(f"[build] бинарь: {binary}")
    else:
        print(f"[build] ВНИМАНИЕ: бинарник не найден: {binary}")

def main() -> int:
    parser = argparse.ArgumentParser(
        description="Сборка LaLuneTokenFetcher (Core/LaLuneTokenFetcher, Playwright) "
                    "для Windows или Linux.",
    )
    parser.add_argument(
        "--platform",
        required=True,
        choices=list(PLATFORMS.keys()),
        help="целевая платформа сборки.",
    )
    parser.add_argument(
        "--clean",
        action="store_true",
        help="очистить папку output/LaLuneTokenFetcher перед копированием.",
    )
    args = parser.parse_args()

    try:
        build(args.platform, args.clean)
    except KeyboardInterrupt:
        fail("прервано пользователем", code=130)

    return 0

if __name__ == "__main__":
    sys.exit(main())