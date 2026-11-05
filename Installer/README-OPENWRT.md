# openwrt.sh — установщик LaLune для OpenWRT

Ставит на роутер ядро CSQTT и backend LaLune, запускает backend в фоне.

## Что делает

1. Создаёт `~/.la-lune/`.
2. Скачивает:
   - `~/.la-lune/csqtt-client-aarch64`
     — из `github.com/redline-keen/csqtt-openwrt/releases/download/0.5/`
   - `~/.la-lune/lalune-openwrt-backend`
     — из `github.com/Endlad2/LaLune/releases/download/26.10.03.18.32/`
3. `chmod +x` на оба бинарника.
4. Убивает старый backend (если был) и чистит pidfile.
5. Запускает backend в фоне (`setsid nohup` или `nohup`).
6. Пишет PID в `~/.la-lune/backend.pid`, лог в `~/.la-lune/LaLuneManager.log`.

## Использование

### На роутере (одной строкой)

```sh
wget -O - https://raw.githubusercontent.com/Endlad2/LaLune/main/Installer/openwrt.sh | sh
```

Или через `curl`:

```
curl -fsSL https://raw.githubusercontent.com/Endlad2/LaLune/main/Installer/openwrt.sh | sh
```

### Локально скачать и скопировать

```
scp LaLune/Installer/openwrt.sh root@192.168.1.1:/tmp/
ssh root@192.168.1.1 "sh /tmp/openwrt.sh"
```

### С флагами

```
sh openwrt.sh              # установить и запустить (по умолчанию)
sh openwrt.sh --force      # перекачать бинарники заново
sh openwrt.sh --stop       # остановить backend
sh openwrt.sh --status     # показать статус
```

## Проверка

После установки:

```
# На роутере
~/.la-lune/lalune-openwrt-backend &   # если ещё не запущен
curl http://127.0.0.1:1062/ping
```

Ожидаемый ответ:

```
{"ok":true,"version":"0.6.0","os":"linux","arch":"aarch64","platform":"openwrt",...}
```

## Из Frontend

В UI (Настройки → Экспериментальное → Роутеры → Подключить OpenWRT)
роутер найдётся автоматически сканером (`192.168.X.1:1062/ping`).

## Файлы

| Путь ↕▾ | Назначение ↕▾ |
|---|---|
| −`~/.la-lune/csqtt-client-aarch64` | ядро CSQTT |
| −`~/.la-lune/lalune-openwrt-backend` | HTTP-демон |
| −`~/.la-lune/backend.pid` | PID backend |
| −`~/.la-lune/LaLuneManager.log` | stdout/stderr backend |
| −`~/.la-lune/settings.json` | настройки (создаёт backend) |
| −`~/.la-lune/configs.db` | SQLite-конфиги (создаёт backend) |
| −`~/.la-lune/logs.log` | логи ядра (пишет ядро) |
⚙

## Автозапуск при загрузке роутера

Добавь в `/etc/rc.local` перед `exit 0`:

```
[ -x "$HOME/.la-lune/lalune-openwrt-backend" ] && \
    nohup "$HOME/.la-lune/lalune-openwrt-backend" >>"$HOME/.la-lune/LaLuneManager.log" 2>&1 &
```

Либо создай `/etc/init.d/lalune`:

```
#!/bin/sh /etc/rc.common
START=99
STOP=10

APP_DIR="$HOME/.la-lune"
BACKEND="$APP_DIR/lalune-openwrt-backend"

start() {
    [ -x "$BACKEND" ] || return 1
    nohup "$BACKEND" >>"$APP_DIR/LaLuneManager.log" 2>&1 &
    echo $! > "$APP_DIR/backend.pid"
}

stop() {
    [ -f "$APP_DIR/backend.pid" ] && kill "$(cat "$APP_DIR/backend.pid")" 2>/dev/null
    rm -f "$APP_DIR/backend.pid"
}

restart() { stop; sleep 1; start; }
```

Затем:

```
chmod +x /etc/init.d/lalune
/etc/init.d/lalune enable
/etc/init.d/lalune start
```

## Требования

- `curl` или `wget` в PATH (на OpenWRT обычно есть `wget` через busybox).
- `setsid` желателен (в busybox есть) — но не обязателен.
- `kill`, `sleep` — busybox.
- Архитектура роутера — **aarch64** (armsr/armv8). Для других архитектур
надо менять URL'ы в `CORE_URL` и `BACKEND_URL`.

## Troubleshooting

**Backend не запускается — смотри лог:**

```
tail -n 50 ~/.la-lune/LaLuneManager.log
```

**Порт 1062 занят:**

```
netstat -tlnp | grep 1062
```

**Роутер не виден из UI:**

- Проверь, что файрвол не блокирует порт 1062 (OpenWRT обычно не блокирует LAN).
- Проверь `curl http://<ip-роутера>:1062/ping` с того же устройства,
где открыт UI.

</BDS:create_file>
</BDS:LONG_WORK>

Готово. `LaLune/Installer/openwrt.sh` — POSIX-sh (busybox-совместимый):

- Скачивает оба бинарника в `~/.la-lune/` (curl, fallback на wget, retry, тихая `.part`-докачка).
- `chmod +x` на оба.
- Убивает старый backend по pidfile, ждёт graceful, потом SIGKILL.
- Запускает через `setsid nohup` (или просто `nohup`, если нет setsid).
- Пишет PID в `~/.la-lune/backend.pid`, лог в `~/.la-lune/LaLuneManager.log`.
- Флаги: `--force` (перекачать), `--stop`, `--status`, `--help`.

Запуск на роутере одной строкой:
```sh
wget -O - https://raw.githubusercontent.com/Endlad2/LaLune/main/Installer/openwrt.sh | sh

Заодно положил `README-OPENWRT.md` с инструкцией, путями файлов и вариантом init.d-скрипта для автозапуска.
