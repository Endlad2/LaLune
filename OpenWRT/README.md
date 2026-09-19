# LaLune OpenWRT — веб-сервер на Go

Бинарник `LaLune-owrt_aarch64` — это веб-сервер с API на `/api/` и
фронтендом на `/`. Слушает порт **6543**.

## Установка

Однокомандник:

```sh
wget -qO- https://raw.githubusercontent.com/Endlad2/LaLune/main/OpenWRT/lalune-owrt-install.sh | sh
```

Скрипт:

1. `opkg update`
2. `opkg install curl ca-bundle kmod-tun`
3. Скачивает `LaLune-owrt_aarch64` из последнего релиза в `/usr/bin/lalune-owrt`
4. Создаёт `/etc/init.d/lalune-owrt`
5. Создаёт `/etc/csqtt/` для конфигов
6. Запускает сервис

## Использование

Открой `http://<router-ip>:6543` в браузере.

### Управление сервисом

```
/etc/init.d/lalune-owrt start
/etc/init.d/lalune-owrt stop
/etc/init.d/lalune-owrt restart
```

## API

| Метод ↕▾ ↕▾ | Endpoint ↕▾ ↕▾ | Описание ↕▾ ↕▾ |
|---|---|---|
| −−GET | −`/api/status` | `{"connected":bool,"installerRunning":bool,"coreRunning":bool}` |
| −−GET | −`/api/configs` | массив конфигов |
| −−POST | −`/api/configs` | `{"link":"csqtt://..."}` |
| −−DELETE | −`/api/configs?id=` | удалить конфиг |
| −−GET | −`/api/settings` | настройки |
| −−POST | −`/api/settings` | сохранить настройки |
| −−GET | −`/api/logs` | массив строк лога |
| −−POST | −`/api/logs/clear` | очистить лог |
| −−POST | −`/api/connect` | `{"configId":N}` — запустить установщик |
| −−POST | −`/api/disconnect` | остановить ядро |
| −−GET | −`/api/vktoken` | состояние токена |
| −−POST | −`/api/vktoken` | `{"token":"vk1.a..."}` |
| −−DELETE | −`/api/vktoken` | удалить токен |
| −−GET | −`/api/updates` | `{"update":bool,"version":"..."}` |
| −−POST | −`/api/updates` | запустить обновление |
| −⚙ |  |  |
⚙

## Конфиги

Хранятся в `/etc/csqtt/`:

| Файл ↕▾ | Назначение ↕▾ |
|---|---|
| −`configs.json` | список конфигов |
| −`settings.json` | настройки (authMode, workers, hashes, ...) |
| −`token.json` | VK-токен (`{"Token":"...","SavedAt":"..."}`) |
| −`csqtt.log` | лог ядра |
⚙

## Как запускается ядро

При нажатии «Подключиться»:

```
curl -fsSL -o /tmp/csqtt-install.sh \
  https://raw.githubusercontent.com/redline-keen/csqtt-openwrt/main/csqtt-github-install-openwrt.sh

sh /tmp/csqtt-install.sh 'csqtt://...' \
  --workers N --hashes M
  [--vk-token T]     # если authMode = autoVk
```

Где:

- `M` — `settings.hashes` (1..6)
- `N` — `settings.hashes` × `perHash`,
- `perHash = max(3, round(workers / hashes))`, округлённое до кратного 3.

## Сборка

Через GitHub Actions (`.github/workflows/build-openwrt.yml`) с официальным SDK:

```
SDK_URL="https://downloads.openwrt.org/releases/25.12.5/targets/armsr/armv8/openwrt-sdk-25.12.5-armsr-armv8_gcc-14.3.0_musl.Linux-x86_64.tar.zst"
curl -fsSL -o sdk.tar.zst "$SDK_URL"
mkdir sdk && tar --zstd -xf sdk.tar.zst -C sdk --strip-components=1
export PATH="$PWD/sdk/staging_dir/toolchain-aarch64_cortex-a53_gcc-14.3.0_musl/bin:$PATH"
export STAGING_DIR="$PWD/sdk/staging_dir"
export GOOS=linux GOARCH=arm64 CGO_ENABLED=1 CC=aarch64-openwrt-linux-gcc
cd OpenWRT && go build -ldflags="-s -w" -o ../LaLune-owrt_aarch64 .
```

## Лицензия

PolyForm Noncommercial License 1.0.0

