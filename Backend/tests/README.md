# Проверка Linux TUN

Проверки API и настоящего Linux TUN запускаются в отдельных сетевых и mount namespaces. Ядро CSQTT заменяется локальным UDP-эхо-процессом: VK, внешняя сеть и пароли не нужны. Маршруты и DNS хоста не меняются.

Нужны Linux, root, `/dev/net/tun`, Python 3, `unshare`, `mount` и полный `iproute2`.

Из корня репозитория:

```sh
cargo test --manifest-path Backend/Desktop/Cargo.toml
cargo test --manifest-path Backend/OpenWRT/Cargo.toml
cargo build --manifest-path Backend/Desktop/Cargo.toml
cargo build --manifest-path Backend/OpenWRT/Cargo.toml
sudo python3 Backend/tests/linux_tun.py Backend/Desktop/target/debug/lalune-backend
sudo python3 Backend/tests/linux_tun.py Backend/OpenWRT/target/debug/lalune-openwrt-backend
sudo python3 Backend/tests/linux_tun.py Backend/Desktop/target/debug/lalune-backend --case paperflux_compat
sudo python3 Backend/tests/linux_tun.py Backend/Desktop/target/debug/lalune-backend --case csqttr_compat
```

Если задан `CARGO_TARGET_DIR`, укажите соответствующие пути к бинарникам. Каждая из 13 основных проверок имеет отдельный namespace и ограничение времени. Дополнительные Desktop-проверки подтверждают сохранение UID, HOME, рабочего каталога и прежнего поведения маршрутов для других протоколов; работу самих PaperFlux/CSQTTR они не проверяют.

Проверяются обычный default route, обход TUN транспортом CSQTT, доступ к LAN, ответ на одиночный пакет, отключение без трафика, отмена подключения, откат после ошибки маршрутов/DNS, сохранение внешнего изменения DNS, выход ядра, переподключение, занятая системная группа, таблица маршрутов с текстовым именем, отказ запуска без CAP_KILL и сохранение работающего VPN при неверном configId. Для проверки CAP_KILL нужна команда `setpriv` из util-linux.

## Требования при запуске CSQTT

Linux-бэкенду нужны root, TUN и `iproute2` с `ip rule uidrange` (на OpenWrt — `ip-full`, `kmod-tun` и поддержка policy routing ядром). В ограниченном systemd-сервисе нужны также `CAP_NET_ADMIN`, `CAP_SETUID`, `CAP_SETGID`, `CAP_CHOWN`, `CAP_DAC_OVERRIDE`, `CAP_KILL`, доступное для исполнения временное хранилище и право записи в `/etc/resolv.conf`.

CSQTT запускается под отдельными свободными UID/GID из диапазона 61062–62061, без создания системной учётной записи. Бинарник и входные файлы копируются во временный каталог. Транспорт этого UID использует `main`; остальные IPv4-пакеты без более точного маршрута в `main` попадают в TUN через таблицу 10620 и правила 10620–10622. Занятые таблица или приоритеты приводят к отказу подключения с откатом, чужие правила не удаляются. Основной default route сохраняется.

При отключении и ошибках удаляются добавленные маршруты, закрывается TUN, возвращается исходный DNS. Более позднее изменение `resolv.conf` другой службой сохраняется. Это IPv4-маршрутизация: защита от утечек IPv6 и полноценный kill switch здесь не реализованы. Трафик LAN с конкретными маршрутами остаётся в LAN.

Для раздачи VPN устройствам за роутером дополнительно требуются настроенные forwarding и firewall OpenWrt. Эти проверки не заменяют испытание на физическом ARM-роутере.

## Windows

```powershell
cargo test --manifest-path Backend/Desktop/Cargo.toml --locked
cargo build --manifest-path Backend/Desktop/Cargo.toml --release --locked
```

Два Windows-теста проверяют отмену watchdog, повторную остановку, запуск локального процесса PowerShell, чтение обоих потоков логов и завершение дочернего процесса. Они не создают Wintun-адаптер и не вызывают настройку маршрутов или DNS. Проверять настоящий VPN на Windows следует в отдельной тестовой системе.
