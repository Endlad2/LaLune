#Requires -Version 5.1
<#
.SYNOPSIS
    LaLune installer для Windows.

.DESCRIPTION
    Скачивает LaLune client, backend, ядро CSQTT, LATEST, icon.ico и wintun.dll,
    распаковывает всё в %APPDATA%\.la-lune\, создаёт ярлыки на рабочем столе
    и в меню Пуск.

.PARAMETER ci
    Если указан — ничего не скачивается. Предполагается, что все нужные
    файлы уже лежат в %TEMP%\.la-lune_downloader\:
        LaLune-Windows.zip
        Backend-Windows.zip
        client-windows-x86_64.exe
        LATEST
        icon.ico
        wintun.zip

.EXAMPLE
    .\install.ps1
    .\install.ps1 -ci
#>

[CmdletBinding()]
param(
    [switch]$ci
)

$ErrorActionPreference = 'Stop'

# ============================================================
#  Константы
# ============================================================

$REPO_LALUNE = 'Endlad2/LaLune'
$REPO_CORE   = 'Endlad2/csqtt-core'

$URL_LALUNE_ZIP  = "https://github.com/$REPO_LALUNE/releases/latest/download/LaLune-Windows.zip"
$URL_BACKEND_ZIP = "https://github.com/$REPO_LALUNE/releases/latest/download/Backend-Windows.zip"
$URL_CORE_EXE    = "https://github.com/$REPO_CORE/releases/latest/download/client-windows-x86_64.exe"
$URL_LATEST      = "https://raw.githubusercontent.com/$REPO_CORE/refs/heads/main/LATEST"
$URL_ICON        = "https://raw.githubusercontent.com/$REPO_LALUNE/refs/heads/main/icon.ico"
$URL_WINTUN_ZIP  = "https://endlad2.github.io/wintun.zip"

$APPDATA_DIR  = Join-Path $env:APPDATA '.la-lune'
$APP_DIR      = Join-Path $APPDATA_DIR 'app'
$TEMP_DIR     = Join-Path $env:TEMP '.la-lune_downloader'
$LAUNCHER_EXE = Join-Path $APP_DIR 'LaLune.exe'
$ICON_PATH    = Join-Path $APPDATA_DIR 'icon.ico'

# ============================================================
#  Логирование
# ============================================================

function Write-Step  { param($m) Write-Host "[*] $m"  -ForegroundColor Cyan }
function Write-Ok    { param($m) Write-Host "[+] $m"  -ForegroundColor Green }
function Write-Warn  { param($m) Write-Host "[!] $m"  -ForegroundColor Yellow }
function Write-Fail  { param($m) Write-Host "[-] $m"  -ForegroundColor Red }

# ============================================================
#  Скачивание
# ============================================================

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Download-File {
    param(
        [Parameter(Mandatory=$true)][string]$Url,
        [Parameter(Mandatory=$true)][string]$Dest
    )

    $dir = Split-Path -Parent $Dest
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }

    if (Test-Path -LiteralPath $Dest) {
        Write-Host "    already present: $([System.IO.Path]::GetFileName($Dest))" -ForegroundColor DarkGray
        return
    }

    Write-Host "    downloading: $Url" -ForegroundColor DarkGray

    $tmp = "$Dest.part"
    try {
        Invoke-WebRequest -Uri $Url -OutFile $tmp -UseBasicParsing -TimeoutSec 120
        Move-Item -LiteralPath $tmp -Destination $Dest -Force
    } catch {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
        throw "Не удалось скачать $Url : $($_.Exception.Message)"
    }
}

# ============================================================
#  Извлечение wintun.dll из архива
# ============================================================

function Extract-WintunDll {
    param(
        [Parameter(Mandatory=$true)][string]$ZipPath,
        [Parameter(Mandatory=$true)][string]$DestDir
    )

    Write-Step "Извлекаю wintun.dll из $([System.IO.Path]::GetFileName($ZipPath))"

    Add-Type -AssemblyName System.IO.Compression.FileSystem

    $zip = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        # Ищем запись 'wintun\bin\amd64\wintun.dll' (в разных версиях zip
        # путь может быть с прямыми или обратными слэшами).
        $entry = $zip.Entries | Where-Object {
            $_.FullName -match '[\\/]amd64[\\/]wintun\.dll$' -and $_.Length -gt 0
        } | Select-Object -First 1

        if (-not $entry) {
            # Fallback: любую wintun.dll, предпочитая amd64.
            $entry = $zip.Entries | Where-Object {
                $_.FullName -match 'wintun\.dll$' -and $_.FullName -match 'amd64'
            } | Select-Object -First 1
        }
        if (-not $entry) {
            $entry = $zip.Entries | Where-Object {
                $_.FullName -match 'wintun\.dll$'
            } | Select-Object -First 1
        }

        if (-not $entry) {
            throw "wintun.dll не найден внутри $ZipPath"
        }

        $dest = Join-Path $DestDir 'wintun.dll'
        if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Force }

        [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $dest, $true)
        Write-Ok "wintun.dll → $dest"
    } finally {
        $zip.Dispose()
    }
}

# ============================================================
#  Распаковка zip в каталог (перезаписывая)
# ============================================================

function Expand-ZipOverwrite {
    param(
        [Parameter(Mandatory=$true)][string]$ZipPath,
        [Parameter(Mandatory=$true)][string]$DestDir
    )

    if (-not (Test-Path -LiteralPath $DestDir)) {
        New-Item -ItemType Directory -Force -Path $DestDir | Out-Null
    }

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        foreach ($entry in $zip.Entries) {
            $name = $entry.FullName -replace '/', '\'
            $name = $name.TrimStart('\')

            if ([string]::IsNullOrWhiteSpace($name)) { continue }
            if ($name.EndsWith('\') -or $entry.Length -eq 0 -and $name.EndsWith('/')) {
                # директория
                $d = Join-Path $DestDir $name.TrimEnd('\')
                if (-not (Test-Path -LiteralPath $d)) {
                    New-Item -ItemType Directory -Force -Path $d | Out-Null
                }
                continue
            }

            $target = Join-Path $DestDir $name
            $parent = Split-Path -Parent $target
            if ($parent -and -not (Test-Path -LiteralPath $parent)) {
                New-Item -ItemType Directory -Force -Path $parent | Out-Null
            }
            if (Test-Path -LiteralPath $target) {
                Remove-Item -LiteralPath $target -Force
            }
            [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $target, $true)
        }
    } finally {
        $zip.Dispose()
    }
}

# ============================================================
#  Ярлыки
# ============================================================

function New-Shortcut {
    param(
        [Parameter(Mandatory=$true)][string]$LinkPath,
        [Parameter(Mandatory=$true)][string]$TargetPath,
        [Parameter(Mandatory=$true)][string]$IconPath,
        [string]$WorkingDir = '',
        [string]$Description = 'LaLune VPN Client'
    )

    $dir = Split-Path -Parent $LinkPath
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }

    $shell = New-Object -ComObject WScript.Shell
    $sc = $shell.CreateShortcut($LinkPath)
    $sc.TargetPath       = $TargetPath
    $sc.IconLocation     = "$IconPath,0"
    $sc.Description      = $Description
    if ($WorkingDir) {
        $sc.WorkingDirectory = $WorkingDir
    }
    $sc.Save()
    [System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell) | Out-Null
}

function Create-AllShortcuts {
    param(
        [Parameter(Mandatory=$true)][string]$TargetExe,
        [Parameter(Mandatory=$true)][string]$IconPath
    )

    $working = Split-Path -Parent $TargetExe

    # Рабочий стол
    $desktop = [Environment]::GetFolderPath('Desktop')
    $desktopLink = Join-Path $desktop 'LaLune.lnk'
    New-Shortcut -LinkPath $desktopLink -TargetPath $TargetExe `
                 -IconPath $IconPath -WorkingDir $working
    Write-Ok "Ярлык на рабочем столе: $desktopLink"

    # Меню Пуск (для текущего пользователя)
    $startMenu = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'
    $startLink = Join-Path $startMenu 'LaLune.lnk'
    New-Shortcut -LinkPath $startLink -TargetPath $TargetExe `
                 -IconPath $IconPath -WorkingDir $working
    Write-Ok "Ярлык в меню Пуск: $startLink"
}

# ============================================================
#  Main
# ============================================================

function Main {
    Write-Host ''
    Write-Host '========================================' -ForegroundColor Green
    Write-Host '     LaLune Installer (Windows)        ' -ForegroundColor Green
    Write-Host '========================================' -ForegroundColor Green
    Write-Host ''

    if ($ci) {
        Write-Step "CI-режим: файлы берутся из $TEMP_DIR"
        if (-not (Test-Path -LiteralPath $TEMP_DIR)) {
            throw "Каталог $TEMP_DIR не найден — перезапустите без -ci"
        }
    } else {
        Write-Step 'Подготовка временного каталога...'
        if (-not (Test-Path -LiteralPath $TEMP_DIR)) {
            New-Item -ItemType Directory -Force -Path $TEMP_DIR | Out-Null
        }
    }

    # --- Скачивание (или проверка наличия в CI-режиме) ---
    Write-Step 'Получаю файлы...'

    $laLuneZip  = Join-Path $TEMP_DIR 'LaLune-Windows.zip'
    $backendZip = Join-Path $TEMP_DIR 'Backend-Windows.zip'
    $coreExe    = Join-Path $TEMP_DIR 'client-windows-x86_64.exe'
    $latestFile = Join-Path $TEMP_DIR 'LATEST'
    $iconFile   = Join-Path $TEMP_DIR 'icon.ico'
    $wintunZip  = Join-Path $TEMP_DIR 'wintun.zip'
    $ps1File    = Join-Path $TEMP_DIR 'install.ps1'

    if ($ci) {
        $missing = @()
        foreach ($f in @($laLuneZip, $backendZip, $coreExe, $latestFile, $iconFile, $wintunZip)) {
            if (-not (Test-Path -LiteralPath $f)) { $missing += $f }
        }
        if ($missing.Count -gt 0) {
            throw ("В $TEMP_DIR не хватает файлов:`n  " + ($missing -join "`n  "))
        }
        Write-Ok 'Все файлы найдены в CI-каталоге'
    } else {
        Download-File -Url $URL_LALUNE_ZIP  -Dest $laLuneZip
        Download-File -Url $URL_BACKEND_ZIP -Dest $backendZip
        Download-File -Url $URL_CORE_EXE    -Dest $coreExe
        Download-File -Url $URL_LATEST      -Dest $latestFile
        Download-File -Url $URL_ICON        -Dest $iconFile
        Download-File -Url $URL_WINTUN_ZIP  -Dest $wintunZip
        Write-Ok 'Все файлы скачаны'
    }

    # --- Подготовка %APPDATA%\.la-lune\ ---
    Write-Step "Готовлю $APPDATA_DIR"
    if (-not (Test-Path -LiteralPath $APPDATA_DIR)) {
        New-Item -ItemType Directory -Force -Path $APPDATA_DIR | Out-Null
    }
    if (-not (Test-Path -LiteralPath $APP_DIR)) {
        New-Item -ItemType Directory -Force -Path $APP_DIR | Out-Null
    }
    Write-Ok "Каталоги готовы"

    # --- Иконка ---
    Write-Step 'Копирую иконку'
    $iconDest = Join-Path $APPDATA_DIR 'icon.ico'
    Copy-Item -LiteralPath $iconFile -Destination $iconDest -Force
    Write-Ok "icon.ico → $iconDest"

    # --- LaLune (UI) ---
    Write-Step 'Распаковываю LaLune-Windows.zip в app\'
    Expand-ZipOverwrite -ZipPath $laLuneZip -DestDir $APP_DIR
    if (-not (Test-Path -LiteralPath $LAUNCHER_EXE)) {
        throw "После распаковки LaLune.exe не найден в $APP_DIR"
    }
    Write-Ok "LaLune.exe → $LAUNCHER_EXE"

    # --- Backend ---
    Write-Step 'Распаковываю Backend-Windows.zip в .la-lune\'
    Expand-ZipOverwrite -ZipPath $backendZip -DestDir $APPDATA_DIR
    Write-Ok 'Backend распакован'

    # --- Ядро CSQTT ---
    Write-Step 'Кладу ядро CSQTT'
    $coreDest = Join-Path $APPDATA_DIR 'client-windows-x86_64.exe'
    Copy-Item -LiteralPath $coreExe -Destination $coreDest -Force
    Write-Ok "client-windows-x86_64.exe → $coreDest"

    # --- LATEST ---
    Write-Step 'Кладу LATEST'
    $latestDest = Join-Path $APPDATA_DIR 'LATEST'
    Copy-Item -LiteralPath $latestFile -Destination $latestDest -Force
    Write-Ok "LATEST → $latestDest"

    # --- wintun.dll ---
    Extract-WintunDll -ZipPath $wintunZip -DestDir $APPDATA_DIR

    # --- Ярлыки ---
    Write-Step 'Создаю ярлыки'
    Create-AllShortcuts -TargetExe $LAUNCHER_EXE -IconPath $iconDest

    # --- Очистка временных файлов ---
    Write-Step 'Очищаю временные файлы'
    try {
        Get-ChildItem -LiteralPath $TEMP_DIR -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -ne 'install.ps1' } |
            Remove-Item -Force -ErrorAction SilentlyContinue
    } catch { }

    Write-Host ''
    Write-Host '========================================' -ForegroundColor Green
    Write-Host '  LaLune установлен!' -ForegroundColor Green
    Write-Host '========================================' -ForegroundColor Green
    Write-Host ''
    Write-Host "  Приложение: $LAUNCHER_EXE" -ForegroundColor White
    Write-Host "  Ярлыки:     рабочий стол + меню Пуск" -ForegroundColor White
    Write-Host ''
}

try {
    Main
    exit 0
} catch {
    Write-Fail $_.Exception.Message
    Write-Host ''
    Write-Host 'Установка прервана.' -ForegroundColor Red
    exit 1
}
