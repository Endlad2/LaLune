#!/usr/bin/env python3
"""
prepare_st.py — копирует Core/SmartTunnel.lua туда, где его читают рантаймы.

Использование:
    python prepare_st.py --platform=Linux
    python prepare_st.py --platform=Windows
    python prepare_st.py --platform=Android
    python prepare_st.py --platform=all

Что делает:
    - Linux   → Desktop/Libs/SmartTunnel.lua        (для go:embed)
    - Windows → Desktop/Libs/SmartTunnel.lua        (для go:embed)
    - Android → Mobile/Android/app/src/main/assets/SmartTunnel.lua
    - all     → все три сразу

ВАЖНО:
    go:embed SmartTunnel.lua в Desktop/Libs/smarttunnel.go ищет файл
    РЯДОМ с .go-файлом, то есть в Desktop/Libs/. Без этого шага
    `go build` падает с "pattern SmartTunnel.lua: no matching files found".

    Desktop/Libs/ — это единая папка для Linux и Windows, потому что
    build_desktop.py собирает go build из неё же.
"""

import argparse
import shutil
import sys
from pathlib import Path

# Windows Python по умолчанию использует cp1252 — форсируем UTF-8.
if sys.stdout.encoding and sys.stdout.encoding.lower() not in ("utf-8", "utf8"):
    try:
        sys.stdout.reconfigure(encoding="utf-8")
    except Exception:
        pass
if sys.stderr.encoding and sys.stderr.encoding.lower() not in ("utf-8", "utf8"):
    try:
        sys.stderr.reconfigure(encoding="utf-8")
    except Exception:
        pass

ROOT = Path(__file__).resolve().parent
SOURCE = ROOT / "Core" / "SmartTunnel.lua"

TARGETS = {
    "Linux": ROOT / "Desktop" / "Libs" / "SmartTunnel.lua",
    "Windows": ROOT / "Desktop" / "Libs" / "SmartTunnel.lua",
    "Android": ROOT / "Mobile" / "Android" / "app" / "src" / "main" / "assets" / "SmartTunnel.lua",
}

def log(msg: str) -> None:
    try:
        print(f"[prepare_st] {msg}", flush=True)
    except UnicodeEncodeError:
        print(f"[prepare_st] {msg.encode('ascii', 'replace').decode('ascii')}",
              flush=True)

def fail(msg: str, code: int = 1) -> None:
    print(f"[prepare_st] ОШИБКА: {msg}", file=sys.stderr, flush=True)
    sys.exit(code)

def copy_one(target: Path) -> None:
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(SOURCE, target)
    size = target.stat().st_size
    log(f"{target.relative_to(ROOT)}  ({size} байт)")

def main() -> int:
    parser = argparse.ArgumentParser(description="Prepare SmartTunnel.lua for platforms")
    parser.add_argument(
        "--platform",
        required=True,
        choices=["Linux", "Windows", "Android", "all"],
        help="Куда копировать (или all для всех сразу)",
    )
    args = parser.parse_args()

    if not SOURCE.exists():
        fail(f"Не найден исходник: {SOURCE}")

    log(f"Источник: {SOURCE.relative_to(ROOT)} "
        f"({SOURCE.stat().st_size} байт)")

    # Desktop/Libs/ общий для Linux и Windows — копируем один раз.
    if args.platform == "all":
        unique_targets = []
        seen = set()
        for name in ("Linux", "Windows", "Android"):
            t = TARGETS[name]
            key = str(t)
            if key not in seen:
                seen.add(key)
                unique_targets.append(t)
        for t in unique_targets:
            copy_one(t)
        log(f"Готово: {len(unique_targets)} файл(ов)")
    else:
        copy_one(TARGETS[args.platform])
        log(f"Готово: 1 файл")

    return 0

if __name__ == "__main__":
    sys.exit(main())
