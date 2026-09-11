# LaLune для OpenWRT — Установка

## Что это

Клиент LaLune (VPN на протоколе CSQTT) в виде нативного LuCI-приложения.
После установки в панели роутера появляется раздел **«LaLune»** с вкладками:

- **Соединение** — статус, выбор конфига, кнопки Подключить / Отключить
- **Конфиги** — список сохранённых конфигов и добавление новых
- **Настройки** — Peer, пароль, VK-хеши, воркеры, obfs, fingerprint, client IDs, Device ID (с кнопкой «Перегенерировать»)
- **Логи** — просмотр логов ядра в реальном времени
- **Информация** — версии ядра (ваш формат LATEST + человеческий CSQTT), проверка обновлений ядра и LaLune

## Требования

- OpenWRT 21.02 или новее
- Архитектура: `arm` (ARMv7) или `arm64` (aarch64)
- Пакеты:
  - `luci-base` (идёт с любой установленной LuCI)
  - `ip-full` (утилита `ip` с полным набором команд)
  - `kmod-tun` (модуль ядра TUN)

## Установка через opkg

### Если у вас уже есть собранные .ipk

Скопируйте оба пакета на роутер и установите:

```sh
scp lalune_0.5.0-1_arm_cortex-a7.ipk root@192.168.1.1:/tmp/
scp luci-app-lalune_0.5.0-1_all.ipk root@192.168.1.1:/tmp/

ssh root@192.168.1.1
opkg update
opkg install /tmp/lalune_0.5.0-1_arm_cortex-a7.ipk
opkg install /tmp/luci-app-lalune_0.5.0-1_all.ipk
```

После установки:

```
/etc/init.d/lalune enable
/etc/init.d/lalune start
```

Откройте LuCI → **Services → LaLune**.

### Если .ipk нет — установка вручную

Скачайте архив `LaLune-OpenWRT-arm64.zip` (или `armv7`) из
[Releases](https://github.com/Endlad2/LaLune/releases).

Распакуйте на роутере в `/`:

```
cd /tmp
curl -L -o LaLune-OpenWRT-arm64.zip \
  https://github.com/Endlad2/LaLune/releases/latest/download/LaLune-OpenWRT-arm64.zip
unzip -o LaLune-OpenWRT-arm64.zip -d /
chmod +x /usr/bin/lalune
/etc/init.d/lalune enable
/etc/init.d/lalune start
```

## Сборка через OpenWRT SDK

### 1. Установка SDK

```
# Пример для OpenWRT 23.05, ARMv7
wget https://downloads.openwrt.org/releases/23.05.0/targets/armsr/armv7/openwrt-sdk-23.05.0-armsr-armv7_gcc-12.3.0_musl.Linux-x86_64.tar.xz
tar xf openwrt-sdk-23.05.0-armsr-armv7_gcc-12.3.0_musl.Linux-x86_64.tar.xz
cd openwrt-sdk-23.05.0-armsr-armv7_gcc-12.3.0_musl.Linux-x86_64
```

Для ARM64 используйте соответствующий SDK `armsr/armv8`.

### 2. Клонирование исходников

```
mkdir -p package/lalune
cp -r /path/to/LaLune/OpenWRT/lalune/* package/lalune/
mkdir -p package/luci-app-lalune
cp -r /path/to/LaLune/OpenWRT/luci-app-lalune/* package/luci-app-lalune/
```

### 3. Сборка

```
./scripts/feeds update -a
./scripts/feeds install -a

make menuconfig
#  → Network → VPN → lalune
#  → LuCI → 3. Applications → luci-app-lalune

make package/lalune/compile V=s
make package/luci-app-lalune/compile V=s
```

Готовые .ipk будут в `bin/packages/<arch>/base/` и `bin/packages/<arch>/luci/`.

### 4. Установка на роутер

```
scp bin/packages/arm_cortex-a7/base/lalune_*.ipk root@192.168.1.1:/tmp/
scp bin/packages/arm_cortex-a7/luci/luci-app-lalune_*.ipk root@192.168.1.1:/tmp/

ssh root@192.168.1.1
opkg install /tmp/lalune_*.ipk /tmp/luci-app-lalune_*.ipk
```

## Первый запуск

1. Откройте LuCI → **Services → LaLune → Настройки**
2. Заполните Peer, Password, VK Hashes (или загрузите конфиг на вкладке «Конфиги»)
3. Сохраните настройки
4. Перейдите на вкладку **Информация**, нажмите **«Проверить обновления ядра»** — ядро скачается автоматически под вашу архитектуру
5. Вернитесь на **Соединение**, выберите конфиг, нажмите **Подключить**

## Ручное управление через CLI

Демон также ставит CLI `/usr/bin/lalune`:

```
lalune status              # текущий статус (JSON из /var/run/lalune/status.json)
lalune version             # версии ядра: local + remote
lalune core-check          # проверить обновление ядра (без скачивания)
lalune core-update         # скачать/обновить ядро под текущую архитектуру
lalune connect 1           # подключиться к конфигу с ID=1
lalune disconnect          # отключиться
lalune config-list         # список конфигов
lalune config-add 'csqtt://connect?v=2&host=...&password=...'
lalune config-delete 2     # удалить конфиг
lalune settings-get        # все настройки
lalune settings-set '{...}' # сохранить настройки
lalune device-id           # текущий deviceId
lalune device-id-regenerate # перегенерировать deviceId
lalune lalune-check        # проверить обновление LaLune (заглушка)
```

## Файлы и каталоги

| Путь ↕▾ | Назначение ↕▾ |
|---|---|
| −`/usr/bin/lalune` | Go-демон + CLI (один бинарь) |
| −`/etc/init.d/lalune` | procd init-скрипт |
| −`/etc/config/lalune` | UCI-конфиг (только `enabled`) |
| −`/etc/lalune/settings.json` | Общие настройки (единый формат с Desktop/Android) |
| −`/etc/lalune/configs.json` | Список конфигов подключения |
| −`/etc/lalune/core/` | Скачанное ядро CSQTT + файл LATEST |
| −`/var/run/lalune/status.json` | Статус (обновляется демоном, читает LuCI) |
| −`/var/run/lalune/daemon.sock` | Unix-сокет для CLI↔демон |
| −`/var/log/lalune.log` | Лог демона |
| −`/var/log/lalune-core.log` | Лог ядра CSQTT |
⚙

## Как маршрутизировать трафик через LaLune

После подключения создаётся TUN-интерфейс `csqtt0` с адресом из TUNCONF.
**Дефолтный маршрут демон не трогает.** Ты сам решаешь, какие пакеты пойдут через VPN.

### Пример 1: весь трафик через VPN

В LuCI → **Network → Routing** добавь default route через `csqtt0`. Или через CLI:

```
ip route add default dev csqtt0
```

Чтобы откатить:

```
ip route del default dev csqtt0
```

### Пример 2: только выборочные IP через VPN

```
# Через VPN пойдёт только трафик к 1.2.3.4
ip route add 1.2.3.4/32 dev csqtt0
```

### Пример 3: через firewall + ipset

Создай ipset с нужными подсетями и направь его в `csqtt0` через `nft`/`iptables`.
Это уже за пределами LaLune — роутер даёт все инструменты.

## Обновление

### Обновление ядра

На вкладке **Информация** нажми **«Проверить обновления ядра»**:

- **«Версия (ваш формат)»** — то, что скачано сейчас (например, `26.09.11.17.17`), или `-` если ядро не скачано
- **«Версия (LATEST)»** — то, что сервер отдаёт прямо сейчас
- **«CSQTT (kernel)»** — человеческий номер (например, `2.1.9`)

Если версии отличаются — появится кнопка **«Обновить ядро»**. Она скачает бинарь
под твою архитектуру и атомарно заменит старый.

Ядро скачивается с `github.com/Endlad2/csqtt-core/releases/download/<ver>/client-linux-<arch>`,
где `<ver>` — содержимое `raw.githubusercontent.com/Endlad2/csqtt-core/refs/heads/main/LATEST`.

### Обновление LaLune

На той же вкладке **Информация** есть кнопка **«Проверка обновлений для LaLune»** —
сейчас она работает как заглушка (возвращает «обновлений нет»). Полноценная
интеграция с релизами LaLune будет добавлена позже.

## Troubleshooting

### Ядро не скачивается

Проверь связь с GitHub:

```
wget -O- https://raw.githubusercontent.com/Endlad2/csqtt-core/refs/heads/main/LATEST
```

Если напрямую не работает — используется прокси-фоллбэк `http://31.77.148.203:8855/?url=...`.
Он встроен в демон.

### TUN не поднимается

Проверь наличие модуля:

```
lsmod | grep tun
```

Если пусто:

```
opkg install kmod-tun
modprobe tun
```

### Не идёт трафик после подключения

По логам ядра (`lalune logs` или `cat /var/log/lalune-core.log`) убедись,
что есть строка `[СТАТИСТИКА] Активных: N` с N > 0. Если N = 0, значит ядро
не смогло установить сессию — проблема в конфиге или в сети.

Если N > 0, но трафик не идёт — проверь маршруты:

```
ip route show
ip addr show csqtt0
```

TUN есть, но default route не через него — так и задумано. Добавь маршрут сам.

### Логи демона

```
logread | grep lalune
tail -f /var/log/lalune.log
tail -f /var/log/lalune-core.log
```

### Логи LuCI

LuCI-страницы пишут ошибки в браузерную консоль (F12). Если что-то не работает
в UI — открой консоль и посмотри.

## Структура пакета

```
/usr/bin/lalune                      — Go-демон + CLI
/etc/init.d/lalune                   — procd
/etc/config/lalune                   — UCI (enabled)
/etc/lalune/settings.json            — настройки (единый формат)
/etc/lalune/configs.json             — конфиги
/etc/lalune/core/client-linux-<arch> — ядро CSQTT
/etc/lalune/core/LATEST              — текущая скачанная версия
/usr/lib/lua/luci/controller/lalune.lua
/usr/lib/lua/luci/model/cbi/lalune/settings.lua
/usr/lib/lua/luci/model/cbi/lalune/configs.lua
/usr/lib/lua/luci/view/lalune/status.htm
/usr/lib/lua/luci/view/lalune/logs.htm
/usr/lib/lua/luci/view/lalune/info.htm
/usr/lib/lua/luci/view/lalune/configs_list.htm
/usr/lib/lua/luci/view/lalune/device_id_field.htm
```

## Лицензия

PolyForm Noncommercial License 1.0.0. Коммерческое использование запрещено.

