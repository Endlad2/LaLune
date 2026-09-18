#!/usr/bin/env python3
"""
build_desktop.py — сборка нативного Desktop-приложения LaLune.

Порядок:
  1. go build -buildmode=c-shared → Desktop/<platform>/build/liblalune.so / lalune.dll
  2. flutter build linux|windows --release
  3. Копируем .so/.dll рядом с Flutter-бинарником (в bundle)
  4. Копируем SmartTunnel.lua в bundle (если нужен внешний, а не embed)

Требования:
  - Go 1.22+
  - Flutter 3.22+ (с desktop support)
  - Frontend/Core/pubspec.yaml
"""

import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path

class DesktopBuilder:
    def __init__(self, platform: str):
        if platform not in ("Linux", "Windows"):
            raise ValueError(f"Неподдерживаемая платформа: {platform}")
        self.platform = platform
        self.root = Path.cwd()
        self.desktop_dir = self.root / "Desktop"
        self.platform_dir = self.desktop_dir / platform
        self.libs_dir = self.desktop_dir / "Libs"
        self.cmd_dir = self.desktop_dir / "cmd"
        self.build_dir = self.platform_dir / "build"
        self.flutter_dir = self.root / "Frontend" / "Core"

        if platform == "Linux":
            self.lib_name = "liblalune.so"
            self.flutter_target = "linux"
            self.bundle_lib_dir = self.flutter_dir / "build" / "linux" / "x64" / "release" / "bundle" / "lib"
        else:
            self.lib_name = "lalune.dll"
            self.flutter_target = "windows"
            self.bundle_lib_dir = self.flutter_dir / "build" / "windows" / "x64" / "runner" / "Release"

    def build_go(self) -> None:
        self.build_dir.mkdir(parents=True, exist_ok=True)
        out_lib = self.build_dir / self.lib_name

        env = os.environ.copy()
        env["CGO_ENABLED"] = "1"
        if self.platform == "Windows":
            env["GOOS"] = "windows"
            env["GOARCH"] = "amd64"
        else:
            env["GOOS"] = "linux"
            env["GOARCH"] = "amd64"

        cmd = [
            "go", "build",
            "-buildmode=c-shared",
            "-o", str(out_lib),
            "./cmd",
        ]
        print(f"[build] go build (c-shared) → {out_lib}")
        subprocess.run(cmd, cwd=str(self.desktop_dir), env=env, check=True)

        if not out_lib.exists():
            raise FileNotFoundError(f"Go не создал {out_lib}")

        # Заодно убираем сгенерированный .h — он нам не нужен.
        h_file = out_lib.with_suffix(".h")
        if h_file.exists():
            h_file.unlink()

    def build_flutter(self) -> None:
        cmd = ["flutter", "build", self.flutter_target, "--release"]
        print(f"[build] flutter {' '.join(cmd[1:])}")
        subprocess.run(cmd, cwd=str(self.flutter_dir), check=True)

    def copy_lib_to_bundle(self) -> None:
        src = self.build_dir / self.lib_name
        if not src.exists():
            raise FileNotFoundError(f"Не найден {src} — сначала соберите Go")

        self.bundle_lib_dir.mkdir(parents=True, exist_ok=True)
        dst = self.bundle_lib_dir / self.lib_name
        shutil.copy2(src, dst)
        print(f"[build] {self.lib_name} → {dst}")

    def build(self) -> None:
        self.build_go()
        self.build_flutter()
        self.copy_lib_to_bundle()
        print(f"\nГотово. Bundle: {self.bundle_lib_dir.parent}")

def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--platform", required=True, choices=["Linux", "Windows"])
    args = parser.parse_args()

    try:
        DesktopBuilder(args.platform).build()
        return 0
    except subprocess.CalledProcessError as e:
        print(f"[build] ошибка: {e}", file=sys.stderr)
        return e.returncode or 1
    except Exception as e:
        print(f"[build] ошибка: {e}", file=sys.stderr)
        return 1

if __name__ == "__main__":
    sys.exit(main())
