# Сборка LaLune

Единый скрипт `build.py` в корне проекта собирает и упаковывает всё.

## Интерактивный режим

```
python build.py
```

Скрипт спросит, под какую платформу собирать:

```
============================================
   LaLune build
============================================

  Под какую платформу собрать?

    1) Windows
    2) Linux

  Выбор [1/2]:
```

## CI-режим

```
python build.py --ci --target windows
python build.py --ci --target linux
```

Без вопросов, сразу собирает указанную платформу.

## Что делает

1. **Собирает Backend** — `cargo build --release` в `Backend/Desktop/`
2. **Собирает Installer** (только Windows) — `cargo build --release` в `Installer/launcher/`
3. **Копирует `Assets/` → `Frontend/assets/`** — Flutter не умеет брать ассеты снаружи
4. **Собирает Frontend** — `flutter build windows --release` или `flutter build linux --release`
5. **Переименовывает бинарник** `lalune`/`lalune.exe` → `LaLune`/`LaLune.exe`
6. **Упаковывает в `Output/`**:

| Файл ↕▾ | Что внутри ↕▾ |
|---|---|
| −`LaLune-Windows.zip` | Весь `Frontend/build/windows/x64/runner/Release/` |
| −`Backend-Windows.zip` | Один файл `LaLuneManager.exe` (Rust-бэкенд) |
| −`Installer-Windows.zip` | Один файл `LaLune-Installer.exe` |
| −`LaLune-Linux.zip` | Весь `Frontend/build/linux/x64/release/bundle/` |
| −`Backend-Linux.zip` | Один файл `LaLuneManager` |
⚙

7. **Чистит**:

- `flutter clean` в `Frontend/`
- `cargo clean` в `Backend/Desktop/`
- `cargo clean` в `Installer/launcher/` (если собирали)
- удаляет временную `Frontend/assets/`

## Формат вывода

```
[RUNNING] cargo build --release (Backend/Desktop)
[OK] cargo build --release (Backend/Desktop)  (42.3s)
[INFO] backend binary: /path/Backend/Desktop/target/release/lalune-backend
[RUNNING] cargo build --release (Installer/launcher)
[OK] cargo build --release (Installer/launcher)  (18.7s)
[INFO] installer exe: /path/Installer/launcher/target/release/LaLune-Installer.exe
[RUNNING] flutter pub get
[OK] flutter pub get  (3.1s)
[RUNNING] flutter build windows --release
[OK] flutter build windows --release  (89.4s)

[INFO] packaging…
[INFO] packaging LaLune-Windows.zip…
[OK] LaLune-Windows.zip  (12345 KB)
[INFO] packaging Backend-Windows.zip…
[OK] Backend-Windows.zip  (2345 KB)
[INFO] packaging Installer-Windows.zip…
[OK] Installer-Windows.zip  (3456 KB)

[OK] build complete: /path/Output
[INFO]   LaLune-Windows.zip  (12345 KB)
[INFO]   Backend-Windows.zip  (2345 KB)
[INFO]   Installer-Windows.zip  (3456 KB)

[INFO] cleaning build artifacts…
[RUNNING] flutter clean (Frontend)
[OK] flutter clean (Frontend)  (2.5s)
[RUNNING] cargo clean (Backend/Desktop)
[OK] cargo clean (Backend/Desktop)  (0.3s)
[RUNNING] cargo clean (Installer/launcher)
[OK] cargo clean (Installer/launcher)  (0.2s)
[OK] removed Frontend/assets/ (temporary copy)

[OK] done.
```

## Флаги

| Флаг ↕▾ | Описание ↕▾ |
|---|---|
| −`--ci` | CI-режим, без вопросов |
| −`--target {windows,linux}` | Целевая платформа |
| −`--no-clean` | Не чистить build-артефакты после сборки |
⚙

## Требования

- **Python 3.8+**
- **Flutter** в `PATH`
- **Rust** (`cargo`) в `PATH`
- **Windows-таргет** — только на Windows-хосте (для сборки нативных exe)

## Использование в GitHub Actions

```
- name: Build Windows
  run: python build.py --ci --target windows

- name: Build Linux
  run: python build.py --ci --target linux

- name: Upload artifacts
  uses: actions/upload-artifact@v4
  with:
    name: LaLune-Windows
    path: Output/*.zip
```