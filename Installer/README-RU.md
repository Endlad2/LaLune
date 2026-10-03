# LaLune Installer — подробное описание

## Что тут лежит

| Файл/папка ↕▾ | Что делает ↕▾ |
|---|---|
| −`install.ps1` | Установщик для Windows (PowerShell) |
| −`install.sh` | Установщик для Linux (bash) |
| −`launcher/` | Rust GUI-инсталлятор для Windows |
| −`launcher/build.rs` | Скачивает все ресурсы во время `cargo build` |
| −`launcher/src/main.rs` | GUI: «Установить» / «Выйти» |
⚙

## Как работает `install.ps1`

### Обычный режим

```
.\install.ps1
```

1. Скачивает во `%TEMP%\.la-lune_downloader\`:

- `LaLune-Windows.zip` (клиент)
- `Backend-Windows.zip` (Rust backend)
- `client-windows-x86_64.exe` (ядро CSQTT)
- `LATEST` (версия ядра)
- `icon.ico` (иконка)
- `wintun-0.14.1.zip` (драйвер TUN)
2. Распаковывает `LaLune-Windows.zip` → `%APPDATA%\.la-lune\app\`
3. Распаковывает `Backend-Windows.zip` → `%APPDATA%\.la-lune\`
4. Кладёт ядро, `LATEST`, `icon.ico` → `%APPDATA%\.la-lune\`
5. Извлекает `wintun\bin\amd64\wintun.dll` из zip → `%APPDATA%\.la-lune\`
6. Создаёт ярлыки на рабочем столе и в меню Пуск
7. Чистит временные файлы

### CI-режим

```
.\install.ps1 -ci
```

То же самое, но **шаг 1 пропускается** — все файлы должны уже лежать
в `%TEMP%\.la-lune_downloader\`.

## Как работает `install.sh`

### Обычный режим

```
./install.sh
```

1. Определяет архитектуру (`x86_64` / `i686` / `aarch64` / `armv7`)
2. Скачивает во `/tmp/.la-lune_downloader\`:

- `LaLune-Linux.zip`
- `Backend-Linux.zip`
- `client-linux-<arch>`
- `LATEST`
- `icon.ico`
3. Распаковывает `LaLune-Linux.zip` → `~/.la-lune/app/`
4. Распаковывает `Backend-Linux.zip` → `~/.la-lune/`
5. Кладёт ядро, `LATEST`, `icon.ico` → `~/.la-lune/`
6. Создаёт:

- `~/.local/share/applications/lalune.desktop`
- симлинк `~/.local/bin/lalune`
7. Чистит временные файлы

### CI-режим

```
./install.sh --ci
```

То же самое, но скачивание пропускается.

## Как работает `launcher/`

### При сборке

`build.rs` скачивает:

- `LaLune-Windows.zip`
- `Backend-Windows.zip`
- `client-windows-x86_64.exe`
- `LATEST`
- `icon.ico`
- `wintun-0.14.1.zip` → извлекает `wintun.dll`

Всё складывается в `OUT_DIR` (внутри `target/`). Плюс копируется
`../install.ps1`.

### При запуске `.exe`

Показывается окно 420×240 с двумя кнопками.

- **Выйти** — просто закрывает приложение.
- **Установить**:

1. Распаковывает все ресурсы в `%TEMP%\.la-lune_downloader\`
(собрав `wintun-0.14.1.zip` на лету из `wintun.dll`).
2. Запускает `powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1 -ci`.
3. Ждёт завершения.
4. Показывает «Установка завершена» и закрывается.

### Сборка

```
cd Installer\launcher
cargo build --release
```

Результат: `target\release\LaLune-Installer.exe`.

## Требования

- **Windows:** PowerShell 5.1+ (встроен в Windows 10/11).
- **Linux:** `curl` или `wget`, `unzip`.
- **Сборка launcher:** Rust 1.75+.

## Ссылки на релизы

- Клиент: https://github.com/Endlad2/LaLune/releases/latest
- Ядро:   https://github.com/Endlad2/csqtt-core/releases/latest
- Wintun: https://www.wintun.net/