# Desktop/core_manager.py
# Загрузка и управление ядром CSQTT

import os
import sys
import platform
import subprocess
import stat
import tempfile
import json
import hashlib
from pathlib import Path
from typing import Optional, Dict, List
import urllib.request
import zipfile
import shutil

class CoreManager:
    """Управление ядром CSQTT"""
    
    # URL для скачивания ядер
    GITHUB_RELEASE = "https://github.com/Endlad2/csqtt-core/releases/download/latest"
    
    # Маппинг платформ
    PLATFORM_MAP = {
        'windows': 'client-windows-x86_64.exe',
        'linux': 'client-linux-x86_64',
        'darwin': 'client-macos-x86_64'
    }
    
    def __init__(self):
        self.platform = platform.system().lower()
        self.temp_dir = Path(tempfile.gettempdir()) / "lalune_core"
        self.temp_dir.mkdir(parents=True, exist_ok=True)
        
        # Определяем имя файла ядра для текущей платформы
        self.core_filename = self.PLATFORM_MAP.get(self.platform)
        if not self.core_filename:
            raise RuntimeError(f"Unsupported platform: {self.platform}")
        
        self.core_path = self.temp_dir / self.core_filename
        self.version_file = self.temp_dir / "version.txt"
    
    def get_core_url(self) -> str:
        """Получение URL для скачивания ядра"""
        # Пробуем получить последнюю версию
        latest_path = f"{self.GITHUB_RELEASE}/{self.core_filename}"
        
        # Альтернативный путь с датой (для отказоустойчивости)
        alt_path = f"https://github.com/Endlad2/csqtt-core/releases/latest/2026.08.24.12.28/{self.core_filename}"
        
        return latest_path  # Сначала пробуем latest
    
    def get_core_path(self) -> Path:
        """Получение пути к ядру"""
        return self.core_path
    
    def is_core_available(self) -> bool:
        """Проверка наличия ядра"""
        return self.core_path.exists()
    
    def download_core(self) -> bool:
        """Скачивание ядра"""
        try:
            url = self.get_core_url()
            print(f"[CORE] Скачивание ядра: {url}")
            
            # Скачиваем
            with urllib.request.urlopen(url) as response:
                total_size = int(response.headers.get('content-length', 0))
                downloaded = 0
                block_size = 8192
                
                with open(self.core_path, 'wb') as f:
                    while True:
                        buffer = response.read(block_size)
                        if not buffer:
                            break
                        f.write(buffer)
                        downloaded += len(buffer)
                        
                        # Прогресс
                        if total_size > 0:
                            percent = (downloaded / total_size) * 100
                            print(f"[CORE] Загрузка: {percent:.1f}%")
            
            # Делаем исполняемым на Linux/macOS
            if self.platform != 'windows':
                self.core_path.chmod(self.core_path.stat().st_mode | stat.S_IEXEC)
            
            # Сохраняем версию
            with open(self.version_file, 'w') as f:
                f.write(url)
            
            print(f"[CORE] Ядро сохранено: {self.core_path}")
            return True
            
        except Exception as e:
            print(f"[CORE] Ошибка загрузки: {e}")
            # Удаляем частично загруженный файл
            if self.core_path.exists():
                self.core_path.unlink()
            return False
    
    def ensure_core(self) -> Path:
        """Проверка наличия ядра и загрузка при необходимости"""
        if not self.is_core_available():
            print("[CORE] Ядро не найдено, скачиваем...")
            if not self.download_core():
                raise RuntimeError("Не удалось загрузить ядро CSQTT")
        
        return self.core_path
    
    def build_command(self, config: Dict, settings: Dict) -> List[str]:
        """
        Построение команды запуска ядра
        Аналогично параметрам из C# проекта:
        -peer <peer>
        -vk <hashes>
        -password <password>
        -n <workers>
        -listen 127.0.0.1:<port>
        -fingerprint <fingerprint>
        -client-ids <client_ids>
        -obfs <obfs>
        -vk-auth-mode <vk_auth_mode>
        -device-id <device_id>
        -captcha-mode <captcha_mode>
        --tun-uds <path> (только для Linux)
        """
        # Базовые параметры
        cmd = [str(self.core_path)]
        
        # Peer
        if config.get('peer'):
            cmd.extend(['-peer', config['peer']])
        
        # VK хеши
        if config.get('hashes'):
            cmd.extend(['-vk', config['hashes']])
        
        # Пароль
        if config.get('password'):
            cmd.extend(['-password', config['password']])
        
        # Количество воркеров
        workers = settings.get('workers_per_hash', 9)
        hashes_count = len(config.get('hashes', '').split(',')) if config.get('hashes') else 1
        total_workers = workers * max(1, hashes_count)
        cmd.extend(['-n', str(total_workers)])
        
        # Слушаем на локальном порту
        listen_port = settings.get('listen_port', '9000')
        cmd.extend(['-listen', f'127.0.0.1:{listen_port}'])
        
        # Fingerprint
        if settings.get('fingerprint'):
            cmd.extend(['-fingerprint', settings['fingerprint']])
        
        # Client IDs
        if settings.get('client_ids'):
            cmd.extend(['-client-ids', settings['client_ids']])
        
        # Обфускация
        if settings.get('obfs'):
            cmd.extend(['-obfs', settings['obfs']])
        
        # VK Auth Mode
        if settings.get('vk_auth_mode'):
            cmd.extend(['-vk-auth-mode', settings['vk_auth_mode']])
        
        # Device ID
        if settings.get('device_id'):
            cmd.extend(['-device-id', settings['device_id']])
        
        # Captcha Mode
        if settings.get('captcha_mode'):
            cmd.extend(['-captcha-mode', settings['captcha_mode']])
        
        # TURN (если указаны)
        if settings.get('turn_host'):
            cmd.extend(['-turn', settings['turn_host']])
        if settings.get('turn_port'):
            cmd.extend(['-port', settings['turn_port']])
        
        # Для Linux добавляем --tun-uds
        if self.platform == 'linux':
            uds_path = self.temp_dir / "csqtt.sock"
            cmd.extend(['--tun-uds', str(uds_path)])
        
        # Включаем события
        cmd.extend(['-allow-hash-redistribution'])
        
        return cmd
    
    def start_core(self, config: Dict, settings: Dict) -> subprocess.Popen:
        """
        Запуск ядра с переданными параметрами
        Возвращает Popen объект для управления процессом
        """
        # Убеждаемся, что ядро есть
        self.ensure_core()
        
        # Строим команду
        cmd = self.build_command(config, settings)
        
        print(f"[CORE] Запуск: {' '.join(cmd)}")
        
        # Настройка окружения
        env = os.environ.copy()
        env['CSQTT_EVENTS'] = '1'
        env['TOKIO_WORKER_THREADS'] = str(min(os.cpu_count() or 2, 8))
        env['RAYON_NUM_THREADS'] = '2'
        
        # Запуск процесса
        process = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            stdin=subprocess.PIPE,
            text=True,
            env=env,
            bufsize=1,
            universal_newlines=True
        )
        
        return process
    
    def cleanup(self):
        """Очистка временных файлов"""
        try:
            if self.core_path.exists():
                self.core_path.unlink()
            if self.version_file.exists():
                self.version_file.unlink()
        except:
            pass
