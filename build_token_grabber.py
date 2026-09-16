#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 luminescq
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
#
# build_token_grabber.py — сборка LaLuneTokenFetcher под Windows или Linux.
#
# Скрипт лежит в корне проекта (рядом с Core/, Desktop/, Frontend/, ...).
# Исходники граббера — в Core/LaLuneTokenFetcher/.
#
# Использование:
#   python build_token_grabber.py --platform=Windows
#   python build_token_grabber.py --platform=Linux
#   python build_token_grabber.py --platform=Windows --clean
#
# Что делает:
#   1. Проверяет наличие dotnet SDK.
#   2. Для Linux — компилирует нативный C-хелпер (gcc + GTK + WebKitGTK).
#   3. Запускает dotnet publish для соответствующего .csproj.
#   4. Копирует артефакты в Core/LaLuneTokenFetcher/output/LaLuneTokenFetcher/,
#      полностью очищая её перед копированием (если передан --clean) или
#      перезаписывая поверх (по умолчанию).
#
# Требования:
#   - Python 3.8+
#   - .NET 8 SDK
#   - Для Linux: gcc, pkg-config, libgtk-3-dev, libwebkit2gtk-4.1-dev

import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path

# Скрипт лежит в корне проекта. Исходники граббера — в Core/LaLuneTokenFetcher/.
PROJECT_ROOT = Path(__file__).resolve().parent
GRABBER_ROOT = PROJECT_ROOT / "Core" / "LaLuneTokenFetcher"
OUTPUT_DIR = GRABBER_ROOT / "output" / "LaLuneTokenFetcher"

PLATFORMS = {
    "Windows": {
        "project": GRABBER_ROOT / "Windows" / "LaLuneTokenFetcher.Windows.csproj",
        "rid": "win-x64",
        "publish_subdir": Path("bin") / "Release" / "net8.0-windows" / "win-x64" / "publish",
        "binary_name": "LaLuneTokenFetcher.exe",
    },
    "Linux": {
        "project": GRABBER_ROOT / "Linux" / "LaLuneTokenFetcher.Linux.csproj",
        "rid": "linux-x64",
        "publish_subdir": Path("bin") / "Release" / "net8.0" / "linux-x64" / "publish",
        "binary_name": "LaLuneTokenFetcher",
    },
}

def log(msg: str) -> None:
    print(f"[build] {msg}", flush=True)

def fail(msg: str, code: int = 1) -> None:
    print(f"[build] ОШИБКА: {msg}", file=sys.stderr, flush=True)
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
        fail("dotnet SDK не найден в PATH. Установи .NET 8 SDK: "
             "https://dotnet.microsoft.com/download/dotnet/8.0")

def check_pkg_config(*packages: str) -> None:
    if which("pkg-config") is None:
        fail("pkg-config не найден. Установи pkg-config / pkgconf.")
    for pkg in packages:
        result = subprocess.run(
            ["pkg-config", "--exists", pkg],
            capture_output=True,
        )
        if result.returncode != 0:
            fail(f"pkg-config не нашёл пакет '{pkg}'. Установи dev-пакеты "
                 f"GTK/WebKitGTK для своего дистрибутива (см. "
                 f"Core/LaLuneTokenFetcher/Linux/README.md).")

def build_native_helper_linux() -> Path:
    """Компилирует la-lune-webview-helper и возвращает путь к бинарнику."""
    if which("gcc") is None:
        fail("gcc не найден. Установи build-essential / base-devel / gcc.")

    webkit_pkg = "webkit2gtk-4.1"
    if subprocess.run(
        ["pkg-config", "--exists", "webkit2gtk-4.1"]
    ).returncode != 0:
        if subprocess.run(
            ["pkg-config", "--exists", "webkit2gtk-4.0"]
        ).returncode == 0:
            webkit_pkg = "webkit2gtk-4.0"
        else:
            fail("Не найден webkit2gtk-4.1 или webkit2gtk-4.0. "
                 "Установи libwebkit2gtk-4.1-dev / webkit2gtk4.1-devel / "
                 "webkit2gtk-4.1.")

    check_pkg_config("gtk+-3.0", webkit_pkg)

    native_dir = GRABBER_ROOT / "Linux" / "native"
    src = native_dir / "la-lune-webview-helper.c"
    if not src.exists():
        fail(f"Не найден исходник хелпера: {src}")

    out = native_dir / "la-lune-webview-helper"

    pkg_flags = subprocess.run(
        ["pkg-config", "--cflags", "--libs", "gtk+-3.0", webkit_pkg],
        capture_output=True,
        text=True,
        check=True,
    ).stdout.split()

    run(["gcc", "-O2", "-Wall", "-o", str(out), str(src), *pkg_flags])
    log(f"Нативный хелпер собран: {out}")
    return out

def clean_output() -> None:
    if OUTPUT_DIR.exists():
        log(f"Очищаю {OUTPUT_DIR}")
        shutil.rmtree(OUTPUT_DIR)
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

def copy_tree(src: Path, dst: Path) -> None:
    """Копирует содержимое src в dst, создавая dst."""
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
        fail(f"Неизвестная платформа: {platform}. "
             f"Допустимые значения: {', '.join(PLATFORMS.keys())}")

    log(f"Корень проекта: {PROJECT_ROOT}")
    log(f"Исходники:      {GRABBER_ROOT}")
    log(f"Платформа:      {platform}")
    log(f"Проект:         {cfg['project']}")

    if not cfg["project"].exists():
        fail(f"Не найден .csproj: {cfg['project']}")

    check_dotnet()

    native_helper: Path | None = None
    if platform == "Linux":
        native_helper = build_native_helper_linux()

    # Публикация C#-бинарника.
    # SelfContained / PublishSingleFile уже прописаны в .csproj, поэтому
    # в командной строке их не дублируем — только -c Release и -r.
    run([
        "dotnet", "publish",
        str(cfg["project"]),
        "-c", "Release",
        "-r", cfg["rid"],
    ])

    publish_dir = cfg["project"].parent / cfg["publish_subdir"]
    if not publish_dir.exists():
        fail(f"Папка публикации не найдена: {publish_dir}")

    if clean:
        clean_output()
    else:
        OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

    log(f"Копирую артефакты из {publish_dir} в {OUTPUT_DIR}")
    copy_tree(publish_dir, OUTPUT_DIR)

    # На Linux — докидываем нативный хелпер, если его не оказалось в publish
    # (он копируется через <None Include="native\..." CopyToOutputDirectory>,
    # но на всякий случай проверим и скопируем явно).
    if platform == "Linux" and native_helper is not None:
        target = OUTPUT_DIR / "la-lune-webview-helper"
        if not target.exists():
            shutil.copy2(native_helper, target)
            log(f"Скопирован нативный хелпер: {target}")

    # Показываем содержимое output/.
    log("Содержимое output/LaLuneTokenFetcher/:")
    for entry in sorted(OUTPUT_DIR.iterdir()):
        if entry.is_file():
            size_mb = entry.stat().st_size / (1024 * 1024)
            print(f"  {entry.name}  ({size_mb:.2f} МБ)")
        else:
            print(f"  {entry.name}/")

    # Финальная подсказка.
    binary = OUTPUT_DIR / cfg["binary_name"]
    print()
    log("Готово.")
    if binary.exists():
        print(f"[build] Запуск: {binary}")
    else:
        print(f"[build] ВНИМАНИЕ: ожидаемый бинарник не найден: {binary}")

def main() -> int:
    parser = argparse.ArgumentParser(
        description="Сборка LaLuneTokenFetcher (Core/LaLuneTokenFetcher) "
                    "под Windows или Linux.",
    )
    parser.add_argument(
        "--platform",
        required=True,
        choices=list(PLATFORMS.keys()),
        help="Целевая платформа сборки.",
    )
    parser.add_argument(
        "--clean",
        action="store_true",
        help="Полностью очищать output/LaLuneTokenFetcher перед копированием.",
    )
    args = parser.parse_args()

    try:
        build(args.platform, args.clean)
    except KeyboardInterrupt:
        fail("прервано пользователем", code=130)

    return 0

if __name__ == "__main__":
    sys.exit(main())
