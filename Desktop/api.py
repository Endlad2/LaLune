import json
import os
import sys
import platform
import subprocess
import tempfile
import hashlib
import urllib.request
import uuid
import threading
import socket
import time
import re
from pathlib import Path
from urllib.parse import urlparse, parse_qs, unquote, quote
from PyQt6.QtCore import QObject, pyqtSlot, pyqtSignal

from database import ConfigDB, get_app_data_dir

if platform.system().lower() == 'windows':
    from wintun import WintunAdapter, TunnelController

LATEST_URL = "https://raw.githubusercontent.com/Endlad2/csqtt-core/refs/heads/main/LATEST"
CORE_URL_TEMPLATE = "https://github.com/Endlad2/csqtt-core/releases/download/{version}/{filename}"
WINTUN_URL = "https://www.wintun.net/builds/wintun-0.14.1.zip"
PROXY_URL = "http://31.77.148.203:8855/?url="

USER_AGENT = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

MIN_SPEED_MBPS = 1.0

def parse_csqtt_link(link):
    result = {
        'protocol': 'CSQTT',
        'peer': '',
        'password': '',
        'hashes': '',
        'name': ''
    }
    
    try:
        text = link.strip()
        if not text.lower().startswith("csqtt://"):
            raise ValueError("Неверная схема")
        
        parsed = urlparse(text)
        
        if parsed.hostname and parsed.hostname.lower() == "connect":
            params = parse_qs(parsed.query)
            
            if 'v' in params and unquote(params['v'][0]) == "2":
                host = unquote(params.get('host', [''])[0])
                port = unquote(params.get('peer', [''])[0])
                password = unquote(params.get('password', [''])[0])
                
                if not host or not port or not password:
                    raise ValueError("Не хватает host/peer/password")
                
                result['peer'] = f"{host}:{port}"
                result['password'] = password
                
                if 'hashes' in params:
                    raw_hashes = params['hashes'][0]
                    parts = raw_hashes.split('+')
                    clean_hashes = []
                    for part in parts:
                        h = strip_vk_url(unquote(part))
                        if h:
                            clean_hashes.append(h)
                    result['hashes'] = ','.join(clean_hashes)
                
                result['name'] = result['peer']
            else:
                raise ValueError("Только v=2 поддерживается")
        else:
            host = parsed.hostname or ''
            port = parsed.port or 46000
            password = unquote(parsed.username or '')
            
            if not host or not password:
                raise ValueError("Неверный legacy формат")
            
            result['peer'] = f"{host}:{port}"
            result['password'] = password
            result['name'] = result['peer']
    
    except Exception as e:
        print(f"[API] Ошибка парсинга: {e}")
        result['peer'] = link
        result['name'] = 'Config'
    
    return result

def strip_vk_url(value):
    v = value.strip()
    prefixes = ["https://vk.com/call/join/", "https://m.vk.com/call/join/", "https://vk.ru/call/join/"]
    for p in prefixes:
        if v.startswith(p):
            v = v[len(p):]
            break
    cut = v.find('?')
    if cut >= 0:
        v = v[:cut]
    cut = v.find('#')
    if cut >= 0:
        v = v[:cut]
    return v.rstrip('/')

def fetch_url(url, timeout=8):
    urls_to_try = [url, PROXY_URL + quote(url, safe='')]
    
    for attempt_url in urls_to_try:
        try:
            print(f"[NET] Пробую: {attempt_url[:100]}...")
            req = urllib.request.Request(attempt_url, headers={'User-Agent': USER_AGENT})
            with urllib.request.urlopen(req, timeout=timeout) as response:
                return response.read()
        except Exception as e:
            print(f"[NET] Ошибка ({attempt_url[:50]}...): {e}")
            continue
    
    return None

def download_file(url, destination, timeout=30):
    urls_to_try = [url, PROXY_URL + quote(url, safe='')]
    
    for attempt_index, attempt_url in enumerate(urls_to_try):
        try:
            print(f"[DOWNLOAD] Пробую: {attempt_url[:100]}...")
            
            req = urllib.request.Request(attempt_url, headers={'User-Agent': USER_AGENT})
            
            with urllib.request.urlopen(req, timeout=timeout) as response:
                total_size = int(response.headers.get('content-length', 0))
                downloaded = 0
                start_time = time.time()
                last_check_time = start_time
                last_check_downloaded = 0
                slow_detected = False
                
                with open(destination, 'wb') as f:
                    while True:
                        chunk = response.read(8192)
                        if not chunk:
                            break
                        
                        f.write(chunk)
                        downloaded += len(chunk)
                        
                        now = time.time()
                        elapsed_since_check = now - last_check_time
                        
                        if elapsed_since_check >= 2.0:
                            bytes_since_check = downloaded - last_check_downloaded
                            speed_mbps = (bytes_since_check / elapsed_since_check) / (1024 * 1024)
                            
                            print(f"[DOWNLOAD] Скорость: {speed_mbps:.2f} МБ/с ({downloaded}/{total_size})")
                            
                            if attempt_index == 0 and speed_mbps < MIN_SPEED_MBPS and total_size > 0:
                                print(f"[DOWNLOAD] Скорость ниже {MIN_SPEED_MBPS} МБ/с, переключаюсь на зеркало...")
                                slow_detected = True
                                break
                            
                            last_check_time = now
                            last_check_downloaded = downloaded
                
                if slow_detected:
                    if os.path.exists(destination):
                        os.remove(destination)
                    continue
                
                file_size = os.path.getsize(destination)
                if file_size < 1024:
                    print(f"[DOWNLOAD] Файл слишком маленький ({file_size} байт)")
                    os.remove(destination)
                    continue
                
                print(f"[DOWNLOAD] Успешно: {destination} ({file_size} байт)")
                return True
                
        except Exception as e:
            print(f"[DOWNLOAD] Ошибка ({attempt_url[:50]}...): {e}")
            if os.path.exists(destination):
                try:
                    os.remove(destination)
                except:
                    pass
            continue
    
    return False

class RouteManager:
    def __init__(self):
        self.bypass_routes = []
        self.gateway = None
        self.physical_index = None
    
    def configure(self, ip, dns, protected_hosts):
        self._find_physical_gateway()
        self._add_bypass_routes(protected_hosts)
        
        self._exec(['netsh', 'interface', 'ipv4', 'set', 'address', 'name="CSQTT"', 'source=static', f'address={ip}', 'mask=255.255.255.255'])
        self._exec(['netsh', 'interface', 'ipv4', 'set', 'subinterface', '"CSQTT"', 'mtu=1300', 'store=active'])
        
        dns_servers = [d for d in dns.split(',') if d.strip()]
        for i, server in enumerate(dns_servers, 1):
            self._exec(['netsh', 'interface', 'ipv4', 'add', 'dnsservers', 'name="CSQTT"', f'address={server}', f'index={i}', 'validate=no'])
        
        self._exec(['netsh', 'interface', 'ipv4', 'add', 'route', 'prefix=0.0.0.0/0', 'interface="CSQTT"', 'nexthop=0.0.0.0', 'metric=5', 'store=active'])
    
    def cleanup(self):
        try:
            self._exec_quiet(['netsh', 'interface', 'ipv4', 'delete', 'route', 'prefix=0.0.0.0/0', 'interface="CSQTT"', 'store=active'])
        except:
            pass
        
        for ip in self.bypass_routes:
            try:
                self._exec_quiet(['route', 'DELETE', ip])
            except:
                pass
        
        self.bypass_routes = []
    
    def _find_physical_gateway(self):
        try:
            result = subprocess.run(['route', 'print', '-4'], capture_output=True, text=True, creationflags=subprocess.CREATE_NO_WINDOW)
            lines = result.stdout.split('\n')
            
            found_default = False
            for line in lines:
                parts = line.split()
                if len(parts) >= 4 and parts[0] == '0.0.0.0' and parts[1] == '0.0.0.0':
                    self.gateway = parts[2]
                    self.physical_index = parts[3]
                    found_default = True
                    break
            
            if not found_default:
                raise RuntimeError("Не найден физический шлюз")
            
        except Exception as e:
            raise RuntimeError(f"Ошибка поиска шлюза: {e}")
    
    def _add_bypass_routes(self, hosts):
        resolved_ips = set()
        
        for host in hosts:
            if not host:
                continue
            
            bare = host.strip()
            
            if bare.startswith('['):
                bare = bare[1:bare.index(']')]
            elif bare.count(':') == 1:
                bare = bare[:bare.rindex(':')]
            
            try:
                socket.inet_aton(bare)
                resolved_ips.add(bare)
            except:
                try:
                    resolved = socket.getaddrinfo(bare, None, socket.AF_INET)
                    for r in resolved:
                        resolved_ips.add(r[4][0])
                except:
                    pass
        
        for ip in resolved_ips:
            cmd = ['route', 'ADD', ip, 'MASK', '255.255.255.255', self.gateway, 'IF', self.physical_index, 'METRIC', '1']
            self._exec(cmd)
            self.bypass_routes.append(ip)
    
    def _exec(self, cmd):
        result = subprocess.run(cmd, capture_output=True, text=True, creationflags=subprocess.CREATE_NO_WINDOW if sys.platform == 'win32' else 0)
        if result.returncode != 0:
            raise RuntimeError(f"{' '.join(cmd)}: {result.stderr or result.stdout}")
    
    def _exec_quiet(self, cmd):
        try:
            subprocess.run(cmd, capture_output=True, creationflags=subprocess.CREATE_NO_WINDOW if sys.platform == 'win32' else 0)
        except:
            pass

class DesktopAPI(QObject):
    log_updated = pyqtSignal(str)
    status_changed = pyqtSignal(bool)
    configs_updated = pyqtSignal(str)
    update_available = pyqtSignal(str)
    
    def __init__(self, parent=None):
        super().__init__(parent)
        self.parent_app = parent
        self.configs = []
        self.settings = {}
        self.password = ""
        self.is_connected = False
        self.core_process = None
        self.update_pending = False
        self.is_downloading = False
        
        self.system = platform.system().lower()
        
        self.app_dir = get_app_data_dir()
        self.settings_file = self.app_dir / "settings.json"
        self.latest_file = self.app_dir / "LATEST"
        
        if self.system == 'windows':
            self.core_path = self.app_dir / "client-windows-x86_64.exe"
            self.wintun_path = self.app_dir / "wintun.dll"
        elif self.system == 'linux':
            self.core_path = self.app_dir / "client-linux-x86_64"
            self.wintun_path = None
        elif self.system == 'darwin':
            self.core_path = self.app_dir / "client-macos-x86_64"
            self.wintun_path = None
        else:
            self.core_path = self.app_dir / "client"
            self.wintun_path = None
        
        self.wintun_adapter = None
        self.tunnel = None
        self.route_manager = None
        self.tunconf = None
        
        self.db = ConfigDB()
        
        self.load_settings()
        self.ensure_device_id()
        self.load_configs()
        
        threading.Thread(target=self._check_update_background, daemon=True).start()
    
    def load_configs(self):
        try:
            self.configs = self.db.get_all()
            print(f"[API] Загружено конфигов: {len(self.configs)}")
        except Exception as e:
            print(f"[ERROR] load_configs: {e}")
            self.configs = []
        
        self.configs_updated.emit(json.dumps(self.configs))
    
    def load_settings(self):
        if self.settings_file.exists():
            try:
                with open(self.settings_file, 'r', encoding='utf-8') as f:
                    self.settings = json.load(f)
            except Exception as e:
                print(f"[ERROR] load_settings: {e}")
                self.settings = {}
        else:
            self.settings = {}
        
        defaults = {
            'peer': '',
            'vkHashes': '',
            'turnHost': '',
            'turnPort': '',
            'workersPerHash': 9,
            'obfs': 'video',
            'fingerprint': 'firefox',
            'clientIds': '8202606,6287487',
            'vkAuthMode': 'vkcalls',
            'captchaMode': 'auto',
            'deviceId': '',
            'autoConnect': False
        }
        
        changed = False
        for key, value in defaults.items():
            if key not in self.settings:
                self.settings[key] = value
                changed = True
        
        if changed:
            self.save_settings_file()
    
    def ensure_device_id(self):
        if not self.settings.get('deviceId'):
            self.settings['deviceId'] = uuid.uuid4().hex
            self.save_settings_file()
            print(f"[API] Сгенерирован Device ID: {self.settings['deviceId']}")
    
    def save_settings_file(self):
        try:
            self.settings_file.parent.mkdir(parents=True, exist_ok=True)
            with open(self.settings_file, 'w', encoding='utf-8') as f:
                json.dump(self.settings, f, ensure_ascii=False, indent=2)
        except Exception as e:
            print(f"[ERROR] save_settings_file: {e}")
    
    def _check_update_background(self):
        try:
            remote_version = self.fetch_latest_version()
            if not remote_version:
                return
            
            local_version = ""
            if self.latest_file.exists():
                local_version = self.latest_file.read_text(encoding='utf-8').strip()
            
            if remote_version != local_version:
                print(f"[UPDATE] Доступна новая версия: {remote_version} (локальная: {local_version or 'нет'})")
                self.update_pending = True
                self.update_available.emit(remote_version)
                
                if not self.is_connected:
                    threading.Thread(target=self._perform_update_async, args=(remote_version,), daemon=True).start()
            
        except Exception as e:
            print(f"[UPDATE] Ошибка проверки: {e}")
    
    def fetch_latest_version(self):
        data = fetch_url(LATEST_URL, timeout=8)
        if data:
            return data.decode('utf-8').strip()
        return None
    
    def _get_core_filename(self):
        if self.system == 'windows':
            return 'client-windows-x86_64.exe'
        elif self.system == 'linux':
            return 'client-linux-x86_64'
        elif self.system == 'darwin':
            return 'client-macos-x86_64'
        return 'client'
    
    def _perform_update_async(self, version):
        if self.is_downloading:
            return
        
        self.is_downloading = True
        temp_core = None
        
        try:
            self.log_updated.emit(f"[UPDATE] Скачивание ядра версии {version}...")
            
            filename = self._get_core_filename()
            core_url = CORE_URL_TEMPLATE.format(version=version, filename=filename)
            temp_core = self.core_path.with_suffix('.tmp')
            
            if not download_file(core_url, temp_core, timeout=30):
                self.log_updated.emit("[UPDATE] Ошибка скачивания ядра")
                if temp_core.exists():
                    temp_core.unlink()
                return
            
            if self.core_path.exists():
                self.core_path.unlink()
            temp_core.rename(self.core_path)
            
            if self.system == 'linux':
                os.chmod(self.core_path, 0o755)
            
            self.latest_file.write_text(version, encoding='utf-8')
            
            self.log_updated.emit(f"[UPDATE] Ядро обновлено до версии {version}")
            self.update_pending = False
            
        except Exception as e:
            self.log_updated.emit(f"[UPDATE] Ошибка обновления: {e}")
            if temp_core and temp_core.exists():
                temp_core.unlink()
        finally:
            self.is_downloading = False
    
    def _ensure_wintun(self):
        if self.system != 'windows':
            return True
        
        if self.wintun_path and self.wintun_path.exists():
            return True
        
        self.log_updated.emit("[WINTUN] Скачивание wintun.dll...")
        
        temp_zip = self.app_dir / "wintun.zip"
        
        if not download_file(WINTUN_URL, temp_zip, timeout=30):
            self.log_updated.emit("[WINTUN] Ошибка скачивания")
            if temp_zip.exists():
                temp_zip.unlink()
            return False
        
        try:
            import zipfile
            with zipfile.ZipFile(temp_zip, 'r') as zf:
                wintun_dll = None
                for name in zf.namelist():
                    if name.endswith('amd64/wintun.dll'):
                        wintun_dll = name
                        break
                
                if not wintun_dll:
                    self.log_updated.emit("[WINTUN] wintun.dll не найден в архиве")
                    return False
                
                with zf.open(wintun_dll) as src:
                    with open(self.wintun_path, 'wb') as dst:
                        dst.write(src.read())
            
            temp_zip.unlink()
            self.log_updated.emit("[WINTUN] Готово")
            return True
            
        except Exception as e:
            self.log_updated.emit(f"[WINTUN] Ошибка распаковки: {e}")
            return False
    
    @pyqtSlot(result=bool)
    def updateCore(self):
        if self.is_connected:
            self.log_updated.emit("[UPDATE] Сначала отключитесь")
            return False
        
        if self.is_downloading:
            self.log_updated.emit("[UPDATE] Уже идёт скачивание")
            return False
        
        self.log_updated.emit("[UPDATE] Проверка версии...")
        
        threading.Thread(target=self._update_core_worker, daemon=True).start()
        return True
    
    def _update_core_worker(self):
        remote_version = self.fetch_latest_version()
        if not remote_version:
            self.log_updated.emit("[UPDATE] Не удалось проверить версию")
            return
        
        self._perform_update_async(remote_version)
        
        if self.system == 'windows':
            threading.Thread(target=self._ensure_wintun, daemon=True).start()
    
    @pyqtSlot(str)
    def log(self, message):
        print(f"[JS LOG] {message}")
        self.log_updated.emit(f"JS: {message}")
    
    @pyqtSlot(int, result=bool)
    def connect(self, config_id):
        print(f"[API] connect({config_id})")
        
        config = self.db.get_by_id(config_id)
        if not config:
            print(f"[API] Конфиг {config_id} не найден")
            return False
        
        threading.Thread(target=self._connect_worker, args=(config,), daemon=True).start()
        return True
    
    def _connect_worker(self, config):
        try:
            if self.system == 'windows':
                if not self._ensure_wintun():
                    self.log_updated.emit("[ERROR] Не удалось получить wintun.dll")
                    return
            
            if not self.core_path.exists():
                self.log_updated.emit("[API] Ядро не найдено, скачиваю...")
                remote_version = self.fetch_latest_version()
                if not remote_version:
                    self.log_updated.emit("[ERROR] Не удалось получить версию")
                    return
                
                self._perform_update_async(remote_version)
                
                if not self.core_path.exists():
                    self.log_updated.emit("[ERROR] Не удалось скачать ядро")
                    return
            
            self.log_updated.emit(f"=== Подключение к {config['name']} ===")
            
            listen_port = self.get_free_port()
            cmd = self.build_command(config, listen_port)
            self.log_updated.emit(f"Команда: {' '.join(cmd)}")
            
            env = os.environ.copy()
            env['CSQTT_EVENTS'] = '1'
            env['TOKIO_WORKER_THREADS'] = str(min(os.cpu_count() or 2, 8))
            env['RAYON_NUM_THREADS'] = '2'
            
            self.core_process = subprocess.Popen(
                cmd,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                encoding='utf-8',
                errors='replace',
                bufsize=1,
                universal_newlines=True,
                env=env,
                creationflags=subprocess.CREATE_NO_WINDOW if sys.platform == 'win32' else 0
            )
            
            self.is_connected = True
            self.status_changed.emit(True)
            
            self.tunconf = None
            
            if self.system == 'windows':
                self._setup_wintun_and_tunnel(listen_port)
            
            for line in self.core_process.stdout:
                line = line.strip()
                if line:
                    self.log_updated.emit(line)
                    
                    tunconf_match = re.search(r'TUNCONF:([^:\s]+):([^:\s]+)', line)
                    if tunconf_match and self.system == 'windows' and not self.tunconf:
                        tun_ip = tunconf_match.group(1)
                        tun_dns = tunconf_match.group(2)
                        self.tunconf = (tun_ip, tun_dns)
                        self.log_updated.emit(f"[TUN] IP: {tun_ip}, DNS: {tun_dns}")
                        
                        self.route_manager = RouteManager()
                        protected_hosts = [
                            config['peer'], 
                            self.settings.get('turnHost', ''),
                            'api.vk.me', 'api.vk.ru', 'login.vk.ru',
                            'id.vk.com', 'vk.com', 'vk.ru',
                            'calls.okcdn.ru', 'api.ok.ru', 'api.okcdn.ru'
                        ]
                        try:
                            self.route_manager.configure(tun_ip, tun_dns, protected_hosts)
                            self.log_updated.emit("[TUN] Маршруты и DNS настроены")
                        except Exception as e:
                            self.log_updated.emit(f"[TUN] Ошибка настройки маршрутов: {e}")
            
            self.core_process.wait()
            
        except Exception as e:
            self.log_updated.emit(f"[ERROR] {e}")
        finally:
            self._cleanup_tunnel()
            self.is_connected = False
            self.status_changed.emit(False)
            self.log_updated.emit("=== Процесс завершён ===")
            
            if self.update_pending:
                version = self.fetch_latest_version()
                if version:
                    threading.Thread(target=self._perform_update_async, args=(version,), daemon=True).start()
    
    def _setup_wintun_and_tunnel(self, core_port):
        try:
            self.wintun_adapter = WintunAdapter(str(self.wintun_path))
            self.wintun_adapter.create_or_open("CSQTT")
            self.wintun_adapter.start_session()
            
            self.tunnel = TunnelController(self.wintun_adapter, self.core_process)
            self.tunnel.start(core_port)
            
            self.log_updated.emit("[TUN] Wintun адаптер и пакетный мост запущены")
            
        except Exception as e:
            self.log_updated.emit(f"[TUN] Ошибка Wintun: {e}")
            self.wintun_adapter = None
            self.tunnel = None
    
    def _cleanup_tunnel(self):
        if self.tunnel:
            try:
                self.tunnel.stop()
            except:
                pass
            self.tunnel = None
        
        if self.route_manager:
            try:
                self.route_manager.cleanup()
            except:
                pass
            self.route_manager = None
        
        if self.wintun_adapter:
            try:
                self.wintun_adapter.close()
            except:
                pass
            self.wintun_adapter = None
    
    def build_command(self, config, listen_port):
        hashes_list = [h for h in config['hashes'].split(',') if h.strip()]
        hashes_count = min(len(hashes_list), 6)
        workers_per_hash = max(9, int(self.settings.get('workersPerHash', 9)))
        total_workers = workers_per_hash * max(1, hashes_count)
        
        cmd = [
            str(self.core_path),
            "-peer", config['peer'],
            "-n", str(total_workers),
            "-listen", f"127.0.0.1:{listen_port}",
            "-vk", config['hashes'],
            "-fingerprint", self.settings.get('fingerprint', 'firefox'),
            "-client-ids", self.settings.get('clientIds', '8202606,6287487'),
            "-obfs", self.settings.get('obfs', 'video'),
            "-vk-auth-mode", self.settings.get('vkAuthMode', 'vkcalls'),
            "-device-id", self.settings.get('deviceId', ''),
            "-password", config['password'],
            "-captcha-mode", self.settings.get('captchaMode', 'auto')
        ]
        
        if self.system == 'linux':
            uds_path = self.app_dir / "csqtt.sock"
            cmd.extend(["--tun-uds", str(uds_path)])
        
        if self.settings.get('turnHost'):
            cmd.extend(["-turn", self.settings['turnHost']])
        if self.settings.get('turnPort'):
            cmd.extend(["-port", self.settings['turnPort']])
        
        return cmd
    
    def get_free_port(self):
        sock = socket.socket()
        sock.bind(('127.0.0.1', 0))
        port = sock.getsockname()[1]
        sock.close()
        return port
    
    @pyqtSlot(result=bool)
    def disconnect(self):
        print("[API] disconnect()")
        self.is_connected = False
        
        self._cleanup_tunnel()
        
        if self.core_process and self.core_process.poll() is None:
            try:
                self.core_process.terminate()
                self.core_process.wait(timeout=3)
            except:
                try:
                    self.core_process.kill()
                except:
                    pass
        
        self.core_process = None
        self.status_changed.emit(False)
        self.log_updated.emit("Отключено")
        return True
    
    @pyqtSlot(str, result=bool)
    def saveConfig(self, link):
        print(f"[API] saveConfig: {link}")
        
        parsed = parse_csqtt_link(link)
        
        try:
            config_id = self.db.save(parsed)
            print(f"[API] Конфиг сохранён, ID: {config_id}")
            self.load_configs()
            return True
        except Exception as e:
            print(f"[API] Ошибка: {e}")
            return False
    
    @pyqtSlot(int, result=bool)
    def deleteConfig(self, config_id):
        print(f"[API] deleteConfig({config_id})")
        result = self.db.delete(config_id)
        if result:
            self.load_configs()
        return result
    
    @pyqtSlot(result=str)
    def getConfigsJson(self):
        return json.dumps(self.configs)
    
    @pyqtSlot(result=str)
    def getSettingsJson(self):
        return json.dumps(self.settings)
    
    @pyqtSlot(str, result=bool)
    def saveSettings(self, settings_json):
        print("[API] saveSettings")
        try:
            new_settings = json.loads(settings_json)
            
            if not new_settings.get('deviceId'):
                new_settings['deviceId'] = self.settings.get('deviceId', '')
            
            if not new_settings.get('deviceId'):
                new_settings['deviceId'] = uuid.uuid4().hex
                print(f"[API] Сгенерирован новый Device ID: {new_settings['deviceId']}")
            
            self.settings = new_settings
            self.save_settings_file()
            return True
        except Exception as e:
            print(f"[ERROR] saveSettings: {e}")
            return False
    
    @pyqtSlot(str, result=bool)
    def savePassword(self, password):
        print("[API] Password saved")
        self.password = password
        return True
    
    @pyqtSlot(result=bool)
    def clearLogs(self):
        print("[API] clearLogs")
        self.log_updated.emit("=== Логи очищены ===")
        return True
    
    def get_settings(self):
        return self.settings
