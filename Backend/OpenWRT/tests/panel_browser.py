# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
"""Run with Python Playwright and an installed Chrome: python tests/panel_browser.py."""

import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from threading import Thread

from playwright.sync_api import expect, sync_playwright

PANEL = Path(__file__).resolve().parents[1] / "src" / "panel"
PROTOCOLS = ["CSQTT", "CSQTTR", "CSQTT 2.1.9"]
PROFILE = {"id": 7, "name": "<img src=x>", "peer": "example.test:7000", "protocol": "CSQTTR 2.5.2"}


class Router(BaseHTTPRequestHandler):
    selected = None
    connected = False
    token = False
    settings = {"authMode": "manual", "workers": 9, "autoApiWorkers": 9}
    writes = []
    profiles = [PROFILE]

    def log_message(self, *_):
        pass

    def reply(self, payload, content_type="application/json"):
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.end_headers()
        self.wfile.write(payload if isinstance(payload, bytes) else json.dumps(payload).encode())

    def do_GET(self):
        assets = {
            "/panel": ("index.html", "text/html"),
            "/panel/panel.css": ("panel.css", "text/css"),
            "/panel/panel.js": ("panel.js", "text/javascript"),
        }
        if self.path in assets:
            name, mime = assets[self.path]
            if not (PANEL / name).is_file():
                self.send_error(404)
                return
            self.reply((PANEL / name).read_bytes(), mime + "; charset=utf-8")
            return
        responses = {
            "/core/protocols": [{"id": name, "displayName": name} for name in PROTOCOLS],
            "/configs": self.profiles,
            "/configs/selected": {"id": self.selected},
            "/settings": self.settings,
            "/vpn/status": {
                "connected": self.connected,
                "state": "connected" if self.connected else "disconnected",
                "uptimeSec": 9,
            },
            "/vk/token/state": {"hasToken": self.token},
            "/logs/tail?source=core&lines=100": ["[CORE] <script>"],
        }
        if self.path in responses:
            self.reply(responses[self.path])
        else:
            self.send_error(404)

    def write(self):
        size = int(self.headers.get("Content-Length", "0"))
        body = json.loads(self.rfile.read(size)) if size else None
        self.writes.append((self.command, self.path, body))
        cls = type(self)
        response = {"ok": True}
        match self.path:
            case "/configs":
                cls.profiles.append({"id": 8, "peer": "example.test:7001", **body})
                response = {"id": 8}
            case "/configs/8" if self.command == "PUT":
                cls.profiles[-1] = {"id": 8, **body}
            case "/configs/8" if self.command == "DELETE":
                cls.profiles.pop()
                cls.selected = None
            case "/configs/selected":
                cls.selected = body["id"]
            case "/settings":
                cls.settings.update(body)
            case "/vpn/connect":
                cls.connected = True
            case "/vpn/disconnect":
                cls.connected = False
            case "/vk/token/submit":
                cls.token = True
            case _:
                self.send_error(404)
                return
        self.reply(response)

    do_POST = do_PUT = do_PATCH = do_DELETE = write


def smoke_test(url):
    with sync_playwright() as playwright:
        browser = playwright.chromium.launch(channel="chrome")
        page = browser.new_page(viewport={"width": 390, "height": 844})
        page.set_default_timeout(8000)
        errors = []
        page.on("pageerror", lambda error: errors.append(error))
        response = page.goto(url + "/panel", wait_until="domcontentloaded", timeout=30000)
        assert response.ok, "Embedded panel must exist"
        expect(page.locator("#profile-select option").last).to_have_text("<img src=x> · CSQTTR 2.5.2")
        assert page.locator("img").count() == 0

        page.locator("#profile-select").select_option("7")
        page.get_by_role("button", name="Подключить", exact=True).click()
        expect(page.locator("#vpn-state")).to_have_text("Подключено")
        assert ("PUT", "/configs/selected", {"id": 7}) in Router.writes
        assert ("POST", "/vpn/connect", {"configId": 7}) in Router.writes
        page.get_by_role("button", name="Отключить", exact=True).click()
        expect(page.locator("#vpn-state")).to_have_text("Отключено")

        page.get_by_role("button", name="Добавить профиль").click()
        dialog = page.get_by_role("dialog")
        dialog.get_by_label("Название").fill("Резерв")
        dialog.get_by_label("Протокол").select_option("CSQTT 2.1.9")
        dialog.get_by_label("Ссылка").fill("csqtt://example.test:7001")
        dialog.get_by_role("button", name="Сохранить профиль").click()
        expect(page.locator("#profile-select")).to_have_value("8")
        assert ("POST", "/configs", {
            "link": "csqtt://example.test:7001", "protocol": "CSQTT 2.1.9", "name": "Резерв",
        }) in Router.writes
        page.get_by_role("button", name="Изменить", exact=True).click()
        dialog.get_by_label("Адрес сервера").fill("example.test:7002")
        dialog.get_by_label("Пароль", exact=True).fill("mock-password")
        dialog.get_by_role("button", name="Сохранить профиль").click()
        expect(page.locator("#vpn-message")).to_have_text("Профиль сохранён")
        assert ("PUT", "/configs/8", {
            "protocol": "CSQTT 2.1.9", "name": "Резерв", "peer": "example.test:7002",
            "password": "mock-password", "hashes": "",
        }) in Router.writes
        page.get_by_role("button", name="Изменить", exact=True).click()
        page.once("dialog", lambda confirmation: confirmation.accept())
        dialog.get_by_role("button", name="Удалить", exact=True).click()
        expect(page.locator("#profile-select")).to_have_value("")
        assert ("DELETE", "/configs/8", None) in Router.writes

        page.locator("#token-file").set_input_files({
            "name": "invalid.json", "mimeType": "application/json", "buffer": b"{}",
        })
        expect(page.locator("#token-message")).to_contain_text("Token")
        assert not any(path == "/vk/token/submit" for _, path, _ in Router.writes)
        page.locator("#token-file").set_input_files({
            "name": "token.json", "mimeType": "application/json",
            "buffer": b'{"Token":"mock-token-for-browser-test"}',
        })
        expect(page.locator("#token-state")).to_have_text("Токен загружен")
        assert ("POST", "/vk/token/submit", {"token": "mock-token-for-browser-test"}) in Router.writes
        assert "mock-token-for-browser-test" not in page.content()
        assert page.locator("#token-file").input_value() == ""
        page.get_by_label("Режим авторизации").select_option("autoApi")
        page.get_by_label("Воркеров на хеш").fill("18")
        page.get_by_role("button", name="Сохранить настройки").click()
        expect(page.locator("#settings-message")).to_have_text("Настройки сохранены")
        assert ("PATCH", "/settings", {"authMode": "autoApi", "autoApiWorkers": 18}) in Router.writes

        page.get_by_text("Журнал ядра", exact=True).click()
        expect(page.locator("#log-output")).to_have_text("[CORE] <script>")
        assert page.locator("#log-output script").count() == 0
        assert page.evaluate("document.documentElement.scrollWidth === innerWidth")
        page.set_viewport_size({"width": 1280, "height": 900})
        assert page.evaluate("document.documentElement.scrollWidth === innerWidth")
        assert not errors
        browser.close()


if __name__ == "__main__":
    with ThreadingHTTPServer(("127.0.0.1", 0), Router) as server:
        worker = Thread(target=server.serve_forever, daemon=True)
        worker.start()
        try:
            smoke_test(f"http://127.0.0.1:{server.server_port}")
        finally:
            server.shutdown()
            worker.join()
    print("OpenWrt panel browser smoke test passed")
