# owrt-client — LaLune для OpenWRT (без SDK)

Минималистичный Rust-клиент. Никаких `.ipk`, никакого SDK. Один статический бинарник.

## Как это работает

1. Кладёшь бинарник `owrt-client` на роутер (например, `/usr/bin/` или `/root/`).
2. Рядом с ним кладёшь файл `config` со ссылкой:
```

csqtt://connect?v=2&host=31.77.148.203&peer=46000&password=xxx&hashes=h1+h2+h3

```
3. Запускаешь:
```

./owrt-client

```

Бинарник:
- парсит ссылку
- скачивает ядро CSQTT в `/tmp/owrt-client/`
- запускает ядро в фоне (`setsid`, отвязка от терминала)
- пишет stdout/stderr ядра в `/tmp/owrt-client/core.log`
- **сам завершается**, ядро продолжает работать

## Команды

```

owrt-client          запустить ядро в фоне
owrt-client logs     показать лог ядра
owrt-client stop     остановить ядро
owrt-client status   показать статус
owrt-client help     справка

```

## Файлы

| Путь | Назначение |
|---|---|
| `<рядом>/owrt-client` | бинарник |
| `<рядом>/config` | ссылка csqtt:// |
| `/tmp/owrt-client/core.log` | лог ядра |
| `/tmp/owrt-client/core.pid` | PID ядра |
| `/tmp/owrt-client/settings.json` | настройки (обфускация, воркеры, deviceId) |
| `/tmp/owrt-client/client-linux-arm64` | скачанное ядро |

## Скачивание бинарника

Из GitHub Actions → **Build OpenWRT** → артефакт `LaLune-OpenWRT-RouteRich`.

Внутри:
- `owrt-client` — сам бинарник
- `config.example` — шаблон конфига
- `README.md` — эта инструкция

## Установка на роутер

```sh
# С компьютера
scp owrt-client root@192.168.1.1:/usr/bin/
scp config.example root@192.168.1.1:/usr/bin/config

# На роутере
ssh root@192.168.1.1
chmod +x /usr/bin/owrt-client

# Правим /usr/bin/config — вставляем свою csqtt:// ссылку
vi /usr/bin/config

# Запускаем
/usr/bin/owrt-client
```

## Сборка вручную

Если бинарник из CI не подходит — собери сам.

### Требования

- Rust 1.75+ (`rustup` с [https://rustup.rs](https://rustup.rs))
- Docker (для `cross`) — либо воспользуйся нативной кросс-сборкой, см. ниже

### Вариант 1: cross (рекомендуется)

```
cd OpenWRT
cargo install cross
cross build --release --target aarch64-unknown-linux-musl
```

Бинарник появится в `target/aarch64-unknown-linux-musl/release/owrt-client`.

### Вариант 2: без Docker

Установи toolchain и линкер:

```
rustup target add aarch64-unknown-linux-musl
sudo apt install gcc-aarch64-linux-gnu
```

Добавь в `~/.cargo/config.toml`:

```
[target.aarch64-unknown-linux-musl]
linker = "aarch64-linux-gnu-gcc"
```

Собирай:

```
cd OpenWRT
cargo build --release --target aarch64-unknown-linux-musl
```

## Автозапуск при загрузке роутера

Если хочешь, чтобы клиент стартовал автоматически, добавь в `/etc/rc.local` перед `exit 0`:

```
/usr/bin/owrt-client
```

Либо создай простой init-скрипт `/etc/init.d/owrt-client`:

```
#!/bin/sh /etc/rc.common
START=99
STOP=10

start() {
    /usr/bin/owrt-client
}

stop() {
    /usr/bin/owrt-client stop
}

restart() {
    stop
    sleep 1
    start
}
```

Затем:

```
chmod +x /etc/init.d/owrt-client
/etc/init.d/owrt-client enable
/etc/init.d/owrt-client start
```

## TODO

- □  
Демон, который поднимает `csqtt0` когда в логе ядра появляется
`[СТАТИСТИКА] Активных: N` с N > 0 (через `tun-rs`)
- □  
Автоопределение актуальной версии ядра через LATEST (сейчас версия в `CORE_VERSION`)
- □  
Автофетч обновления ядра

## Лицензия

PolyForm Noncommercial License 1.0.0.

