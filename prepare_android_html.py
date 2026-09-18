#!/usr/bin/env python3
"""
prepare_android_html.py — устаревший скрипт.

Теперь эта роль полностью возложена на build_frontend.py:
    python build_frontend.py --platform Android

Он собирает Dart-фронтенд в Frontend/output/ и копирует нужный
Api/android.js как api.js.

Чтобы не ломать существующие workflow, этот скрипт оставлен как
тонкая обёртка: он вызывает build_frontend.py и копирует результат
в Mobile/Android/app/src/main/assets/.

Использование:
    python prepare_android_html.py
"""

import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
FRONTEND_OUTPUT = ROOT / "Frontend" / "output"
ANDROID_ASSETS = ROOT / "Mobile" / "Android" / "app" / "src" / "main" / "assets"

def log(msg: str) -> None:
    print(f"[prepare_android] {msg}", flush=True)

def die(msg: str) -> None:
    print(f"[prepare_android][ERROR] {msg}", file=sys.stderr, flush=True)
    sys.exit(1)

def main() -> int:
    log("Делегирую сборку фронтенда в build_frontend.py")

    # 1) Собрать фронтенд для Android
    result = subprocess.run(
        [sys.executable, str(ROOT / "build_frontend.py"), "--platform", "Android"],
        cwd=str(ROOT),
        text=True,
        encoding="utf-8",
        errors="replace",
    )
    if result.returncode != 0:
        die(f"build_frontend.py упал с кодом {result.returncode}")

    if not FRONTEND_OUTPUT.exists():
        die(f"После сборки нет {FRONTEND_OUTPUT}")

    index = FRONTEND_OUTPUT / "index.html"
    api_js = FRONTEND_OUTPUT / "api.js"
    if not index.exists():
        die(f"Нет index.html в {FRONTEND_OUTPUT}")
    if not api_js.exists():
        die(f"Нет api.js в {FRONTEND_OUTPUT}")

    # 2) Очистить и скопировать в assets Android
    if ANDROID_ASSETS.exists():
        shutil.rmtree(ANDROID_ASSETS)
    ANDROID_ASSETS.mkdir(parents=True, exist_ok=True)

    log(f"Копирую {FRONTEND_OUTPUT} → {ANDROID_ASSETS}")
    for item in FRONTEND_OUTPUT.iterdir():
        dst = ANDROID_ASSETS / item.name
        if item.is_dir():
            shutil.copytree(item, dst)
        else:
            shutil.copy2(item, dst)

    count = sum(1 for _ in ANDROID_ASSETS.rglob("*") if _.is_file())
    log(f"Скопировано файлов: {count}")

    # 3) Проверим, что api.js и index.html на месте
    for required in ("index.html", "api.js"):
        p = ANDROID_ASSETS / required
        if not p.exists():
            die(f"После копирования нет {required} в {ANDROID_ASSETS}")
        log(f"OK: {required} ({p.stat().st_size} байт)")

    log("Готово.")
    return 0

if __name__ == "__main__":
    sys.exit(main())
