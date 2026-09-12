#!/usr/bin/env python3
"""
build_desktop.py — сборка Wails-приложения LaLune для Desktop.

Требования:
    - Python 3.8+
    - Wails v2 установлен в PATH
    - Frontend/output/ уже собран через build_frontend.py

Что делает:
  1. Проверяет, что Frontend/output/ существует
  2. Копирует Frontend/output/* в Desktop/<platform>/frontend/
  3. Копирует Desktop/Libs/*.go в Desktop/<platform>/Libs/
  4. Копирует ресурсы Windows (icon.ico, manifest)
  5. Запускает wails build
  6. Убирает временные файлы
"""

import argparse
import shutil
import subprocess
import sys
import time
from pathlib import Path
from typing import List

# ============================================================
#  Progress
# ============================================================

class ProgressBar:
    def __init__(self, total_steps: int, desc: str = "Progress"):
        self.total_steps = total_steps
        self.current_step = 0
        self.desc = desc
        self.start_time = time.time()

    def update(self, step_desc: str = "") -> None:
        self.current_step += 1
        percent = (self.current_step / self.total_steps) * 100
        bar_width = 50
        filled = int(bar_width * self.current_step / self.total_steps)
        bar = "#" * filled + "-" * (bar_width - filled)

        elapsed = time.time() - self.start_time
        sys.stdout.write(
            f"\r{self.desc}: [{bar}] {percent:.1f}% "
            f"({self.current_step}/{self.total_steps}) {step_desc}  [{elapsed:.1f}s]"
        )
        sys.stdout.flush()

        if self.current_step == self.total_steps:
            sys.stdout.write("\n")
            sys.stdout.flush()

# ============================================================
#  Builder
# ============================================================

class WailsBuilder:
    def __init__(self, platform: str, wails_flags: str = ""):
        if platform not in ("Linux", "Windows"):
            raise ValueError(f"Неподдерживаемая платформа: {platform}")

        self.platform = platform
        self.wails_flags = wails_flags

        self.root_dir = Path.cwd()
        self.frontend_output = self.root_dir / "Frontend" / "output"
        self.desktop_dir = self.root_dir / "Desktop"
        self.platform_dir = self.desktop_dir / platform
        self.frontend_dir = self.platform_dir / "frontend"
        self.libs_platform_dir = self.platform_dir / "Libs"
        self.desktop_libs_dir = self.desktop_dir / "Libs"

        self.icon_ico_source = self.platform_dir / "icon.ico"
        self.manifest_source = self.platform_dir / "wails.exe.manifest"
        self.build_windows_dir = self.platform_dir / "build" / "windows"

        self._created_frontend = False
        self._created_libs = False
        self._created_build_windows = False

    # ---------- setup ----------

    def check_prerequisites(self) -> None:
        if not self.frontend_output.exists():
            raise FileNotFoundError(
                f"Не найден {self.frontend_output}\n"
                f"Сначала соберите фронтенд:\n"
                f"  python build_frontend.py --platform {self.platform}"
            )

        index = self.frontend_output / "index.html"
        if not index.exists():
            raise FileNotFoundError(
                f"В {self.frontend_output} нет index.html — сборка фронта пустая"
            )

    def setup_frontend(self) -> None:
        """Копирует Frontend/output/* в Desktop/<platform>/frontend/."""
        if self.frontend_dir.exists():
            shutil.rmtree(self.frontend_dir)
        self.frontend_dir.mkdir(parents=True, exist_ok=True)
        self._created_frontend = True

        for item in self.frontend_output.iterdir():
            dst = self.frontend_dir / item.name
            if item.is_dir():
                shutil.copytree(item, dst)
            else:
                shutil.copy2(item, dst)

        count = len(list(self.frontend_dir.rglob("*")))
        print(f"  Фронтенд: {count} файлов → {self.frontend_dir}")

    def copy_libs(self) -> None:
        """Копирует Desktop/Libs/* → Desktop/<platform>/Libs/."""
        if not self.desktop_libs_dir.exists():
            print(f"\n  [WARN] {self.desktop_libs_dir} не найден, пропускаю")
            return

        if self.libs_platform_dir.exists():
            shutil.rmtree(self.libs_platform_dir)
        self.libs_platform_dir.mkdir(parents=True, exist_ok=True)
        self._created_libs = True

        count = 0
        for item in self.desktop_libs_dir.iterdir():
            dst = self.libs_platform_dir / item.name
            if item.is_file():
                shutil.copy2(item, dst)
                count += 1
            elif item.is_dir():
                shutil.copytree(item, dst, dirs_exist_ok=True)
                count += 1

        print(f"  Libs: {count} файлов → {self.libs_platform_dir}")

    def copy_windows_resources(self) -> None:
        """Копирует icon.ico и wails.exe.manifest в build/windows/."""
        if self.platform != "Windows":
            return

        if self.build_windows_dir.exists():
            shutil.rmtree(self.build_windows_dir)
        self.build_windows_dir.mkdir(parents=True, exist_ok=True)
        self._created_build_windows = True

        if self.icon_ico_source.exists():
            shutil.copy2(
                self.icon_ico_source,
                self.build_windows_dir / "icon.ico",
            )
            print(f"  icon.ico → {self.build_windows_dir}")
        else:
            print(f"  [WARN] {self.icon_ico_source} не найден")

        if self.manifest_source.exists():
            shutil.copy2(
                self.manifest_source,
                self.build_windows_dir / "wails.exe.manifest",
            )
            print(f"  wails.exe.manifest → {self.build_windows_dir}")
        else:
            print(f"  [WARN] {self.manifest_source} не найден")

    # ---------- build ----------

    def build_wails(self) -> None:
        cmd = ["wails", "build"]
        if self.wails_flags:
            cmd.extend(self.wails_flags.split())

        print("\n" + "=" * 60)
        print(f"Running: {' '.join(cmd)}")
        print(f"  cwd: {self.platform_dir}")
        print("=" * 60 + "\n")

        # На Windows wails — .exe/.bat, но он есть в PATH и subprocess
        # со shell=True на Windows корректно работает только с одной строкой.
        # Используем list + shell для .bat-совместимости.
        use_shell = sys.platform == "win32"

        process = subprocess.Popen(
            cmd,
            cwd=str(self.platform_dir),
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            encoding="utf-8",
            errors="replace",
            bufsize=1,
            shell=use_shell,
        )

        assert process.stdout is not None
        for line in process.stdout:
            sys.stdout.write(line)
            sys.stdout.flush()

        process.wait()

        if process.returncode != 0:
            raise subprocess.CalledProcessError(process.returncode, cmd)

    # ---------- cleanup ----------

    def cleanup(self) -> None:
        if self._created_frontend and self.frontend_dir.exists():
            shutil.rmtree(self.frontend_dir, ignore_errors=True)

        if self._created_libs and self.libs_platform_dir.exists():
            shutil.rmtree(self.libs_platform_dir, ignore_errors=True)

        if self._created_build_windows and self.build_windows_dir.exists():
            shutil.rmtree(self.build_windows_dir, ignore_errors=True)

# ============================================================
#  main
# ============================================================

def main() -> int:
    parser = argparse.ArgumentParser(description="Wails Builder Script")
    parser.add_argument(
        "--platform",
        required=True,
        choices=["Linux", "Windows"],
        help="Target platform",
    )
    parser.add_argument(
        "--wails-flags",
        default="",
        help="Additional flags for wails build (в виде строки)",
    )
    args = parser.parse_args()

    builder = WailsBuilder(args.platform, args.wails_flags)

    total_steps = 6
    progress = ProgressBar(total_steps, f"Building for {args.platform}")

    try:
        progress.update("Проверка Frontend/output/...")
        builder.check_prerequisites()

        progress.update("Копирование фронтенда...")
        builder.setup_frontend()

        progress.update("Копирование Libs...")
        builder.copy_libs()

        progress.update("Копирование Windows-ресурсов...")
        builder.copy_windows_resources()

        progress.update("Запуск wails build...")
        builder.build_wails()

        progress.update("Очистка временных файлов...")
        builder.cleanup()

        print(f"\nСборка успешно завершена для {args.platform}")
        return 0

    except subprocess.CalledProcessError as e:
        progress.update(f"Ошибка wails build (exit={e.returncode})")
        builder.cleanup()
        return e.returncode or 1

    except Exception as e:
        progress.update(f"Ошибка: {e}")
        builder.cleanup()
        return 1

if __name__ == "__main__":
    sys.exit(main())
