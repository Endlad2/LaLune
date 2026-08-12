#!/usr/bin/env python3
# build.py
import os
import sys
import subprocess
import platform
import urllib.request
import zipfile

WINTUN_URL = "https://www.wintun.net/builds/wintun-0.14.1.zip"
WINTUN_DLL = "cmd/server/wintun.dll"

def download_wintun():
    print("=" * 60)
    print("  1. Downloading wintun.dll")
    print("=" * 60)
    
    if os.path.exists(WINTUN_DLL):
        print(f"  {WINTUN_DLL} already exists, skipping download")
        return
    
    arch = platform.machine().lower()
    print(f"  Architecture: {arch}")
    
    zip_path = "wintun.zip"
    urllib.request.urlretrieve(WINTUN_URL, zip_path)
    
    with zipfile.ZipFile(zip_path, 'r') as zf:
        for name in zf.namelist():
            if name.endswith('wintun.dll') and arch in name:
                with zf.open(name) as src:
                    with open(WINTUN_DLL, 'wb') as dst:
                        dst.write(src.read())
                print(f"  Extracted: {name} -> {WINTUN_DLL}")
                break
    
    os.remove(zip_path)
    if not os.path.exists(WINTUN_DLL):
        print("  WARNING: Could not extract wintun.dll — download manually")
        sys.exit(1)

def check_go():
    print("=" * 60)
    print("  2. Checking Go installation")
    print("=" * 60)
    
    try:
        result = subprocess.run(["go", "version"], capture_output=True, text=True)
        print(f"  {result.stdout.strip()}")
    except FileNotFoundError:
        print("  ERROR: Go is not installed")
        sys.exit(1)

def build():
    print("=" * 60)
    print("  3. Building La Lune Server")
    print("=" * 60)
    
    goos = os.environ.get("GOOS", platform.system().lower())
    goarch = os.environ.get("GOARCH", platform.machine().lower())
    
    arch_map = {"x86_64": "amd64", "amd64": "amd64", "aarch64": "arm64", "arm64": "arm64"}
    goarch = arch_map.get(goarch, goarch)
    
    output_name = "la-lune-server"
    if goos == "windows":
        output_name += ".exe"
    
    print(f"  Target: {goos}/{goarch}")
    print(f"  Output: {output_name}")
    
    print("  Tidying dependencies...")
    subprocess.run(["go", "mod", "tidy"], check=True)
    
    print(f"  Building {output_name}...")
    env = os.environ.copy()
    env["GOOS"] = goos
    env["GOARCH"] = goarch
    
    cmd = [
        "go", "build",
        "-ldflags=-s -w",
        "-o", output_name,
        "./cmd/server/",
    ]
    
    result = subprocess.run(cmd, env=env, capture_output=True, text=True)
    
    if result.returncode != 0:
        print(f"  {result.stderr}")
        print(f"  ERROR: Command failed with code {result.returncode}")
        sys.exit(1)
    
    size = os.path.getsize(output_name)
    print(f"  OK Build successful: {output_name} ({size / 1024 / 1024:.1f} MB)")

def main():
    print("=" * 60)
    print("  La Lune Build Script")
    print("  Cross-Platform: Windows / Linux / macOS")
    print("=" * 60)
    print()
    
    goos = os.environ.get("GOOS", platform.system().lower())
    
    if goos == "windows":
        download_wintun()
    
    check_go()
    build()
    
    print()
    print("  OK Done!")

if __name__ == "__main__":
    main()