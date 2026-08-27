import sys
import os
import json
import ctypes
from pathlib import Path

from PyQt6.QtCore import Qt, QUrl, QTimer
from PyQt6.QtWidgets import QApplication, QMainWindow, QVBoxLayout, QWidget, QMessageBox
from PyQt6.QtWebEngineWidgets import QWebEngineView
from PyQt6.QtWebChannel import QWebChannel

from api import DesktopAPI


def ensure_admin():
    if sys.platform == 'win32':
        try:
            is_admin = ctypes.windll.shell32.IsUserAnAdmin()
        except:
            is_admin = False
        if not is_admin:
            ctypes.windll.shell32.ShellExecuteW(
                None, "runas", sys.executable, " ".join(sys.argv), None, 1
            )
            sys.exit(0)


class LaLuneDesktop(QMainWindow):
    def __init__(self):
        super().__init__()
        
        self.setWindowTitle("LaLune")
        self.setGeometry(100, 100, 480, 850)
        self.setMinimumSize(360, 600)
        self.setMaximumSize(1920, 1080)
        
        central_widget = QWidget()
        self.setCentralWidget(central_widget)
        layout = QVBoxLayout(central_widget)
        layout.setContentsMargins(0, 0, 0, 0)
        
        self.webview = QWebEngineView()
        self.webview.setContextMenuPolicy(Qt.ContextMenuPolicy.NoContextMenu)
        
        self.api = DesktopAPI(self)
        
        self.channel = QWebChannel()
        self.channel.registerObject("api", self.api)
        self.webview.page().setWebChannel(self.channel)
        
        self.api.log_updated.connect(self.on_log_updated)
        self.api.status_changed.connect(self.on_status_changed)
        self.api.configs_updated.connect(self.on_configs_updated)
        self.api.update_available.connect(self.on_update_available)
        
        html_path = Path(__file__).parent.parent / "Frontend" / "app.html"
        if html_path.exists():
            html_url = QUrl.fromLocalFile(str(html_path))
            self.webview.load(html_url)
            print(f"[INFO] Loaded: {html_path}")
        else:
            error_html = "<html><body style='background:#0a0e2a;color:white;display:flex;justify-content:center;align-items:center;height:100vh;font-family:monospace;'><div><h1 style='color:#f7e84e;'>ERROR</h1><p>File not found</p></div></body></html>"
            self.webview.setHtml(error_html)
        
        layout.addWidget(self.webview)
        
        self.webview.loadFinished.connect(self.on_load_finished)
    
    def on_load_finished(self, ok):
        if ok:
            configs_json = self.api.getConfigsJson()
            safe_json = json.dumps(configs_json)
            self.webview.page().runJavaScript(
                f"if (typeof refreshConfigs === 'function') refreshConfigs({safe_json});"
            )
            
            settings_json = self.api.getSettingsJson()
            safe_settings = json.dumps(settings_json)
            self.webview.page().runJavaScript(
                f"if (typeof refreshSettings === 'function') refreshSettings({safe_settings});"
            )
            
            print("[INFO] Page loaded, configs and settings sent to JS")
            
            if self.api.settings.get('autoConnect', False) and self.api.configs:
                QTimer.singleShot(1000, lambda: self.webview.page().runJavaScript("toggleConnect();"))
    
    def on_log_updated(self, message):
        safe_msg = json.dumps(message)
        self.webview.page().runJavaScript(
            f"if (typeof appendLog === 'function') appendLog({safe_msg});"
        )
    
    def on_status_changed(self, connected):
        self.webview.page().runJavaScript(
            f"if (typeof setConnected === 'function') setConnected({'true' if connected else 'false'});"
        )
    
    def on_configs_updated(self, configs_json):
        safe_json = json.dumps(configs_json)
        self.webview.page().runJavaScript(
            f"if (typeof refreshConfigs === 'function') refreshConfigs({safe_json});"
        )
    
    def on_update_available(self, version):
        safe_version = json.dumps(version)
        self.webview.page().runJavaScript(
            f"if (typeof showUpdateBanner === 'function') showUpdateBanner({safe_version});"
        )
    
    def closeEvent(self, event):
        reply = QMessageBox.question(
            self, "Выход", "Закрыть приложение?",
            QMessageBox.StandardButton.Yes | QMessageBox.StandardButton.No,
            QMessageBox.StandardButton.No
        )
        if reply == QMessageBox.StandardButton.Yes:
            if self.api.is_connected:
                self.api.disconnect()
            event.accept()
        else:
            event.ignore()


def main():
    ensure_admin()
    
    app = QApplication(sys.argv)
    app.setApplicationName("LaLune")
    app.setOrganizationName("LaLune")
    
    window = LaLuneDesktop()
    window.show()
    
    sys.exit(app.exec())


if __name__ == "__main__":
    main()