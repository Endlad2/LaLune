# luci-app-csqtt

LuCI-приложение для OpenWRT, которое даёт веб-UI для подключения к CSQTT
(тот же протокол, что использует LaLune).

## Что умеет

- Поле ввода **csqtt://** ссылки
- Поле ввода **VK-токена**
- Поля **количество хешей** (1..6, дефолт 3) и **количество воркеров** (1..127, дефолт 27)
- Кнопка **«Подключить»** — запускает официальный установочный скрипт:
```

curl -fsSL [https://raw.githubusercontent.com/redline-keen/csqtt-openwrt/refs/heads/main/csqtt-github-install-openwrt.sh](https://raw.githubusercontent.com/redline-keen/csqtt-openwrt/refs/heads/main/csqtt-github-install-openwrt.sh) -o /tmp/csqtt-install.sh
sh /tmp/csqtt-install.sh 'csqtt://...' --hashes N --workers M --vk-token TOKEN

```
- Кнопка **«Отключить»** — останавливает активную сессию и убивает ядро
- Кнопка **«Обновить логи»** — читает `/etc/csqtt/csqtt.log`
- Вкладка **«Поддержать»** — реквизиты авторов

## Где что лежит

| Что | Путь |
|---|---|
| Лог | `/etc/csqtt/csqtt.log` (+ `.log.1` при ротации) |
| PID установщика | `/var/run/csqtt/install.pid` |
| Скачанный установщик | `/etc/csqtt/csqtt-install.sh` |
| UI | `htdocs/luci-static/resources/view/csqtt/main.js` |
| RPC-демон | `root/usr/libexec/rpcd/luci.csqtt` |

## Требования

- OpenWRT 23.05+ / 24.10 / 25.x
- Пакеты: `curl`, `unzip`, `ca-bundle`, `kmod-tun`

## Установка

### Через SDK (как в CI)

```bash
tar --zstd -xf openwrt-sdk-*.tar.zst
cd openwrt-sdk-*
./scripts/feeds update -a
./scripts/feeds install -a
cp -r /path/to/luci-app-csqtt package/luci-app-csqtt
make menuconfig   # LuCI → Applications → luci-app-csqtt
make package/luci-app-csqtt/compile V=s
```

Готовый `.ipk` появится в `bin/packages/*/base/luci-app-csqtt_*.ipk`.

### На роутере

```
opkg update
opkg install luci-app-csqtt_*.ipk
/etc/init.d/rpcd restart
/etc/init.d/uhttpd restart
```

Затем LuCI → **Services → CSQTT**.

## Лицензия

PolyForm Noncommercial License 1.0.0

