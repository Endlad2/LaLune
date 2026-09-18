#!/usr/bin/env python3
"""
build_desktop.py — сборка нативного Desktop-приложения LaLune.

Структура модуля:
  Desktop/Libs/go.mod        (module lalune-libs)
  Desktop/Libs/cmd/main.go   (package main для c-shared)
  Desktop/Libs/*.go          (package libs — вся логика)

Порядок:
  1. go build -buildmode=c-shared из Desktop/Libs/ → Desktop/Libs/build/liblalune.so / lalune.dll
  2. flutter build linux|windows --release из Frontend/Core/
  3. Копируем .so/.dll рядом с Flutter-бинарником (в bundle)

Требования:
  - Go 1.22+
  - Flutter 3.22+ (с desktop support)
  - Windows: Visual Studio 2022 с workload "Desktop development with C++"
             (CMake-генератор "Visual Studio 17 2022")
"""

import argparse
import os
import platform
import shutil
import subprocess
import sys
from pathlib import Path

def log(msg: str) -> None:
    print(f"[build] {msg}", flush=True)

def err(msg: str) -> None:
    print(f"[build] ошибка: {msg}", file=sys.stderr, flush=True)

def which_or_die(name: str, hint: str = "") -> str:
    """Возвращает полный путь к исполняемому файлу или падает."""
    path = shutil.which(name)
    if path:
        return path
    msg = f"{name} не найден в PATH"
    if hint:
        msg += f"\n  {hint}"
    raise FileNotFoundError(msg)

def detect_vs_generator() -> str | None:
    """
    Возвращает имя CMake-генератора для установленной Visual Studio,
    либо None, если vswhere не нашёл ни одной инсталляции.

    Приоритет: VS 2022 → VS 2019. Если найдена только 2019 — вернём её,
    но пользователь должен понимать, что для сборки Flutter Windows
    нужен VS 2022 (Flutter 3.24+ не поддерживает 2019).
    """
    if platform.system() != "Windows":
        return None

    vswhere_candidates = [
        Path(os.environ.get("ProgramFiles(x86)", r"C:\Program Files (x86)"))
        / "Microsoft Visual Studio" / "Installer" / "vswhere.exe",
        Path(os.environ.get("ProgramFiles", r"C:\Program Files"))
        / "Microsoft Visual Studio" / "Installer" / "vswhere.exe",
    ]
    vswhere = next((p for p in vswhere_candidates if p.exists()), None)
    if vswhere is None:
        return None

    try:
        out = subprocess.check_output(
            [
                str(vswhere),
                "-latest",
                "-products", "*",
                "-requires", "Microsoft.VisualStudio.Component.VC.Tools.x86.x64",
                "-property", "installationVersion",
            ],
            text=True,
            encoding="utf-8",
            errors="replace",
        ).strip()
    except subprocess.CalledProcessError:
        return None

    if not out:
        return None

    # installationVersion вида "17.9.34714.143" или "16.11.34.0"
    major = out.split(".", 1)[0]
    if major == "17":
        return "Visual Studio 17 2022"
    if major == "16":
        return "Visual Studio 16 2019"
    return None

class DesktopBuilder:
    def __init__(self, platform_name: str):
        if platform_name not in ("Linux", "Windows"):
            raise ValueError(f"Неподдерживаемая платформа: {platform_name}")
        self.platform = platform_name
        self.root = Path.cwd()
        self.desktop_dir = self.root / "Desktop"
        self.libs_dir = self.desktop_dir / "Libs"
        self.build_dir = self.libs_dir / "build"
        self.flutter_dir = self.root / "Frontend" / "Core"

        if platform_name == "Linux":
            self.lib_name = "liblalune.so"
            self.flutter_target = "linux"
            self.bundle_lib_dir = (
                self.flutter_dir / "build" / "linux" / "x64" / "release" / "bundle" / "lib"
            )
        else:
            self.lib_name = "lalune.dll"
            self.flutter_target = "windows"
            self.bundle_lib_dir = (
                self.flutter_dir / "build" / "windows" / "x64" / "runner" / "Release"
            )

    def preflight(self) -> None:
        """Проверяет, что все нужные пути и инструменты на месте.

        Выполняется ДО первого subprocess.run, чтобы WinError 2 / FileNotFoundError
        не возникал в неочевидном месте.
        """
        if not self.libs_dir.exists():
            raise FileNotFoundError(
                f"Не найдена папка {self.libs_dir}\n"
                f"  Ожидается структура:\n"
                f"    Desktop/Libs/go.mod\n"
                f"    Desktop/Libs/cmd/main.go\n"
                f"    Desktop/Libs/*.go"
            )

        if not (self.libs_dir / "go.mod").exists():
            raise FileNotFoundError(
                f"Не найден {self.libs_dir / 'go.mod'}\n"
                f"  Убедитесь, что Go-модуль собран в Desktop/Libs/"
            )

        if not (self.libs_dir / "cmd" / "main.go").exists():
            raise FileNotFoundError(
                f"Не найден {self.libs_dir / 'cmd' / 'main.go'}\n"
                f"  Это точка входа для c-shared сборки."
            )

        if not self.flutter_dir.exists():
            raise FileNotFoundError(
                f"Не найдена папка Flutter-проекта: {self.flutter_dir}"
            )

        if not (self.flutter_dir / "pubspec.yaml").exists():
            raise FileNotFoundError(
                f"Не найден {self.flutter_dir / 'pubspec.yaml'}"
            )

        # Проверяем, что инструменты доступны.
        self.go_path = which_or_die(
            "go",
            "Установите Go 1.22+ (https://go.dev/dl/) и добавьте в PATH"
        )
        self.flutter_path = which_or_die(
            "flutter",
            "Установите Flutter 3.22+ (https://docs.flutter.dev/get-started/install) "
            "и добавьте в PATH"
        )

        # Windows: проверяем наличие VS 2022 и запоминаем генератор CMake.
        self.cmake_generator: str | None = None
        if self.platform == "Windows":
            gen = detect_vs_generator()
            if gen is None:
                raise RuntimeError(
                    "Не найдена Visual Studio с C++ toolchain.\n"
                    "  Установите Visual Studio 2022 с workload "
                    "'Desktop development with C++'.\n"
                    "  Скачать: https://visualstudio.microsoft.com/downloads/"
                )
            if gen == "Visual Studio 16 2019":
                log("WARN: найдена только VS 2019. Flutter 3.24+ требует VS 2022 — "
                    "сборка может упасть. Установите VS 2022.")
            self.cmake_generator = gen
            log(f"CMake generator: {self.cmake_generator}")

        log(f"go:      {self.go_path}")
        log(f"flutter: {self.flutter_path}")

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
            self.go_path,
            "build",
            "-buildmode=c-shared",
            "-o", str(out_lib),
            "./cmd",
        ]
        log(f"go build (c-shared) → {out_lib}")
        log(f"  cwd: {self.libs_dir}")
        log(f"  CGO_ENABLED={env['CGO_ENABLED']} GOOS={env['GOOS']} GOARCH={env['GOARCH']}")

        try:
            subprocess.run(
                cmd,
                cwd=str(self.libs_dir),
                env=env,
                check=True,
                text=True,
                encoding="utf-8",
                errors="replace",
            )
        except FileNotFoundError as e:
            raise FileNotFoundError(
                f"Не удалось запустить go: {e}\n"
                f"  Путь: {self.go_path}\n"
                f"  cwd:  {self.libs_dir}"
            )
        except subprocess.CalledProcessError as e:
            raise RuntimeError(
                f"go build завершился с кодом {e.returncode}"
            )

        if not out_lib.exists():
            raise FileNotFoundError(f"Go не создал {out_lib}")

        # Удаляем сгенерированный .h — он не нужен.
        h_file = out_lib.with_suffix(".h")
        if h_file.exists():
            h_file.unlink()

    def build_flutter(self) -> None:
        cmd = [self.flutter_path, "build", self.flutter_target, "--release"]
        log(f"flutter build {self.flutter_target} --release")
        log(f"  cwd: {self.flutter_dir}")

        env = os.environ.copy()
        # Ключевой момент: принудительно сообщаем CMake, какой генератор использовать.
        # Без этого Flutter-тулза подставляет VS 2019 по умолчанию на некоторых
        # раннерах, и CMake падает с "could not find any instance of Visual Studio".
        if self.platform == "Windows" and self.cmake_generator:
            env["CMAKE_GENERATOR"] = self.cmake_generator
            log(f"  CMAKE_GENERATOR={env['CMAKE_GENERATOR']}")

        try:
            subprocess.run(
                cmd,
                cwd=str(self.flutter_dir),
                env=env,
                check=True,
                text=True,
                encoding="utf-8",
                errors="replace",
            )
        except FileNotFoundError as e:
            raise FileNotFoundError(
                f"Не удалось запустить flutter: {e}\n"
                f"  Путь: {self.flutter_path}\n"
                f"  cwd:  {self.flutter_dir}"
            )
        except subprocess.CalledProcessError as e:
            raise RuntimeError(
                f"flutter build завершился с кодом {e.returncode}"
            )

    def copy_lib_to_bundle(self) -> None:
        src = self.build_dir / self.lib_name
        if not src.exists():
            raise FileNotFoundError(f"Не найден {src} — сначала соберите Go")

        self.bundle_lib_dir.mkdir(parents=True, exist_ok=True)
        dst = self.bundle_lib_dir / self.lib_name
        shutil.copy2(src, dst)
        log(f"{self.lib_name} → {dst}")

    def build(self) -> None:
        self.preflight()
        self.build_go()
        self.build_flutter()
        self.copy_lib_to_bundle()
        log(f"Готово. Bundle: {self.bundle_lib_dir.parent}")

def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--platform", required=True, choices=["Linux", "Windows"])
    args = parser.parse_args()

    try:
        DesktopBuilder(args.platform).build()
        return 0
    except FileNotFoundError as e:
        err(str(e))
        return 1
    except RuntimeError as e:
        err(str(e))
        return 1
    except subprocess.CalledProcessError as e:
        err(f"команда завершилась с кодом {e.returncode}")
        return e.returncode or 1
    except Exception as e:
        err(f"{type(e).__name__}: {e}")
        return 1

if __name__ == "__main__":
    sys.exit(main())
