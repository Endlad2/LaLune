#!/usr/bin/env python3
"""
build_deploy_manager.py — собирает Core/DeployManager (Rust) и кладёт бинарник
в нужное место LaLune для каждой платформы.

Назначение (см. PROJECT.md):
  * При сборке LaLune собирается и DeployManager.
  * DeployManager кладётся в LaLune на каждой платформе.
  * Для Android он собирается как БИНАРНИК (не библиотека) и кладётся
    в папку библиотек (jniLibs), откуда упаковывается в APK и распаковывается
    в Files dir; запускается через Process.exec.

Использование:
    python build_deploy_manager.py --dest Desktop/Windows
    python build_deploy_manager.py --dest Desktop/Linux
    python build_deploy_manager.py --android --abi arm64-v8a
    python build_deploy_manager.py --dest out --target x86_64-unknown-linux-musl
"""

import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
CRATE_DIR = ROOT / "Core" / "DeployManager"

# Android ABI -> Rust target triple
ANDROID_TARGETS = {
    "arm64-v8a": "aarch64-linux-android",
    "armeabi-v7a": "armv7-linux-androideabi",
    "x86_64": "x86_64-linux-android",
    "x86": "i686-linux-android",
}


def log(msg: str) -> None:
    try:
        print(f"[deploy-manager] {msg}", flush=True)
    except UnicodeEncodeError:
        print(f"[deploy-manager] {msg.encode('ascii','replace').decode('ascii')}", flush=True)


def die(msg: str) -> None:
    print(f"[deploy-manager][ERROR] {msg}", file=sys.stderr, flush=True)
    sys.exit(1)


def bin_name() -> str:
    return "deploy-manager.exe" if os.name == "nt" else "deploy-manager"


def cargo_build(target: str | None, release: bool, android: bool) -> Path:
    if not CRATE_DIR.exists():
        die(f"не найдена папка крейта: {CRATE_DIR}")

    cmd = ["cargo", "build"]
    if release:
        cmd.append("--release")
    if target:
        cmd += ["--target", target]

    env = os.environ.copy()
    if android:
        ndk = env.get("ANDROID_NDK_HOME") or env.get("NDK_HOME")
        if not ndk:
            die("для сборки под Android задайте ANDROID_NDK_HOME/NDK_HOME")
        api = env.get("ANDROID_API_LEVEL", "24")
        host = "windows-x86_64" if os.name == "nt" else "linux-x86_64"
        toolchain = Path(ndk) / "toolchains" / "llvm" / "prebuilt" / host / "bin"
        env["PATH"] = str(toolchain) + os.pathsep + env.get("PATH", "")
        env["CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER"] = str(toolchain / "aarch64-linux-android{}-clang".format(api))
        env["CC_aarch64_linux_android"] = str(toolchain / f"aarch64-linux-android{api}-clang")
        env["AR_aarch64_linux_android"] = str(toolchain / "llvm-ar")

    log("cargo " + " ".join(cmd[1:]))
    proc = subprocess.run(cmd, cwd=str(CRATE_DIR), env=env)
    if proc.returncode != 0:
        die(f"cargo build завершился с ошибкой (exit={proc.returncode})")

    profile = "release" if release else "debug"
    if target:
        out = CRATE_DIR / "target" / target / profile / bin_name()
    else:
        out = CRATE_DIR / "target" / profile / bin_name()
    if not out.exists():
        die(f"бинарник не найден после сборки: {out}")
    return out


def main() -> int:
    parser = argparse.ArgumentParser(description="Build & place DeployManager")
    parser.add_argument("--dest", default=None,
                        help="каталог, куда положить бинарник (desktop-платформы)")
    parser.add_argument("--target", default=None,
                        help="Rust target triple (по умолчанию host)")
    parser.add_argument("--release", action="store_true", default=True,
                        help="собирать release (по умолчанию)")
    parser.add_argument("--debug", dest="release", action="store_false")
    parser.add_argument("--android", action="store_true",
                        help="собрать под Android и положить в jniLibs")
    parser.add_argument("--abi", default="arm64-v8a",
                        choices=list(ANDROID_TARGETS.keys()),
                        help="Android ABI (при --android)")
    args = parser.parse_args()

    target = args.target
    if args.android:
        target = ANDROID_TARGETS[args.abi]

    binary = cargo_build(target, args.release, args.android)
    log(f"собран: {binary}")

    if args.android:
        # Android: бинарник кладётся в jniLibs как lib*.so (упаковывается в APK,
        # затем распаковывается в Files dir и запускается через Process.exec).
        dst_dir = (ROOT / "Mobile" / "Android" / "app" / "src" / "main" / "jniLibs"
                   / args.abi)
        dst_dir.mkdir(parents=True, exist_ok=True)
        dst = dst_dir / "libdeploy_manager.so"
        shutil.copy2(binary, dst)
        log(f"Android: {dst}")
    elif args.dest:
        dst_dir = (ROOT / args.dest).resolve()
        dst_dir.mkdir(parents=True, exist_ok=True)
        dst = dst_dir / bin_name()
        shutil.copy2(binary, dst)
        log(f"Desktop: {dst}")
    else:
        log("--dest/--android не заданы: бинарник собран, но не скопирован")

    return 0


if __name__ == "__main__":
    sys.exit(main())