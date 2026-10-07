# Installer / launcher

Rust GUI-инсталлятор для Windows.

**Больше не использует `install.ps1`** — всё делает сам на чистом Rust.

## Как работает

### При сборке

`build.rs` скачивает в `OUT_DIR`:

- `LaLune-Windows.zip`
- `Backend-Windows.zip`
- `client-windows-x86_64.exe`
- `LATEST`
- `icon.ico`
- `wintun-0.14.1.zip` → извлекает `wintun.dll`

Всё встраивается в бинарник через `include_bytes!` (см. `src/installer.rs`).

### При запуске

1. Показывается окно с кнопками «Установить» / «Выйти».
2. **Установить** → в отдельном потоке вызывается `installer::run_install`:

- Создаёт `%APPDATA%\.la-lune\` и `%APPDATA%\.la-lune\app\`.
- Распаковывает `LaLune-Windows.zip` → `%APPDATA%\.la-lune\app\`.
- Ищет `LaLune.exe` в `app\` (в корне или на 1 уровень вглубь).
- Распаковывает `Backend-Windows.zip` → `%APPDATA%\.la-lune\`.
- Кладёт `client-windows-x86_64.exe`, `LATEST`, `icon.ico`,
`wintun.dll` в `%APPDATA%\.la-lune\`.
- Создаёт ярлыки через COM (`IShellLink` + `IPersistFile`):

- `%USERPROFILE%\Desktop\LaLune.lnk`
- `%APPDATA%\Microsoft\Windows\Start Menu\Programs\LaLune.lnk`
3. По завершении — MessageBox «Установка завершена» и выход.

## Сборка

```
cd Installer\launcher
cargo build --release
```

Результат: `target\release\LaLune-Installer.exe`.

## Зависимости

- `native-windows-gui` — GUI (WinAPI, без C++ toolchain).
- `zip` — распаковка встроенных архивов.
- `windows` — COM-обёртка для ярлыков (`IShellLink`, `IPersistFile`).
- `anyhow` — ошибки.
- `dirs` — пути (запасной вариант).

## Что удалено

- Копирование `install.ps1` в `OUT_DIR` — больше не нужно.
- Вызов `powershell -File install.ps1 -ci` — заменён на `installer::run_install`.
- Промежуточная распаковка в `%TEMP%\.la-lune_downloader\` — больше не нужна.