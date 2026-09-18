#!/usr/bin/env python3
"""
build_frontend.py — подготовка Flutter-проекта к нативной сборке.

Больше не собирает web. Просто:
  1. Копирует Assets/* → Frontend/Core/assets/
  2. flutter pub get

Сборка самого бинарника — в build_desktop.py (Desktop) или gradle (Android).

Использование:
    python build_frontend.py --platform Android
    python build_frontend.py --platform Linux
    python build_frontend.py --platform Windows
"""

import argparse
import os
import platform
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
FRONTEND = ROOT / "Frontend"
DART_CORE = FRONTEND / "Core"
DART_ASSETS = DART_CORE / "assets"
ASSETS = ROOT / "Assets"

IS_WINDOWS = platform.system() == "Windows"

PLATFORMS = ["Android", "Linux", "Windows", "IOS"]

def log(msg: str) -> None:
    print(f"[build_frontend] {msg}", flush=True)

def die(msg: str) -> None:
    print(f"[build_frontend][ERROR] {msg}", file=sys.stderr, flush=True)
    sys.exit(1)

def find_flutter() -> str:
    for name in (["flutter.bat", "flutter"] if IS_WINDOWS else ["flutter"]):
        found = shutil.which(name)
        if found:
            return found
    die("flutter not found in PATH")
    return ""

def copy_assets() -> None:
    if not ASSETS.exists():
        log(f"WARN: {ASSETS} не найден, пропускаю")
        return
    if DART_ASSETS.exists():
        shutil.rmtree(DART_ASSETS)
    DART_ASSETS.mkdir(parents=True, exist_ok=True)
    count = 0
    for item in ASSETS.iterdir():
        if item.is_file():
            shutil.copy2(item, DART_ASSETS / item.name)
            count += 1
    log(f"Assets: {count} файл(ов) → {DART_ASSETS}")

def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--platform", required=True, choices=PLATFORMS)
    args = parser.parse_args()

    log(f"Platform: {args.platform}")

    if not DART_CORE.exists():
        die(f"Flutter-проект не найден: {DART_CORE}")

    copy_assets()

    flutter = find_flutter()
    log(f"flutter pub get (cwd: {DART_CORE})")
    subprocess.run([flutter, "pub", "get"], cwd=str(DART_CORE), check=True)

    log(f"Готово. Проект: {DART_CORE}")
    return 0

if __name__ == "__main__":
    sys.exit(main())
