#!/usr/bin/env python3
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
#
# build.py — единый сборщик LaLune.
#
# Интерактивный режим:
#     python build.py
#     Спросит: под какую платформу собрать (Windows / Linux).
#     Соберёт Backend + Frontend (+ Installer для Windows),
#     упакует в Output/ и сделает clean.
#
# CI-режим:
#     python build.py --ci --target windows
#     python build.py --ci --target linux
#
# Что собирает:
#   * Backend/Desktop          → cargo build --release
#   * Frontend                 → flutter build <platform>
#   * Installer/launcher       → cargo build --release  (только Windows)
#
# Что пакует в Output/:
#   * LaLune-Windows.zip   ← Frontend/build/windows/x64/runner/Release/
#   * Backend-Windows.zip  ← Backend/Desktop/target/release/lalune-backend.exe
#   * Installer-Windows.zip← Installer/launcher/target/release/LaLune-Installer.exe
#   * LaLune-Linux.zip     ← Frontend/build/linux/x64/release/bundle/
#   * Backend-Linux.zip    ← Backend/Desktop/target/release/lalune-backend
#
# После сборки делает clean:
#   * Frontend:            flutter clean
#   * Backend/Desktop:     cargo clean
#   * Installer/launcher:  cargo clean  (только если собирали)

import argparse
import os
import platform
import shutil
import subprocess
import sys
import time
import zipfile
from pathlib import Path
from typing import List, Optional

# ────────────────────────────────────────────────────────────────
#  UTF-8 для stdout/stderr (важно на Windows)
# ────────────────────────────────────────────────────────────────

for _stream in (sys.stdout, sys.stderr):
    try:
        if _stream.encoding and _stream.encoding.lower() not in ("utf-8", "utf8"):
            _stream.reconfigure(encoding="utf-8")
    except Exception:
        pass

# ────────────────────────────────────────────────────────────────
#  Пути
# ────────────────────────────────────────────────────────────────

ROOT            = Path(__file__).resolve().parent
FRONTEND        = ROOT / "Frontend"
BACKEND_DESKTOP = ROOT / "Backend" / "Desktop"
INSTALLER       = ROOT / "Installer" / "launcher"
OUTPUT          = ROOT / "Output"

IS_WINDOWS_HOST = platform.system() == "Windows"

# ────────────────────────────────────────────────────────────────
#  Логирование
# ────────────────────────────────────────────────────────────────

# Цвета (включаются, если терминал их поддерживает)
_USE_COLOR = sys.stdout.isatty() and not IS_WINDOWS_HOST or (
    IS_WINDOWS_HOST and os.environ.get("WT_SESSION") is not None
)

def _c(code: str, text: str) -> str:
    if not _USE_COLOR:
        return text
    return f"\033[{code}m{text}\033[0m"

def status(tag: str, msg: str) -> None:
    """Печатает [TAG] msg с цветной подсветкой."""
    tag_up = tag.upper()
    if tag_up == "RUNNING":
        print(_c("36", f"[RUNNING] {msg}"), flush=True)
    elif tag_up == "OK":
        print(_c("32", f"[OK] {msg}"), flush=True)
    elif tag_up == "FAIL":
        print(_c("31", f"[FAIL] {msg}"), flush=True)
    elif tag_up == "WARN":
        print(_c("33", f"[WARN] {msg}"), flush=True)
    elif tag_up == "INFO":
        print(_c("90", f"[INFO] {msg}"), flush=True)
    else:
        print(f"[{tag_up}] {msg}", flush=True)

def die(msg: str, code: int = 1) -> None:
    status("FAIL", msg)
    sys.exit(code)

# ────────────────────────────────────────────────────────────────
#  Запуск команд
# ────────────────────────────────────────────────────────────────

def run(cmd: List[str], cwd: Path, label: Optional[str] = None) -> None:
    """
    Запускает команду, печатает [RUNNING] / [OK] / [FAIL].
    Падает с exit code, если команда вернула не 0.
    """
    label = label or " ".join(cmd)
    status("RUNNING", label)

    # shell=True нужен только для flutter на Windows (.bat).
    use_shell = IS_WINDOWS_HOST and cmd[0] in ("flutter", "flutter.bat")

    t0 = time.time()
    try:
        proc = subprocess.run(
            cmd,
            cwd=str(cwd),
            shell=use_shell,
            check=False,
        )
    except FileNotFoundError as e:
        die(f"{cmd[0]}: not found ({e})")

    dt = time.time() - t0
    if proc.returncode != 0:
        status("FAIL", f"{label}  (exit={proc.returncode}, {dt:.1f}s)")
        sys.exit(proc.returncode or 1)

    status("OK", f"{label}  ({dt:.1f}s)")

# ────────────────────────────────────────────────────────────────
#  Утилиты
# ────────────────────────────────────────────────────────────────

def which(name: str) -> Optional[str]:
    return shutil.which(name)

def require_tool(name: str, hint: str = "") -> None:
    if which(name) is None:
        die(f"{name} not found in PATH. {hint}".strip())

def clean_dir(path: Path) -> None:
    if path.exists():
        shutil.rmtree(path)
    path.mkdir(parents=True, exist_ok=True)

def find_first(paths: List[Path], names: List[str]) -> Optional[Path]:
    for base in paths:
        for name in names:
            candidate = base / name
            if candidate.exists():
                return candidate
    return None

def zip_dir(src_dir: Path, dest_zip: Path, arc_prefix: str = "") -> None:
    """
    Пакует src_dir в dest_zip. Внутри zip — файлы относительно src_dir
    (или с указанным префиксом).
    """
    dest_zip.parent.mkdir(parents=True, exist_ok=True)
    if dest_zip.exists():
        dest_zip.unlink()

    with zipfile.ZipFile(dest_zip, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as zf:
        for root, _dirs, files in os.walk(src_dir):
            root_path = Path(root)
            for f in files:
                full = root_path / f
                rel = full.relative_to(src_dir)
                arcname = str(Path(arc_prefix) / rel) if arc_prefix else str(rel)
                zf.write(full, arcname)

def zip_file(src_file: Path, dest_zip: Path, arcname: Optional[str] = None) -> None:
    """Кладёт ровно один файл в zip."""
    dest_zip.parent.mkdir(parents=True, exist_ok=True)
    if dest_zip.exists():
        dest_zip.unlink()
    with zipfile.ZipFile(dest_zip, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as zf:
        zf.write(src_file, arcname or src_file.name)

# ────────────────────────────────────────────────────────────────
#  Этапы сборки
# ────────────────────────────────────────────────────────────────

def build_backend_desktop() -> Path:
    """Собирает Rust-бэкенд для Desktop. Возвращает путь к бинарнику."""
    require_tool("cargo", "Install Rust: https://rustup.rs")

    if not BACKEND_DESKTOP.exists():
        die(f"Backend/Desktop not found: {BACKEND_DESKTOP}")

    run(["cargo", "build", "--release"], cwd=BACKEND_DESKTOP,
        label="cargo build --release (Backend/Desktop)")

    bin_name = "lalune-backend.exe" if IS_WINDOWS_HOST else "lalune-backend"
    bin_path = BACKEND_DESKTOP / "target" / "release" / bin_name
    if not bin_path.exists():
        die(f"backend binary not found: {bin_path}")
    return bin_path

def build_installer() -> Optional[Path]:
    """Собирает Rust-инсталлятор (только Windows). Возвращает путь к exe."""
    if not IS_WINDOWS_HOST:
        status("INFO", "Installer: skipping (not Windows host)")
        return None

    if not INSTALLER.exists():
        status("WARN", f"Installer not found: {INSTALLER}")
        return None

    require_tool("cargo", "Install Rust: https://rustup.rs")
    run(["cargo", "build", "--release"], cwd=INSTALLER,
        label="cargo build --release (Installer/launcher)")

    exe = INSTALLER / "target" / "release" / "LaLune-Installer.exe"
    if not exe.exists():
        # Fallback: имя как в Cargo.toml [[bin]]
        exe = INSTALLER / "target" / "release" / "lalune-installer.exe"
    if not exe.exists():
        die(f"installer exe not found: {exe}")
    return exe

def build_frontend(target_os: str) -> Path:
    """
    Собирает Flutter-фронтенд. Возвращает каталог с результатом.
    Гарантирует, что бинарник называется LaLune (или LaLune.exe).
    """
    require_tool("flutter", "Install Flutter: https://docs.flutter.dev/get-started/install")

    if not FRONTEND.exists():
        die(f"Frontend not found: {FRONTEND}")

    # ── Подготовка Assets/ → Frontend/assets/ ─────────────────
    # Корневой Assets/ копируется в Frontend/assets/ перед сборкой.
    src_assets = ROOT / "Assets"
    dst_assets = FRONTEND / "assets"
    if src_assets.exists():
        status("INFO", f"Assets: {src_assets} → {dst_assets}")
        if dst_assets.exists():
            shutil.rmtree(dst_assets)
        shutil.copytree(src_assets, dst_assets)
    else:
        status("WARN", f"Assets/ not found at {src_assets} — Flutter может упасть")

    # ── flutter pub get ──────────────────────────────────────
    run(["flutter", "pub", "get"], cwd=FRONTEND, label="flutter pub get")

    # ── flutter build ────────────────────────────────────────
    if target_os == "windows":
        run(["flutter", "build", "windows", "--release"], cwd=FRONTEND,
            label="flutter build windows --release")
        result_dir = FRONTEND / "build" / "windows" / "x64" / "runner" / "Release"
    elif target_os == "linux":
        run(["flutter", "build", "linux", "--release"], cwd=FRONTEND,
            label="flutter build linux --release")
        result_dir = FRONTEND / "build" / "linux" / "x64" / "release" / "bundle"
    else:
        die(f"unsupported target: {target_os}")

    if not result_dir.exists():
        die(f"flutter build result not found: {result_dir}")

    # ── Гарантируем имя бинарника LaLune[.exe] ───────────────
    rename_to_laLune(result_dir, target_os)
    return result_dir

def rename_to_laLune(result_dir: Path, target_os: str) -> None:
    """
    Flutter по умолчанию называет бинарник так же, как pubspec name
    (у нас — lalune). Переименовываем в LaLune[.exe], как ожидает
    install.ps1/install.sh.
    """
    if target_os == "windows":
        candidates = [
            result_dir / "lalune.exe",
            result_dir / "LaLune.exe",
        ]
        desired = result_dir / "LaLune.exe"
    else:
        candidates = [
            result_dir / "lalune",
            result_dir / "LaLune",
        ]
        desired = result_dir / "LaLune"

    if desired.exists():
        status("INFO", f"binary name already OK: {desired.name}")
        return

    for c in candidates:
        if c.exists():
            status("INFO", f"rename: {c.name} → {desired.name}")
            c.rename(desired)
            return

    # Не нашли ни один — не падаем, но предупреждаем.
    status("WARN", f"could not find binary to rename in {result_dir}")

# ────────────────────────────────────────────────────────────────
#  Упаковка
# ────────────────────────────────────────────────────────────────

def package_windows(
    frontend_dir: Path,
    backend_bin: Path,
    installer_exe: Optional[Path],
) -> None:
    clean_dir(OUTPUT)

    # LaLune-Windows.zip ← весь каталог Frontend/build/.../Release/
    lalune_zip = OUTPUT / "LaLune-Windows.zip"
    status("INFO", f"packaging {lalune_zip.name}…")
    zip_dir(frontend_dir, lalune_zip)
    status("OK", f"{lalune_zip.name}  ({lalune_zip.stat().st_size // 1024} KB)")

    # Backend-Windows.zip ← один бинарник
    backend_zip = OUTPUT / "Backend-Windows.zip"
    status("INFO", f"packaging {backend_zip.name}…")
    zip_file(backend_bin, backend_zip, arcname="LaLuneManager.exe")
    status("OK", f"{backend_zip.name}  ({backend_zip.stat().st_size // 1024} KB)")

    # Installer-Windows.zip ← один exe (если собран)
    if installer_exe is not None:
        installer_zip = OUTPUT / "Installer-Windows.zip"
        status("INFO", f"packaging {installer_zip.name}…")
        zip_file(installer_exe, installer_zip, arcname="LaLune-Installer.exe")
        status("OK", f"{installer_zip.name}  ({installer_zip.stat().st_size // 1024} KB)")

def package_linux(frontend_dir: Path, backend_bin: Path) -> None:
    clean_dir(OUTPUT)

    # LaLune-Linux.zip ← весь каталог bundle/
    lalune_zip = OUTPUT / "LaLune-Linux.zip"
    status("INFO", f"packaging {lalune_zip.name}…")
    zip_dir(frontend_dir, lalune_zip)
    status("OK", f"{lalune_zip.name}  ({lalune_zip.stat().st_size // 1024} KB)")

    # Backend-Linux.zip ← один бинарник
    backend_zip = OUTPUT / "Backend-Linux.zip"
    status("INFO", f"packaging {backend_zip.name}…")
    zip_file(backend_bin, backend_zip, arcname="LaLuneManager")
    status("OK", f"{backend_zip.name}  ({backend_zip.stat().st_size // 1024} KB)")

# ────────────────────────────────────────────────────────────────
#  Clean
# ────────────────────────────────────────────────────────────────

def clean_all(built_installer: bool) -> None:
    status("INFO", "cleaning build artifacts…")

    if FRONTEND.exists() and which("flutter"):
        run(["flutter", "clean"], cwd=FRONTEND, label="flutter clean (Frontend)")

    if BACKEND_DESKTOP.exists() and which("cargo"):
        run(["cargo", "clean"], cwd=BACKEND_DESKTOP,
            label="cargo clean (Backend/Desktop)")

    if built_installer and INSTALLER.exists() and which("cargo"):
        run(["cargo", "clean"], cwd=INSTALLER,
            label="cargo clean (Installer/launcher)")

    # Frontend/assets/ — копия корневого Assets/. Удаляем после сборки.
    dst_assets = FRONTEND / "assets"
    if dst_assets.exists():
        shutil.rmtree(dst_assets, ignore_errors=True)
        status("OK", "removed Frontend/assets/ (temporary copy)")

# ────────────────────────────────────────────────────────────────
#  Интерактивный выбор
# ────────────────────────────────────────────────────────────────

def ask_target() -> str:
    print()
    print("=" * 44)
    print("   LaLune build")
    print("=" * 44)
    print()
    print("  Под какую платформу собрать?")
    print()
    print("    1) Windows")
    print("    2) Linux")
    print()

    while True:
        try:
            choice = input("  Выбор [1/2]: ").strip()
        except EOFError:
            choice = ""

        if choice == "1" or choice.lower() in ("w", "windows", "win"):
            return "windows"
        if choice == "2" or choice.lower() in ("l", "linux"):
            return "linux"
        print("  Введите 1 или 2.")

# ────────────────────────────────────────────────────────────────
#  Main
# ────────────────────────────────────────────────────────────────

def main() -> int:
    parser = argparse.ArgumentParser(
        description="LaLune build script",
    )
    parser.add_argument(
        "--ci", action="store_true",
        help="CI-режим: не задавать вопросы, использовать --target",
    )
    parser.add_argument(
        "--target", choices=["windows", "linux"],
        help="Целевая платформа (обязательно в --ci)",
    )
    parser.add_argument(
        "--no-clean", action="store_true",
        help="Не чистить build-артефакты после сборки",
    )
    args = parser.parse_args()

    # ── Выбор платформы ──────────────────────────────────────
    if args.ci:
        if not args.target:
            die("--ci требует --target windows|linux")
        target_os = args.target
    else:
        if args.target:
            target_os = args.target
        else:
            target_os = ask_target()

    # ── Проверки ─────────────────────────────────────────────
    if target_os == "windows" and not IS_WINDOWS_HOST:
        die("Windows target requires a Windows host")

    status("INFO", f"target: {target_os}")
    print()

    # ── Сборка ───────────────────────────────────────────────
    try:
        # 1. Backend
        backend_bin = build_backend_desktop()
        status("INFO", f"backend binary: {backend_bin}")

        # 2. Installer (только Windows)
        installer_exe: Optional[Path] = None
        if target_os == "windows":
            installer_exe = build_installer()
            if installer_exe:
                status("INFO", f"installer exe: {installer_exe}")

        # 3. Frontend
        frontend_dir = build_frontend(target_os)
        status("INFO", f"frontend dir: {frontend_dir}")

        # ── Упаковка ─────────────────────────────────────────
        print()
        status("INFO", "packaging…")
        if target_os == "windows":
            package_windows(frontend_dir, backend_bin, installer_exe)
        else:
            package_linux(frontend_dir, backend_bin)

        print()
        status("OK", f"build complete: {OUTPUT}")
        for f in sorted(OUTPUT.iterdir()):
            if f.is_file():
                status("INFO", f"  {f.name}  ({f.stat().st_size // 1024} KB)")

        # ── Clean ────────────────────────────────────────────
        if not args.no_clean:
            print()
            clean_all(built_installer=installer_exe is not None)

        print()
        status("OK", "done.")
        return 0

    except KeyboardInterrupt:
        print()
        status("FAIL", "interrupted by user")
        return 130

if __name__ == "__main__":
    sys.exit(main())
