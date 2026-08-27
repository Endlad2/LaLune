#!/usr/bin/env python3
# -*- coding: utf-8 -*-

"""
LaLune Mobile - Kivy приложение с WebView
"""

import os
import sys
import json
from pathlib import Path

from kivy.app import App
from kivy.uix.boxlayout import BoxLayout
from kivy.uix.label import Label
from kivy.uix.button import Button
from kivy.uix.widget import Widget
from kivy.clock import Clock
from kivy.logger import Logger
from kivy.core.window import Window
from kivy.config import Config
from kivy.graphics import Color, Rectangle

# Настройка окна
Config.set('graphics', 'width', '420')
Config.set('graphics', 'height', '800')
Config.set('graphics', 'resizable', False)

# Для отладки на Windows
if sys.platform == 'win32':
    try:
        import ctypes
        ctypes.windll.user32.SetProcessDPIAware()
    except:
        pass

from api import MobileAPI

class WebViewWidget(Widget):
    """
    Виджет для отображения HTML через WebView.
    Использует kivy-garden.xwebview если доступен.
    """
    def __init__(self, html_content='', **kwargs):
        super().__init__(**kwargs)
        self.html_content = html_content
        self.webview = None
        self._create_webview()
    
    def _create_webview(self):
        """Создание WebView"""
        try:
            # Пробуем использовать kivy-garden.xwebview (Android/Windows)
            from kivy_garden.xwebview import XWebView
            self.webview = XWebView()
            self.webview.load_html(self.html_content, 'file:///')
            self.add_widget(self.webview)
            Logger.info('WebView: Используется kivy-garden.xwebview')
            return
        except ImportError:
            Logger.warning('WebView: kivy-garden.xwebview не найден')
        
        # Если kivy-garden.xwebview не доступен
        self.add_widget(Label(
            text='⚠️ WebView не доступен\nУстановите:\npip install kivy-garden.xwebview',
            color=(1, 0.7, 0.2, 1),
            font_size=16,
            halign='center',
            valign='middle'
        ))
        Logger.error('WebView: Нет доступных бэкендов!')
    
    def load_html(self, html_content):
        """Загрузка HTML-контента"""
        self.html_content = html_content
        if self.webview and hasattr(self.webview, 'load_html'):
            self.webview.load_html(html_content, 'file:///')
    
    def execute_javascript(self, js_code):
        """Выполнение JavaScript в WebView"""
        if self.webview and hasattr(self.webview, 'evaluate_javascript'):
            self.webview.evaluate_javascript(js_code)

class LaLuneMobileApp(App):
    """Мобильное приложение LaLune"""
    
    def __init__(self, **kwargs):
        super().__init__(**kwargs)
        self.title = 'LaLune Mobile'
        
        # API-мост
        self.api = MobileAPI(self)
        
        # Callbacks для обновления UI
        self.log_callback = self.on_log
        self.status_callback = self.on_status
    
    def build(self):
        """Создание интерфейса"""
        # Основной контейнер
        layout = BoxLayout(orientation='vertical')
        
        # Загрузка HTML
        html_path = Path(__file__).parent.parent / "Frontend" / "app.html"
        html_content = ""
        if html_path.exists():
            try:
                html_content = html_path.read_text(encoding='utf-8')
                Logger.info(f"HTML loaded from: {html_path}")
            except Exception as e:
                Logger.error(f"Error loading HTML: {e}")
                html_content = self.get_error_html(str(html_path))
        else:
            html_content = self.get_error_html(str(html_path))
            Logger.error(f"HTML not found: {html_path}")
        
        # WebView
        self.webview = WebViewWidget(html_content)
        self.api.set_webview(self.webview)
        layout.add_widget(self.webview)
        
        # Кнопка перезагрузки (для отладки)
        if sys.platform == 'win32':
            reload_btn = Button(
                text='🔄',
                size_hint=(None, None),
                size=(40, 40),
                pos=(10, 10),
                background_color=(0.29, 0.42, 0.97, 0.8)
            )
            reload_btn.bind(on_press=self.reload_webview)
            layout.add_widget(reload_btn)
        
        return layout
    
    def get_error_html(self, path):
        """HTML для ошибки"""
        return f"""
        <html>
        <body style="background:#0a0e2a;color:white;display:flex;justify-content:center;align-items:center;height:100vh;font-family:monospace;text-align:center;">
            <div>
                <h1 style="color:#f7e84e;">⚠️ Ошибка</h1>
                <p>Файл не найден: {path}</p>
                <p style="color:rgba(255,255,255,0.5);">Убедитесь, что Frontend/app.html существует</p>
                <p style="color:rgba(255,255,255,0.3);font-size:12px;">Рабочая директория: {os.getcwd()}</p>
            </div>
        </body>
        </html>
        """
    
    def reload_webview(self, instance=None):
        """Перезагрузка WebView"""
        html_path = Path(__file__).parent.parent / "Frontend" / "app.html"
        if html_path.exists():
            html_content = html_path.read_text(encoding='utf-8')
            self.webview.load_html(html_content)
            Logger.info('WebView reloaded')
    
    def on_log(self, message):
        """Обработка логов"""
        # Передаем в JS
        if self.webview:
            escaped = message.replace("'", "\\'").replace("\n", "\\n")
            js_code = f"appendLog('{escaped}')"
            self.webview.execute_javascript(js_code)
    
    def on_status(self, connected):
        """Обработка изменения статуса"""
        if self.webview:
            js_code = f"setConnected({str(connected).lower()})"
            self.webview.execute_javascript(js_code)
    
    def on_start(self):
        """Запуск приложения"""
        Logger.info("LaLune Mobile started")
        
        # Загружаем конфиги в JS после загрузки страницы
        Clock.schedule_once(self.load_configs_to_js, 1.0)
    
    def load_configs_to_js(self, dt):
        """Загрузка конфигов в JS"""
        configs_json = self.api.getConfigsJson()
        if self.webview:
            self.webview.execute_javascript(f"refreshConfigs({configs_json})")
            Logger.info("Configs sent to JS")
        
        # Если включено автоподключение
        if self.api.settings.get('autoConnect', False) and self.api.configs:
            Clock.schedule_once(lambda dt: self.webview.execute_javascript("toggleConnect();"), 0.5)

def main():
    """Точка входа"""
    try:
        app = LaLuneMobileApp()
        app.run()
    except Exception as e:
        Logger.error(f"Fatal error: {e}")
        import traceback
        traceback.print_exc()

if __name__ == '__main__':
    main()
