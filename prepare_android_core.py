#!/usr/bin/env python3
"""
prepare_android_core.py — копирует Java-классы из Core/ в Android-проект
с заменой package на com.lalune.app.

После миграции Android-проект живёт в Frontend/Core/android/.

Что делает:
  1. Читает все .java в Core/.
  2. Заменяет `package com.lalune.tokenfetcher;` (или уже `com.lalune.app`)
     на целевой package.
  3. Копирует результат в
     Frontend/Core/android/app/src/main/java/com/lalune/app/

Использование:
    python prepare_android_core.py
    python prepare_android_core.py --package com.custom.pkg
    python prepare_android_core.py --dest /custom/path
"""

import argparse
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
CORE_DIR = ROOT / "Core"
DEFAULT_PACKAGE = "com.lalune.app"
DEFAULT_SRC_PACKAGE = "com.lalune.tokenfetcher"

# Куда копируем по умолчанию.
DEFAULT_DEST = (
    ROOT / "Frontend" / "Core" / "android" / "app" / "src" / "main" / "java"
)

if sys.stdout.encoding and sys.stdout.encoding.lower() not in ("utf-8", "utf8"):
    try:
        sys.stdout.reconfigure(encoding="utf-8")
    except Exception:
        pass

def log(msg: str) -> None:
    try:
        print(f"[prepare_android_core] {msg}", flush=True)
    except UnicodeEncodeError:
        print(f"[prepare_android_core] {msg.encode('ascii', 'replace').decode('ascii')}",
              flush=True)

def die(msg: str) -> None:
    print(f"[prepare_android_core][ERROR] {msg}", file=sys.stderr, flush=True)
    sys.exit(1)

def package_to_dir(pkg: str) -> Path:
    return Path(*pkg.split("."))

def rewrite_package(content: str, src_pkg: str, dst_pkg: str) -> str:
    """
    Заменяет package-декларацию. Поддерживает три варианта исходного пакета:
      - com.lalune.tokenfetcher (дефолт)
      - com.lalune.app         (если файл уже в целевом пакете)
    """
    pattern = re.compile(
        r"^(\s*package\s+)(?:com\.lalune\.tokenfetcher|com\.lalune\.app)(\s*;)",
        re.MULTILINE,
    )
    new_content, n = pattern.subn(r"\g<1>" + dst_pkg + r"\g<2>", content, count=1)
    if n == 0:
        log(f"  [WARN] package-декларация не найдена, копирую без замены")
    return new_content

def main() -> int:
    parser = argparse.ArgumentParser(description="Prepare Android Core Java sources")
    parser.add_argument("--package", default=DEFAULT_PACKAGE,
                        help=f"Целевой package (по умолчанию {DEFAULT_PACKAGE})")
    parser.add_argument("--src-package", default=DEFAULT_SRC_PACKAGE,
                        help=f"Исходный package в Core/ (по умолчанию {DEFAULT_SRC_PACKAGE})")
    parser.add_argument("--dest", default=str(DEFAULT_DEST),
                        help=f"Куда копировать java-файлы "
                             f"(по умолчанию {DEFAULT_DEST.relative_to(ROOT)})")
    args = parser.parse_args()

    if not CORE_DIR.exists():
        log(f"Core/ не найден: {CORE_DIR}, пропускаю")
        return 0

    java_files = sorted(CORE_DIR.glob("*.java"))
    if not java_files:
        log("Core/ пуст, пропускаю")
        return 0

    base_dest = Path(args.dest)
    if not base_dest.is_absolute():
        base_dest = ROOT / base_dest

    dst_dir = base_dest / package_to_dir(args.package)
    dst_dir.mkdir(parents=True, exist_ok=True)

    log(f"Package: {args.src_package} -> {args.package}")
    log(f"Destination: {dst_dir}")

    count = 0
    for src in java_files:
        content = src.read_text(encoding="utf-8")
        rewritten = rewrite_package(content, args.src_package, args.package)
        dst = dst_dir / src.name
        dst.write_text(rewritten, encoding="utf-8")
        log(f"  {src.name} -> {dst.relative_to(ROOT)}")
        count += 1

    log(f"Готово: {count} файл(ов)")
    return 0

if __name__ == "__main__":
    sys.exit(main())