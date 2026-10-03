# LaLune Backend — OpenWRT

Отдельная сборка backend'а для OpenWRT-роутеров (armsr/armv8, musl).

## Отличия от Desktop

| Параметр ↕▾ | Desktop ↕▾ | OpenWRT ↕▾ |
|---|---|---|
| −Bind | `127.0.0.1:1062` | **`0.0.0.0:1062`** (LAN-доступ) |
| −Ядро | `client-linux-x86_64` | **`csqtt-client-aarch64`** (фиксировано) |
| −Сборка | нативный `cargo build` | OpenWRT SDK 25.12.5 `armsr/armv8` |
| −Директория | `~/.la-lune/` | `~/.la-lune/` |
| −Запуск | Desktop runner | вручную / init.d скрипт |
⚙

## Сборка через OpenWRT SDK

SDK скачивается автоматически скриптом `build.sh`:

```
cd Backend/OpenWRT
./build.sh
```

Скрипт:

1. Скачивает `openwrt-sdk-25.12.5-armsr-armv8_gcc-14.3.0_musl.Linux-x86_64.tar.zst` с `downloads.openwrt.org`.
2. Проверяет SHA256 (`1b0316604a3e820b2b008a1baff3f9dac6716af942bef800930e58c7de98c98b`).
3. Распаковывает в `.cache/openwrt-sdk/`.
4. Настраивает `CARGO_HOME`, `RUSTUP_HOME`, toolchain.
5. Собирает бинарник под `aarch64-unknown-linux-musl`.
6. Кладёт результат в `Backend/OpenWRT/output/lalune-openwrt-backend`.

## Установка на роутер

```
# С роутера
scp lalune-openwrt-backend root@192.168.1.1:/usr/bin/
ssh root@192.168.1.1

# На роутере
mkdir -p ~/.la-lune
mkdir -p ~/.la-lune/core
# Положить ядро
wget -O ~/.la-lune/csqtt-client-aarch64 \
  https://github.com/Endlad2/csqtt-core/releases/latest/download/client-linux-arm64
chmod +x ~/.la-lune/csqtt-client-aarch64

# Положить wintun? — на Linux не нужен.

# Запустить backend
nohup lalune-openwrt-backend > ~/.la-lune/LaLuneManager.log 2>&1 &

# Проверить
curl http://192.168.1.1:1062/ping
```

## Файлы данных

Всё в `~/.la-lune/`:

```
~/.la-lune/
├── configs.db
├── settings.json
├── token.json
├── logs.log
├── LATEST
└── csqtt-client-aarch64     ← ядро
```

## API

Полностью совпадает с `Backend/API.md` (Desktop). Отличие — bind на `0.0.0.0` вместо `127.0.0.1`.

## Что нужно доработать в UI

- Кнопка **«Подключить OpenWRT»** в Настройках → Экспериментальное.
- Скан `192.168.X.1:1062` (X=0..255).
- Ручной ввод IP.
- Список роутеров.
- При подключении — UI переключает все запросы с `127.0.0.1:1062` на `IP_роутера:1062`.
- Глобальный зелёный баннер сверху.

См. `Frontend/lib/state/router_notifier.dart` и `Frontend/lib/api/api_client.dart`.