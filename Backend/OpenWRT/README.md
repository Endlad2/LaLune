# LaLune Backend — OpenWRT

Backend для OpenWrt: ARM64 (`armsr/armv8`) и `ramips/mt7621` (`mipsel_24kc`).

## Панель и AutoAPI

Откройте `http://<IP роутера>:1062/panel` из доверенной локальной сети.
Панель встроена в backend и не загружает ресурсы из Интернета. В ней можно
добавить или изменить профиль, выбрать ядро, подключить VPN, сохранить настройки
и смотреть журнал. Используется тот же API и то же хранилище, что в LaLune.
Порт 1062 не следует публиковать в WAN: существующий API рассчитан на доверенную LAN.

Для AutoAPI импортируйте JSON с полем `Token` или `token`, выберите «Авто API»,
сохраните настройки и подключите профиль. Токен хранится на роутере в
`token.json` с правами `0600`. Backend получает хеши звонков при подключении
и закрывает известные звонки этой сессии при остановке. Токен не возвращается
через панель. При AutoVK он передаётся ядру через stdin.
Проверка хешей отдельной командой ядра в панели не предлагается: эта команда
завершает процесс после проверки и не запускает VPN.

История backend и ядра хранится в `logs.log.gz` и `logs.log.1.gz`: суммарно
до 130 КиБ, плюс небольшая очередь в памяти. Старый `logs.log` переносится
с сохранением последних строк. Показ, экспорт и очистка логов идут через API;
очистка истории не сбрасывает готовность запущенного ядра.

## Отличия от Desktop

| Параметр ↕▾ | Desktop ↕▾ | OpenWRT ↕▾ |
|---|---|---|
| −Bind | `127.0.0.1:1062` | **`0.0.0.0:1062`** (LAN-доступ) |
| −Ядро | `client-linux-x86_64` | ARM: `csqtt-client-aarch64`; ramips: три встроенных ядра |
| −Сборка | нативный `cargo build` | OpenWrt SDK 25.12.5 для целевой архитектуры |
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

Для ramips запустите `bash Backend/OpenWRT/build-ramips.sh` на Linux x86_64.
В CI за это отвечает отдельная задача **OpenWRT Backend (ramips)**.
Она проверяет SHA256 SDK и трёх исходных архивов, собирает ядра CSQTT, CSQTTR
и CSQTT 2.1.9 (коммит `eda00fce6343430b40413da01791946dccb9c6ff`),
проверяет ABI ELF, упаковывает ядра через `zip -9` и включает ZIP в
`lalune-openwrt-backend-ramips`. При подключении извлекается только выбранное
ядро. Встроенные ядра обновляются вместе с backend. PaperFlux в этой сборке нет.

## Установка на роутер

Запускайте backend от `root`: ему нужны TUN, изменение маршрутов и запуск CSQTT под отдельным UID. На роутере должны быть `kmod-tun` и `ip-full` с поддержкой `ip rule uidrange`; облегчённого `ip` недостаточно. UI-установщик при необходимости пытается подготовить TUN, `ip` и CA/download-инструменты.

Требования к policy routing, восстановление DNS, ограничения IPv4 и воспроизводимые проверки описаны в [инструкции проверки Linux TUN](../tests/README.md).

```
# На роутере
mkdir -p ~/la-lune ~/.la-lune
wget -O ~/la-lune/lalune-openwrt-backend \
  https://github.com/Endlad2/LaLune/releases/latest/download/lalune-openwrt-backend
chmod +x ~/la-lune/lalune-openwrt-backend

# Ядро нужно только если его ещё нет.
wget -O ~/.la-lune/csqtt-client-aarch64 \
  https://github.com/Endlad2/csqtt-core/releases/latest/download/client-linux-arm64
chmod +x ~/.la-lune/csqtt-client-aarch64

# На Linux Wintun не нужен.
nohup ~/la-lune/lalune-openwrt-backend > ~/.la-lune/LaLuneManager.log 2>&1 &

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
├── logs.log.gz
├── logs.log.1.gz
├── LATEST
└── csqtt-client-aarch64     ← ядро
```

## API

Основные маршруты описаны в [Backend/API.md](../API.md). Список доступных
протоколов возвращает `GET /core/protocols`; он зависит от сборки backend.

## Что нужно доработать в UI

- Кнопка **«Подключить OpenWRT»** в Настройках → Экспериментальное.
- Скан `192.168.X.1:1062` (X=0..255).
- Ручной ввод IP.
- Список роутеров.
- При подключении — UI переключает все запросы с `127.0.0.1:1062` на `IP_роутера:1062`.
- Глобальный зелёный баннер сверху.

См. `Frontend/lib/state/router_notifier.dart` и `Frontend/lib/api/api_client.dart`.
