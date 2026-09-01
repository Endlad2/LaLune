#!/usr/bin/env python3

import os
import shutil
import argparse
import subprocess
import sys
import re
import time
from pathlib import Path
from typing import List

class ProgressBar:
    def __init__(self, total_steps: int, desc: str = "Progress"):
        self.total_steps = total_steps
        self.current_step = 0
        self.desc = desc
        self.start_time = time.time()

    def update(self, step_desc: str = ""):
        self.current_step += 1
        percent = (self.current_step / self.total_steps) * 100
        bar_width = 50
        filled = int(bar_width * self.current_step / self.total_steps)
        bar = "█" * filled + "░" * (bar_width - filled)

        elapsed = time.time() - self.start_time
        sys.stdout.write(f"\r{self.desc}: [{bar}] {percent:.1f}% ({self.current_step}/{self.total_steps}) {step_desc}")
        sys.stdout.flush()

        if self.current_step == self.total_steps:
            sys.stdout.write("\n")
            sys.stdout.flush()

class WailsBuilder:
    def __init__(self, platform: str, wails_flags: str = ""):
        self.platform = platform
        self.wails_flags = wails_flags
        self.temp_dirs: List[Path] = []
        self.temp_files: List[Path] = []

        self.root_dir = Path.cwd()
        self.frontend_dir = self.root_dir / "Frontend"
        self.desktop_dir = self.root_dir / "Desktop"
        self.platform_dir = self.desktop_dir / platform
        self.frontend_platform_dir = self.platform_dir / "frontend"
        self.libs_platform_dir = self.platform_dir / "Libs"

        self.app_html = self.frontend_dir / "app.html"
        self.api_js = self.frontend_dir / "desktop-api.js"
        self.target_html = self.frontend_platform_dir / "index.html"

        self.icon_ico_source = self.platform_dir / "icon.ico"
        self.manifest_source = self.platform_dir / "wails.exe.manifest"
        self.build_windows_dir = self.platform_dir / "build" / "windows"

    def setup_directories(self):
        self.frontend_platform_dir.mkdir(parents=True, exist_ok=True)
        self.libs_platform_dir.mkdir(parents=True, exist_ok=True)
        self.temp_dirs.extend([self.frontend_platform_dir, self.libs_platform_dir])

    def process_html(self):
        if not self.app_html.exists():
            raise FileNotFoundError(f"File not found: {self.app_html}")

        with open(self.app_html, 'r', encoding='utf-8') as f:
            content = f.read()

        pattern = r'<script src="\{QTWEBCHANNEL_SCRIPT\}"></script>\s*<script src="\{API_SCRIPT\}"></script>'
        content = re.sub(pattern, '<script src="desktop-api.js"></script>', content)

        with open(self.target_html, 'w', encoding='utf-8') as f:
            f.write(content)

    def copy_api_js(self):
        if not self.api_js.exists():
            raise FileNotFoundError(f"File not found: {self.api_js}")

        for platform in ['Linux', 'Windows']:
            target = self.desktop_dir / platform / "frontend" / "desktop-api.js"
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(self.api_js, target)

    def copy_libs(self):
        desktop_libs = self.desktop_dir / "Libs"
        if not desktop_libs.exists():
            print(f"\nWarning: {desktop_libs} not found, skipping Libs copy")
            return

        files = list(desktop_libs.iterdir())
        if not files:
            print(f"\nWarning: {desktop_libs} is empty, skipping Libs copy")
            return

        for platform in ['Linux', 'Windows']:
            target_libs = self.desktop_dir / platform / "Libs"
            target_libs.mkdir(parents=True, exist_ok=True)

            for item in files:
                if item.is_file():
                    shutil.copy2(item, target_libs / item.name)
                    print(f"  Copied file: {item.name} -> {target_libs / item.name}")
                elif item.is_dir():
                    shutil.copytree(item, target_libs / item.name, dirs_exist_ok=True)
                    print(f"  Copied directory: {item.name} -> {target_libs / item.name}")

    def copy_windows_resources(self):
        if self.platform != "Windows":
            return

        self.build_windows_dir.mkdir(parents=True, exist_ok=True)

        if self.icon_ico_source.exists():
            target_ico = self.build_windows_dir / "icon.ico"
            shutil.copy2(self.icon_ico_source, target_ico)
            print(f"  Copied icon: {self.icon_ico_source} -> {target_ico}")
        else:
            print(f"\nWarning: {self.icon_ico_source} not found, skipping icon copy")

        if self.manifest_source.exists():
            target_manifest = self.build_windows_dir / "wails.exe.manifest"
            shutil.copy2(self.manifest_source, target_manifest)
            print(f"  Copied manifest: {self.manifest_source} -> {target_manifest}")
        else:
            print(f"\nWarning: {self.manifest_source} not found, skipping manifest copy")

        self.temp_dirs.append(self.build_windows_dir)

    def build_wails(self):
        os.chdir(self.platform_dir)
        cmd = ["wails", "build"]
        if self.wails_flags:
            cmd.extend(self.wails_flags.split())

        print("\n" + "=" * 60)
        print(f"Running: {' '.join(cmd)}")
        print("=" * 60 + "\n")

        process = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1)

        for line in process.stdout:
            print(line, end='')

        process.wait()

        os.chdir(self.root_dir)

        if process.returncode != 0:
            raise subprocess.CalledProcessError(process.returncode, cmd)

    def cleanup(self):
        for dir_path in self.temp_dirs:
            if dir_path.exists():
                shutil.rmtree(dir_path, ignore_errors=True)

        for file_path in self.temp_files:
            if file_path.exists():
                file_path.unlink()

def main():
    parser = argparse.ArgumentParser(description="Wails Builder Script")
    parser.add_argument("--platform", required=True, choices=["Linux", "Windows"], help="Target platform")
    parser.add_argument("--wails-flags", default="", help="Additional flags for wails build")
    args = parser.parse_args()

    builder = WailsBuilder(args.platform, args.wails_flags)

    total_steps = 6
    progress = ProgressBar(total_steps, f"Building for {args.platform}")

    try:
        progress.update("Setting up directories...")
        builder.setup_directories()

        progress.update("Processing HTML...")
        builder.process_html()

        progress.update("Copying API JS...")
        builder.copy_api_js()

        progress.update("Copying Libs...")
        builder.copy_libs()

        progress.update("Copying platform resources...")
        builder.copy_windows_resources()

        progress.update("Running wails build...")
        builder.build_wails()

        progress.update("Cleaning up temp files...")
        builder.cleanup()

        print(f"\nBuild completed successfully for {args.platform}")

    except subprocess.CalledProcessError as e:
        progress.update(f"Build failed (exit code: {e.returncode})")
        builder.cleanup()
        sys.exit(e.returncode)
    except Exception as e:
        progress.update(f"Error: {str(e)}")
        builder.cleanup()
        sys.exit(1)

if __name__ == "__main__":
    main()