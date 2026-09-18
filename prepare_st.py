#!/usr/bin/env python3
"""
prepare_st.py — копирует Core/SmartTunnel.lua в места, где его читают рантаймы.

Использование:
    python prepare_st.py --platform=Linux
    python prepare_st.py --platform=Windows
    python prepare_st.py --platform=Android
    python prepare_st.py --platform=all

Что делает:
    - Linux   → Desktop/Linux/SmartTunnel.lua   (для go:embed)
    - Windows → Desktop/Windows/SmartTunnel.lua (для go:embed)
    - Android → Mobile/Android/app/src/main/assets/SmartTunnel.lua
    - all     → все три сразу

После копирования печатает список файлов и их размер.
"""

import argparse
import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
SOURCE = ROOT / "Core" / "SmartTunnel.lua"

TARGETS = {
    "Linux": ROOT / "Desktop" / "Linux" / "SmartTunnel.lua",
    "Windows": ROOT / "Desktop" / "Windows" / "SmartTunnel.lua",
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

    platforms = list(TARGETS.keys()) if args.platform == "all" else [args.platform]

    for name in platforms:
        copy_one(TARGETS[name])

    log(f"Готово: {len(platforms)} файл(ов)")
    return 0

if __name__ == "__main__":
    sys.exit(main())
