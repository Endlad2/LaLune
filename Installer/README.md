# Installer

Три компонента:

| Файл ↕▾ | Назначение ↕▾ |
|---|---|
| −`install.ps1` | Установщик для Windows (PowerShell) |
| −`install.sh` | Установщик для Linux (bash) |
| −`launcher/` | Rust GUI-инсталлятор для Windows (опционально) |
⚙

## install.ps1 — Windows

```
# Скачивает всё из интернета:
.\install.ps1

# Использует уже скачанное в %TEMP%\.la-lune_downloader\:
.\install.ps1 -ci
```

### Что делает

1. Создаёт `%APPDATA%\.la-lune\`
2. Скачивает:

- `LaLune-Windows.zip` → распаковывает в `%APPDATA%\.la-lune\app\`
- `Backend-Windows.zip` → распаковывает в `%APPDATA%\.la-lune\`
- `client-windows-x86_64.exe` → кладёт в `%APPDATA%\.la-lune\`
- `LATEST` → кладёт в `%APPDATA%\.la-lune\`
- `icon.ico` → кладёт в `%APPDATA%\.la-lune\icon.ico`
- `wintun-0.14.1.zip` → берёт из него `wintun\bin\amd64\wintun.dll` → кладёт в `%APPDATA%\.la-lune\`
3. Создаёт ярлыки:

- на рабочем столе
- в меню Пуск
- ведут на `%APPDATA%\.la-lune\app\LaLune.exe`
- иконка — `%APPDATA%\.la-lune\icon.ico`
4. Чистит временные файлы
5. Выходит

### Флаг `-ci`

Если указан — **ничего не скачивает**. Предполагает, что все файлы уже лежат в `%TEMP%\.la-lune_downloader\`:

```
%TEMP%\.la-lune_downloader\
├── LaLune-Windows.zip
├── Backend-Windows.zip
├── client-windows-x86_64.exe
├── LATEST
├── icon.ico
└── wintun-0.14.1.zip
```

## install.sh — Linux

```
# Скачивает всё из интернета:
./install.sh

# Использует уже скачанное в /tmp/.la-lune_downloader/:
./install.sh --ci
```

### Что делает

1. Создаёт `~/.la-lune/`
2. Скачивает:

- `LaLune-Linux.zip` → распаковывает в `~/.la-lune/app/`
- `Backend-Linux.zip` → распаковывает в `~/.la-lune/`
- `client-linux-x86_64` (или `client-linux-i686` для 32-bit) → кладёт в `~/.la-lune/`
- `LATEST` → кладёт в `~/.la-lune/`
- `icon.ico` → кладёт в `~/.la-lune/icon.ico`
3. Создаёт:

- `.desktop` файл в `~/.local/share/applications/lalune.desktop`
- симлинк `~/.local/bin/lalune` → `~/.la-lune/app/LaLune`
4. Чистит временные файлы
5. Выходит

## launcher (Rust, только Windows)

GUI-обёртка, встраиваемая в `.exe`. При сборке скачивает всё нужное
и пакует внутрь бинарника. При запуске показывает окно с двумя кнопками:

- **Установить** — распаковывает всё в `%TEMP%\.la-lune_downloader\` и
запускает `install.ps1 -ci`
- **Выйти** — закрывает приложение

### Сборка

```
cd Installer\launcher
cargo build --release
```

Результат: `Installer\launcher\target\release\LaLune-Installer.exe`.

### Что внутри

Все файлы (`LaLune-Windows.zip`, `Backend-Windows.zip`, `client-windows-x86_64.exe`,
`LATEST`, `icon.ico`, `wintun-0.14.1.zip`, `install.ps1`) встроены через
`include_bytes!` (архивы) и `include_str!` (скрипт).

`build.rs` скачивает их во время `cargo build`.