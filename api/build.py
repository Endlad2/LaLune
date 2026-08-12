#!/usr/bin/env python3
import os
import sys
import subprocess
import platform
import urllib.request
import zipfile
import shutil
import tempfile
import shutil

def print_step(step):
    print(f"\n{'='*60}")
    print(f"  {step}")
    print(f"{'='*60}")

def download_wintun():
    """Скачивает wintun.dll в папку cmd/server/"""
    print_step("1. Downloading wintun.dll")
    
    # Определяем архитектуру
    arch = platform.machine().lower()
    if arch in ['amd64', 'x86_64']:
        dll_arch = 'amd64'
    elif arch in ['arm64', 'aarch64']:
        dll_arch = 'arm64'
    elif arch == 'x86':
        dll_arch = 'x86'
    else:
        dll_arch = 'amd64'
    
    print(f"  Architecture: {dll_arch}")
    
    # Путь для сохранения dll рядом с main.go
    dll_dir = os.path.join('cmd', 'server')
    dll_path = os.path.join(dll_dir, 'wintun.dll')
    
    # Создаем папку если нет
    os.makedirs(dll_dir, exist_ok=True)
    
    # Проверяем, есть ли уже dll
    if os.path.exists(dll_path):
        print(f"  wintun.dll already exists at {dll_path}, skipping download")
        return True
    
    # Скачиваем архив
    url = 'https://www.wintun.net/builds/wintun-0.14.1.zip'
    print(f"  Downloading from: {url}")
    
    try:
        with urllib.request.urlopen(url) as response:
            with tempfile.NamedTemporaryFile(delete=False, suffix='.zip') as tmp_file:
                tmp_file.write(response.read())
                zip_path = tmp_file.name
        
        print("  Extracting...")
        with zipfile.ZipFile(zip_path, 'r') as zip_ref:
            # Извлекаем нужную dll
            dll_in_zip = f'wintun/bin/{dll_arch}/wintun.dll'
            with zip_ref.open(dll_in_zip) as src, open(dll_path, 'wb') as dst:
                dst.write(src.read())
        
        os.unlink(zip_path)
        print(f"  wintun.dll extracted successfully to {dll_path} ({os.path.getsize(dll_path)} bytes)")
        return True
        
    except Exception as e:
        print(f"  ERROR: Failed to download/extract wintun.dll: {e}")
        return False

def check_go():
    """Проверяет наличие Go"""
    print_step("2. Checking Go installation")
    
    try:
        result = subprocess.run(['go', 'version'], capture_output=True, text=True)
        if result.returncode == 0:
            version = result.stdout.strip().split()[2]
            print(f"  Go version: {version}")
            return True
    except FileNotFoundError:
        pass
    
    print("  ERROR: Go is not installed or not in PATH")
    print("  Please install Go from: https://golang.org/dl/")
    return False

def run_command(cmd, cwd=None, check=True):
    """Запускает команду и выводит вывод"""
    print(f"  Running: {' '.join(cmd) if isinstance(cmd, list) else cmd}")
    
    try:
        if isinstance(cmd, str):
            process = subprocess.Popen(cmd, shell=True, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1)
        else:
            process = subprocess.Popen(cmd, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1)
        
        output = []
        for line in iter(process.stdout.readline, ''):
            print(f"    {line.rstrip()}")
            output.append(line)
        
        process.stdout.close()
        return_code = process.wait()
        
        if check and return_code != 0:
            print(f"  ERROR: Command failed with code {return_code}")
            return False
        return True
        
    except Exception as e:
        print(f"  ERROR: {e}")
        return False

def build_server():
    """Собирает сервер"""
    print_step("3. Building La Lune Server")
    
    # go mod tidy
    print("  Tidying dependencies...")
    if not run_command(['go', 'mod', 'tidy']):
        return False
    
    # Определяем имя бинарника
    if platform.system() == 'Windows':
        binary_name = 'la-lune-server.exe'
    else:
        binary_name = 'la-lune-server'
    
    # Собираем с оптимизациями
    print(f"  Building {binary_name}...")
    cmd = ['go', 'build', '-ldflags=-s -w', '-o', binary_name, 'cmd/server/main.go']
    if not run_command(cmd):
        return False
    
    if os.path.exists(binary_name):
        size = os.path.getsize(binary_name)
        print(f"  ✅ Build successful! Binary size: {size / 1024 / 1024:.2f} MB")
        return True
    else:
        print(f"  ERROR: Binary not created")
        return False

def create_launcher():
    """Создает лаунчер для Windows"""
    if platform.system() != 'Windows':
        return
    
    print_step("4. Creating launcher script")
    
    launcher_content = '''@echo off
echo Starting La Lune API Server...
echo.
echo Requesting administrator privileges...
powershell -Command "Start-Process -Verb RunAs -FilePath '%cd%\\\\la-lune-server.exe'"
echo.
echo Server started. Press any key to continue...
pause > nul
'''
    
    with open('launch.bat', 'w', encoding='utf-8') as f:
        f.write(launcher_content)
    print("  Created launch.bat (run as administrator)")

def main():
    """Основная функция"""
    print("\n" + "="*60)
    print("  La Lune Build Script")
    print("  Building API Server with embedded wintun.dll")
    print("="*60)
    
    # Проверяем Python версию
    if sys.version_info < (3, 6):
        print("ERROR: Python 3.6+ required")
        sys.exit(1)
    
    # Скачиваем wintun.dll в папку cmd/server/
    if not download_wintun():
        print("\n❌ Build failed: wintun.dll download failed")
        sys.exit(1)
    
    # Проверяем Go
    if not check_go():
        print("\n❌ Build failed: Go not found")
        sys.exit(1)
    
    # Собираем
    if not build_server():
        print("\n❌ Build failed: compilation error")
        sys.exit(1)
    
    # Создаем лаунчер
    create_launcher()
    
    # Финальный вывод
    print("\n" + "="*60)
    print("  ✅ BUILD SUCCESSFUL")
    print("="*60)
    
    if platform.system() == 'Windows':
        binary = 'la-lune-server.exe'
        launcher = 'launch.bat'
        print(f"\n  Run server: {launcher} (as administrator)")
        print(f"  Or run: {binary} (as administrator)")
    else:
        binary = 'la-lune-server'
        print(f"\n  Run server: ./{binary} (with sudo)")
        print(f"  Command: sudo ./{binary}")
    
    print("\n  Server will start on: http://localhost:7419")
    print("\n  Files created:")
    print(f"    - {binary} (main binary)")
    print(f"    - cmd/server/wintun.dll (embedded in binary)")
    if platform.system() == 'Windows':
        print(f"    - launch.bat (launcher script)")
    print("\n  You can now distribute the binary with embedded wintun.dll!")
    print("  No WireGuard installation required!")

if __name__ == '__main__':
    try:
        main()
    except KeyboardInterrupt:
        print("\n\nBuild cancelled by user")
        sys.exit(1)
    except Exception as e:
        print(f"\n\nERROR: {e}")
        sys.exit(1)
