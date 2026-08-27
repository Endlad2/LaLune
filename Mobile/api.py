# Mobile/api.py
# API мост для взаимодействия JS ↔ Python на мобильных устройствах (Kivy)

import json
import hashlib
from pathlib import Path
from kivy.logger import Logger
from kivy.clock import Clock

class MobileAPI:
    """
    API-мост для мобильного приложения (Kivy).
    Предоставляет методы для вызова из JavaScript.
    """
    
    def __init__(self, app):
        self.app = app
        self.webview = None
        self.configs = []
        self.settings = {}
        self.password = ""
        self.is_connected = False
        self.configs_file = Path("configs.json")
        self.settings_file = Path("settings.json")
        self.load_configs()
        self.load_settings()
    
    def set_webview(self, webview):
        """Установка WebView для выполнения JS"""
        self.webview = webview
    
    def load_configs(self):
        """Загрузка конфигов из файла"""
        if self.configs_file.exists():
            try:
                with open(self.configs_file, 'r', encoding='utf-8') as f:
                    self.configs = json.load(f)
                self.refresh_configs_js()
            except Exception as e:
                Logger.error(f"MobileAPI: load_configs error - {e}")
                self.configs = []
        else:
            # Демо-конфиг
            self.configs = [{
                'id': 1,
                'name': 'Demo Config',
                'protocol': 'CSQTT',
                'link': 'csqtt://connect?v=2&host=example.com'
            }]
            self.save_configs()
    
    def save_configs(self):
        """Сохранение конфигов"""
        try:
            with open(self.configs_file, 'w', encoding='utf-8') as f:
                json.dump(self.configs, f, ensure_ascii=False, indent=2)
            self.refresh_configs_js()
        except Exception as e:
            Logger.error(f"MobileAPI: save_configs error - {e}")
    
    def load_settings(self):
        """Загрузка настроек"""
        if self.settings_file.exists():
            try:
                with open(self.settings_file, 'r', encoding='utf-8') as f:
                    self.settings = json.load(f)
            except Exception as e:
                Logger.error(f"MobileAPI: load_settings error - {e}")
                self.settings = {}
        else:
            self.settings = {
                'peer': '203.0.113.10:46000',
                'vkHashes': '',
                'turnHost': 'turn.example.com',
                'turnPort': '3478',
                'workersPerHash': 9,
                'obfs': 'video',
                'fingerprint': 'firefox',
                'clientIds': '8202606,6287487',
                'vkAuthMode': 'vkcalls',
                'captchaMode': 'auto',
                'deviceId': '',
                'autoConnect': False
            }
            self.save_settings()
    
    def save_settings(self):
        """Сохранение настроек"""
        try:
            with open(self.settings_file, 'w', encoding='utf-8') as f:
                json.dump(self.settings, f, ensure_ascii=False, indent=2)
        except Exception as e:
            Logger.error(f"MobileAPI: save_settings error - {e}")
    
    def refresh_configs_js(self):
        """Обновление конфигов в JavaScript"""
        if self.webview:
            js_code = f"refreshConfigs({json.dumps(self.configs)})"
            self.webview.execute_javascript(js_code)
    
    def execute_js(self, js_code):
        """Выполнение JavaScript в WebView"""
        if self.webview:
            self.webview.execute_javascript(js_code)
    
    # === Методы для вызова из JavaScript ===
    
    def log(self, message):
        """Логирование из JavaScript"""
        Logger.info(f"JS: {message}")
        self.app.log_callback(f"JS: {message}")
    
    def connect(self, config_id):
        """Подключение к конфигу"""
        Logger.info(f"MobileAPI: Connecting to config {config_id}")
        config = next((c for c in self.configs if c['id'] == config_id), None)
        if not config:
            Logger.error(f"MobileAPI: Config {config_id} not found")
            return False
        
        # Здесь будет логика подключения CSQTT
        Logger.info(f"MobileAPI: Connecting to {config['link']}")
        
        # Имитация подключения
        self.is_connected = True
        self.app.status_callback(True)
        self.app.log_callback(f"Подключено к {config['name']}")
        return True
    
    def disconnect(self):
        """Отключение"""
        Logger.info("MobileAPI: Disconnecting")
        self.is_connected = False
        self.app.status_callback(False)
        self.app.log_callback("Отключено")
        return True
    
    def saveConfig(self, link):
        """Сохранение нового конфига"""
        Logger.info(f"MobileAPI: Saving config: {link}")
        config_id = abs(hash(link) % 1000000)
        config = {
            'id': config_id,
            'name': f'Config {len(self.configs) + 1}',
            'protocol': 'CSQTT',
            'link': link
        }
        self.configs.append(config)
        self.save_configs()
        return True
    
    def deleteConfig(self, config_id):
        """Удаление конфига"""
        Logger.info(f"MobileAPI: Deleting config: {config_id}")
        self.configs = [c for c in self.configs if c['id'] != config_id]
        self.save_configs()
        return True
    
    def getConfigsJson(self):
        """Получение конфигов в JSON"""
        return json.dumps(self.configs)
    
    def saveSettings(self, settings_json):
        """Сохранение настроек"""
        Logger.info("MobileAPI: Saving settings")
        try:
            self.settings = json.loads(settings_json)
            self.save_settings()
            return True
        except Exception as e:
            Logger.error(f"MobileAPI: saveSettings error - {e}")
            return False
    
    def savePassword(self, password):
        """Сохранение пароля"""
        Logger.info("MobileAPI: Password saved")
        self.password = password
        return True
    
    def clearLogs(self):
        """Очистка логов"""
        Logger.info("MobileAPI: Logs cleared")
        self.app.log_callback("=== Логи очищены ===")
        return True
    
    def get_settings(self):
        """Получение настроек (для Python-части)"""
        return self.settings
