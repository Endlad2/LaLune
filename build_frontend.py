#!/usr/bin/env python3
"""
build_frontend.py — сборка Dart-фронтенда LaLune в готовый output/.

Что делает:
  1. Находит flutter (Windows .bat, PATH, FLUTTER_ROOT)
  2. Копирует Assets/* → Frontend/Core/assets/ (как есть, без обработки)
  3. flutter pub get + flutter build web --release
  4. Копирует Frontend/Core/build/web/* → Frontend/output/
  5. Копирует Api/<platform>.js → Frontend/output/api.js
  6. Перезаписывает output/index.html своим шаблоном

Использование:
    python build_frontend.py --platform Android
    python build_frontend.py --platform Linux
    python build_frontend.py --platform Windows
    python build_frontend.py --platform OpenWRT
    python build_frontend.py --platform IOS
"""

import argparse
import os
import platform
import shutil
import subprocess
import sys
from pathlib import Path

# ============================================================
#  Пути
# ============================================================

ROOT = Path(__file__).resolve().parent
FRONTEND = ROOT / "Frontend"
DART_CORE = FRONTEND / "Core"
DART_ASSETS = DART_CORE / "assets"
API_DIR = FRONTEND / "Api"
OUTPUT = FRONTEND / "output"
ASSETS = ROOT / "Assets"

API_FILES = {
    "Android": "android.js",
    "Linux": "desktop.js",
    "Windows": "desktop.js",
    "OpenWRT": "openwrt.js",
    "IOS": "ios.js",
}

IS_WINDOWS = platform.system() == "Windows"

# ============================================================
#  Логирование
# ============================================================

def log(msg: str) -> None:
    print(f"[build_frontend] {msg}", flush=True)

def warn(msg: str) -> None:
    print(f"[build_frontend][WARN] {msg}", flush=True)

def die(msg: str) -> None:
    print(f"[build_frontend][ERROR] {msg}", file=sys.stderr, flush=True)
    sys.exit(1)

# ============================================================
#  Поиск Flutter
# ============================================================

def find_flutter() -> str:
    flutter_root = os.environ.get("FLUTTER_ROOT")
    if flutter_root:
        candidate = Path(flutter_root) / "bin" / (
            "flutter.bat" if IS_WINDOWS else "flutter"
        )
        if candidate.is_file():
            log(f"Flutter из FLUTTER_ROOT: {candidate}")
            return str(candidate)

    names = (
        ["flutter.bat", "flutter.exe", "flutter.cmd", "flutter"]
        if IS_WINDOWS
        else ["flutter"]
    )

    for name in names:
        found = shutil.which(name)
        if found:
            log(f"Flutter найден в PATH: {found}")
            return found

    path_dirs = os.environ.get("PATH", "").split(os.pathsep)
    for d in path_dirs:
        if not d:
            continue
        for name in names:
            candidate = Path(d) / name
            if candidate.is_file():
                log(f"Flutter найден вручную: {candidate}")
                return str(candidate)

    if IS_WINDOWS:
        common_roots = [
            Path("C:/flutter"),
            Path("C:/src/flutter"),
            Path("C:/dev/flutter"),
            Path(os.path.expanduser("~/flutter")),
            Path(os.path.expanduser("~/src/flutter")),
            Path(os.path.expanduser("~/development/flutter")),
        ]
    else:
        common_roots = [
            Path("/opt/flutter"),
            Path("/usr/local/flutter"),
            Path.home() / "flutter",
            Path.home() / "development/flutter",
            Path.home() / "snap/flutter/common/flutter",
        ]

    for r in common_roots:
        candidate = r / "bin" / ("flutter.bat" if IS_WINDOWS else "flutter")
        if candidate.is_file():
            log(f"Flutter найден в стандартном месте: {candidate}")
            return str(candidate)

    die(
        "flutter не найден.\n"
        "  1) Установи Flutter: https://docs.flutter.dev/get-started/install\n"
        "  2) Добавь <flutter_dir>/bin в PATH и перезапусти терминал\n"
        "  3) Или задай переменную FLUTTER_ROOT=<flutter_dir>"
    )
    return ""

# ============================================================
#  Запуск Flutter
# ============================================================

def run_flutter(flutter: str, args: list, cwd: Path) -> None:
    log(f"$ {' '.join([Path(flutter).name] + args)}  (в {cwd})")

    if IS_WINDOWS and flutter.lower().endswith((".bat", ".cmd")):
        cmd = ["cmd.exe", "/c", flutter] + list(args)
    else:
        cmd = [flutter] + list(args)

    try:
        result = subprocess.run(
            cmd,
            cwd=str(cwd),
            check=False,
            text=True,
            encoding="utf-8",
            errors="replace",
        )
    except FileNotFoundError:
        die(f"не удалось запустить {flutter}")
        return
    except OSError as e:
        die(f"ошибка запуска {flutter}: {e}")
        return

    if result.returncode != 0:
        die(f"команда завершилась с кодом {result.returncode}: {' '.join(cmd)}")

# ============================================================
#  Шаг 1: Assets → Frontend/Core/assets/
# ============================================================

def copy_assets_to_dart() -> None:
    """
    Копирует Assets/* → Frontend/Core/assets/ как есть.
    Никакой обработки — пользователь сам подготовил картинки.
    """
    if not ASSETS.exists():
        warn(f"{ASSETS} не существует — картинок не будет")
        return

    if DART_ASSETS.exists():
        shutil.rmtree(DART_ASSETS)
    DART_ASSETS.mkdir(parents=True, exist_ok=True)

    count = 0
    for item in ASSETS.iterdir():
        if item.is_file():
            shutil.copy2(item, DART_ASSETS / item.name)
            log(f"  asset: {item.name}")
            count += 1

    if count == 0:
        warn(f"{ASSETS} пустой — ни одной картинки не скопировано")
    else:
        log(f"Скопировано ассетов: {count}")

# ============================================================
#  Шаг 2: flutter build web
# ============================================================

def build_dart(flutter: str) -> None:
    if not DART_CORE.exists():
        die(f"Не найден Dart-проект: {DART_CORE}")
    if not (DART_CORE / "pubspec.yaml").exists():
        die(f"Нет pubspec.yaml в {DART_CORE}")

    run_flutter(flutter, ["pub", "get"], cwd=DART_CORE)
    run_flutter(flutter, ["build", "web", "--release"], cwd=DART_CORE)

    built = DART_CORE / "build" / "web"
    if not built.exists():
        die(f"После сборки нет {built}")

    if OUTPUT.exists():
        shutil.rmtree(OUTPUT)
    OUTPUT.mkdir(parents=True)

    log(f"Копирую {built} → {OUTPUT}")
    for item in built.iterdir():
        dst = OUTPUT / item.name
        if item.is_dir():
            shutil.copytree(item, dst)
        else:
            shutil.copy2(item, dst)

# ============================================================
#  Шаг 3: api.js
# ============================================================

def copy_api(platform_name: str) -> None:
    if platform_name not in API_FILES:
        die(
            f"Неизвестная платформа: {platform_name}. "
            f"Доступные: {', '.join(API_FILES)}"
        )

    src = API_DIR / API_FILES[platform_name]
    if not src.exists():
        die(f"Не найден Api-файл: {src}")

    dst = OUTPUT / "api.js"
    shutil.copy2(src, dst)
    log(f"api.js ← {src.name}")

# ============================================================
#  Шаг 4: перезапись index.html
# ============================================================

INDEX_HTML_TEMPLATE = """<!DOCTYPE html>
<html lang="ru">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
    <meta name="apple-mobile-web-app-capable" content="yes">
    <meta name="mobile-web-app-capable" content="yes">
    <title>LaLune</title>
    <link rel="icon" href="data:,">
    <link href="https://fonts.googleapis.com/css2?family=Overpass+Mono:wght@300;400;600;700&display=swap" rel="stylesheet">
    <style>
        html, body {
            margin: 0;
            padding: 0;
            height: 100%;
            overflow: hidden;
            background: radial-gradient(ellipse at 20% 30%, #1a2a6c, #0a0e2a 60%, #04060f);
            font-family: 'Overpass Mono', monospace;
        }
        #loading {
            position: fixed;
            inset: 0;
            display: flex;
            align-items: center;
            justify-content: center;
            color: rgba(255,255,255,0.6);
            font-size: 14px;
            z-index: 9999;
            transition: opacity 0.4s ease;
        }
        #loading.hidden {
            opacity: 0;
            pointer-events: none;
        }
    </style>
</head>
<body>
    <div id="loading">Загрузка...</div>

    <script src="api.js"></script>

    <script>
        window.addEventListener('flutter-first-frame', function () {
            const loading = document.getElementById('loading');
            if (loading) {
                loading.classList.add('hidden');
                setTimeout(function () { loading.remove(); }, 500);
            }
        });
    </script>

    <script src="flutter_bootstrap.js" async></script>
</body>
</html>
"""

def write_index_html() -> None:
    index = OUTPUT / "index.html"
    index.write_text(INDEX_HTML_TEMPLATE, encoding="utf-8")
    log(f"Записал index.html ({len(INDEX_HTML_TEMPLATE)} байт)")

# ============================================================
#  main
# ============================================================

def main() -> int:
    parser = argparse.ArgumentParser(
        description="Сборка Dart-фронтенда LaLune в Frontend/output/",
    )
    parser.add_argument(
        "--platform",
        required=True,
        choices=list(API_FILES.keys()),
        help="Целевая платформа (выбирает, какой Api/*.js копировать)",
    )
    args = parser.parse_args()

    log(f"Платформа: {args.platform}")

    flutter = find_flutter()

    copy_assets_to_dart()
    build_dart(flutter)
    copy_api(args.platform)
    write_index_html()

    log(f"Готово. Результат: {OUTPUT}")
    return 0

if __name__ == "__main__":
    sys.exit(main())