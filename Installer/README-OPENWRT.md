# openwrt.sh — установщик LaLune для OpenWRT

Установщик поддерживает ARM64 (`armsr/armv8`) и `ramips/mt7621`
(`mipsel_24kc`). Он скачивает один backend-бинарник для нужной архитектуры.
Внутри обоих backend уже встроены **CSQTT**, **CSQTTR** и **CSQTT 2.1.9**.

## Установка

```sh
wget -O - https://raw.githubusercontent.com/Endlad2/LaLune/main/Installer/openwrt.sh | sh
```

или:

```sh
curl -fsSL https://raw.githubusercontent.com/Endlad2/LaLune/main/Installer/openwrt.sh | sh
```

Флаги:

```sh
sh openwrt.sh --force
sh openwrt.sh --stop
sh openwrt.sh --status
```

## Что делает

- создаёт `~/.la-lune/`;
- выбирает `lalune-openwrt-backend` либо `lalune-openwrt-backend-ramips`;
- проверяет/ставит `ip-full`, `kmod-tun`, `iptables-nft`/`iptables` и `nohup`;
- скачивает backend и делает его executable;
- останавливает предыдущий процесс, запускает новый через `nohup`;
- пишет PID в `~/.la-lune/backend.pid`, лог — в
  `~/.la-lune/LaLuneManager.log`.

Отдельные core-файлы не скачиваются.

## VPN routing

При подключении backend создаёт `lalune0`, маркирует основной IPv4-трафик
через iptables и policy-routes его в отдельную таблицу через TUN. Транспорт
самого core исключается по отдельному UID, чтобы не возникала рекурсия VPN.

## Проверка

```sh
curl http://127.0.0.1:1062/ping
curl http://127.0.0.1:1062/core/protocols
ip link show lalune0            # когда VPN подключён
ip -4 rule show                 # policy rules LaLune
iptables -t mangle -S           # MARK rules LaLune
```

Панель доступна в доверенной LAN по `http://<IP роутера>:1062/panel`.
