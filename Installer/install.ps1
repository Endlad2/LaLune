#Requires -Version 5.1
<#
.SYNOPSIS
    LaLune installer для Windows (CSQTT + CSQTTR + PaperFlux).
#>

[CmdletBinding()]
param(
    [switch]$ci
)

$ErrorActionPreference = 'Stop'

# ============================================================
#  Константы
# ============================================================

$REPO_LALUNE   = 'Endlad2/LaLune'
$REPO_CSQTT    = 'Endlad2/csqtt-core'
$REPO_PAPERFLUX = 'Endlad2/PaperFlux-core'
$REPO_CSQTTR = 'Endlad2/csqttr-core'

$URL_LALUNE_ZIP     = "https://github.com/$REPO_LALUNE/releases/latest/download/LaLune-Windows.zip"
$URL_BACKEND_ZIP    = "https://github.com/$REPO_LALUNE/releases/latest/download/Backend-Windows.zip"
$URL_CSQTT_EXE      = "https://github.com/$REPO_CSQTT/releases/latest/download/client-windows-x86_64.exe"
$URL_CSQTT_219_EXE  = "https://github.com/$REPO_CSQTT/releases/download/2026.09.17.17.36/client-windows-x86_64.exe"
$URL_PAPERFLUX_EXE  = "https://github.com/$REPO_PAPERFLUX/releases/latest/download/paperflux-windows-amd64.exe"
$URL_CSQTTR_EXE     = "https://github.com/$REPO_CSQTTR/releases/latest/download/client-windows-x86_64.exe"
$URL_CSQTTR_LATEST  = "https://raw.githubusercontent.com/$REPO_CSQTTR/refs/heads/release-2.5.2/LATEST"
$URL_CSQTT_LATEST   = "https://raw.githubusercontent.com/$REPO_CSQTT/refs/heads/main/LATEST"
$URL_PF_LATEST      = "https://raw.githubusercontent.com/$REPO_PAPERFLUX/refs/heads/main/LATEST"
$URL_ICON           = "https://raw.githubusercontent.com/$REPO_LALUNE/refs/heads/main/icon.ico"
$URL_WINTUN_ZIP     = "https://endlad2.github.io/wintun.zip"

$APPDATA_DIR  = Join-Path $env:APPDATA '.la-lune'
$APP_DIR      = Join-Path $APPDATA_DIR 'app'
$TEMP_DIR     = Join-Path $env:TEMP '.la-lune_downloader'
$LAUNCHER_EXE = Join-Path $APP_DIR 'LaLune.exe'
$ICON_PATH    = Join-Path $APPDATA_DIR 'icon.ico'

function Write-Step  { param($m) Write-Host "[*] $m"  -ForegroundColor Cyan }
function Write-Ok    { param($m) Write-Host "[+] $m"  -ForegroundColor Green }
function Write-Warn  { param($m) Write-Host "[!] $m"  -ForegroundColor Yellow }
function Write-Fail  { param($m) Write-Host "[-] $m"  -ForegroundColor Red }

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

function Extract-WintunDll {
    param(
        [Parameter(Mandatory=$true)][string]$ZipPath,
        [Parameter(Mandatory=$true)][string]$DestDir
    )
    Write-Step "Извлекаю wintun.dll из $([System.IO.Path]::GetFileName($ZipPath))"
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        $entry = $zip.Entries | Where-Object {
            $_.FullName -match '[\\/]amd64[\\/]wintun\.dll$' -and $_.Length -gt 0
        } | Select-Object -First 1
        if (-not $entry) {
            $entry = $zip.Entries | Where-Object {
                $_.FullName -match 'wintun\.dll$' -and $_.FullName -match 'amd64'
            } | Select-Object -First 1
        }
        if (-not $entry) {
            $entry = $zip.Entries | Where-Object { $_.FullName -match 'wintun\.dll$' } | Select-Object -First 1
        }
        if (-not $entry) { throw "wintun.dll не найден внутри $ZipPath" }
        $dest = Join-Path $DestDir 'wintun.dll'
        if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Force }
        [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $dest, $true)
        Write-Ok "wintun.dll → $dest"
    } finally { $zip.Dispose() }
}

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
            if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Force }
            [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $target, $true)
        }
    } finally { $zip.Dispose() }
}

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
    if ($WorkingDir) { $sc.WorkingDirectory = $WorkingDir }
    $sc.Save()
    [System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell) | Out-Null
}

function Create-AllShortcuts {
    param(
        [Parameter(Mandatory=$true)][string]$TargetExe,
        [Parameter(Mandatory=$true)][string]$IconPath
    )
    $working = Split-Path -Parent $TargetExe
    $desktop = [Environment]::GetFolderPath('Desktop')
    $desktopLink = Join-Path $desktop 'LaLune.lnk'
    New-Shortcut -LinkPath $desktopLink -TargetPath $TargetExe -IconPath $IconPath -WorkingDir $working
    Write-Ok "Ярлык на рабочем столе: $desktopLink"

    $startMenu = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'
    $startLink = Join-Path $startMenu 'LaLune.lnk'
    New-Shortcut -LinkPath $startLink -TargetPath $TargetExe -IconPath $IconPath -WorkingDir $working
    Write-Ok "Ярлык в меню Пуск: $startLink"
}

function Main {
    Write-Host ''
    Write-Host '========================================' -ForegroundColor Green
    Write-Host '     LaLune Installer (Windows)        ' -ForegroundColor Green
    Write-Host '     CSQTT + PaperFlux                 ' -ForegroundColor Green
    Write-Host '========================================' -ForegroundColor Green
    Write-Host ''

    if (-not (Test-Path -LiteralPath $TEMP_DIR)) {
        New-Item -ItemType Directory -Force -Path $TEMP_DIR | Out-Null
    }

    Write-Step 'Получаю файлы...'

    $laLuneZip       = Join-Path $TEMP_DIR 'LaLune-Windows.zip'
    $backendZip      = Join-Path $TEMP_DIR 'Backend-Windows.zip'
    $csqttExe        = Join-Path $TEMP_DIR 'client-windows-x86_64.exe'
    $csqtt219Exe     = Join-Path $TEMP_DIR 'csqtt-219.exe'
    $csqtt219Latest  = Join-Path $TEMP_DIR 'LATEST.CSQTT-2.1.9'
    $paperfluxExe    = Join-Path $TEMP_DIR 'paperflux-windows-amd64.exe'
    $csqttrExe       = Join-Path $TEMP_DIR 'csqttr-windows-x86_64.exe'
    $csqttrLatest    = Join-Path $TEMP_DIR 'LATEST.CSQTTR'
    $csqttLatest     = Join-Path $TEMP_DIR 'LATEST.Csqtt'
    $pfLatest        = Join-Path $TEMP_DIR 'LATEST.PaperFlux'
    $iconFile        = Join-Path $TEMP_DIR 'icon.ico'
    $wintunZip       = Join-Path $TEMP_DIR 'wintun.zip'

    if ($ci) {
        if (-not (Test-Path -LiteralPath $csqttrExe)) {
            Download-File -Url $URL_CSQTTR_EXE -Dest $csqttrExe
        }
        if (-not (Test-Path -LiteralPath $csqttrLatest)) {
            Download-File -Url $URL_CSQTTR_LATEST -Dest $csqttrLatest
        }
        if (-not (Test-Path -LiteralPath $csqtt219Latest)) {
            Set-Content -LiteralPath $csqtt219Latest -Value '2026.09.17.17.36' -NoNewline -Encoding ascii
        }
        $missing = @()
        foreach ($f in @($laLuneZip, $backendZip, $csqttExe, $csqtt219Exe, $csqtt219Latest, $csqttrExe, $csqttrLatest, $paperfluxExe, $csqttLatest, $pfLatest, $iconFile, $wintunZip)) {
            if (-not (Test-Path -LiteralPath $f)) { $missing += $f }
        }
        if ($missing.Count -gt 0) {
            throw ("В $TEMP_DIR не хватает файлов:`n  " + ($missing -join "`n  "))
        }
        Write-Ok 'Все файлы найдены в CI-каталоге'
    } else {
        Download-File -Url $URL_LALUNE_ZIP    -Dest $laLuneZip
        Download-File -Url $URL_BACKEND_ZIP   -Dest $backendZip
        Download-File -Url $URL_CSQTT_EXE     -Dest $csqttExe
        Download-File -Url $URL_CSQTT_219_EXE -Dest $csqtt219Exe
        Set-Content -LiteralPath $csqtt219Latest -Value '2026.09.17.17.36' -NoNewline -Encoding ascii
        Download-File -Url $URL_PAPERFLUX_EXE -Dest $paperfluxExe
        Download-File -Url $URL_CSQTTR_EXE -Dest $csqttrExe
        Download-File -Url $URL_CSQTTR_LATEST -Dest $csqttrLatest
        Download-File -Url $URL_CSQTT_LATEST  -Dest $csqttLatest
        Download-File -Url $URL_PF_LATEST     -Dest $pfLatest
        Download-File -Url $URL_ICON          -Dest $iconFile
        Download-File -Url $URL_WINTUN_ZIP    -Dest $wintunZip
        Write-Ok 'Все файлы скачаны'
    }

    Write-Step "Готовлю $APPDATA_DIR"
    if (-not (Test-Path -LiteralPath $APPDATA_DIR)) {
        New-Item -ItemType Directory -Force -Path $APPDATA_DIR | Out-Null
    }
    if (-not (Test-Path -LiteralPath $APP_DIR)) {
        New-Item -ItemType Directory -Force -Path $APP_DIR | Out-Null
    }

    # Иконка
    Write-Step 'Копирую иконку'
    $iconDest = Join-Path $APPDATA_DIR 'icon.ico'
    Copy-Item -LiteralPath $iconFile -Destination $iconDest -Force

    # UI
    Write-Step 'Распаковываю LaLune-Windows.zip'
    Expand-ZipOverwrite -ZipPath $laLuneZip -DestDir $APP_DIR

    # Backend
    Write-Step 'Распаковываю Backend-Windows.zip'
    Expand-ZipOverwrite -ZipPath $backendZip -DestDir $APPDATA_DIR

    # CSQTT core
    Write-Step 'Кладу CSQTT core'
    Copy-Item -LiteralPath $csqttExe -Destination (Join-Path $APPDATA_DIR 'csqtt-core.exe') -Force
    Copy-Item -LiteralPath $csqtt219Exe -Destination (Join-Path $APPDATA_DIR 'csqtt-219.exe') -Force

    # CSQTTR core
    Copy-Item -LiteralPath $csqttrExe -Destination (Join-Path $APPDATA_DIR 'csqttr-core.exe') -Force

    # PaperFlux core
    if (Test-Path -LiteralPath $paperfluxExe) {
        Write-Step 'Кладу PaperFlux core'
        Copy-Item -LiteralPath $paperfluxExe -Destination (Join-Path $APPDATA_DIR 'paperflux-core.exe') -Force
    } else {
        Write-Warn 'PaperFlux core не скачан (CI без файла?)'
    }

    # LATEST-версии
    Write-Step 'Кладу LATEST-файлы'
    if (Test-Path -LiteralPath $csqttLatest) {
        Copy-Item -LiteralPath $csqttLatest -Destination (Join-Path $APPDATA_DIR 'LATEST.Csqtt') -Force
    }
    Copy-Item -LiteralPath $csqtt219Latest -Destination (Join-Path $APPDATA_DIR 'LATEST.CSQTT-2.1.9') -Force
    Copy-Item -LiteralPath $csqttrLatest -Destination (Join-Path $APPDATA_DIR 'LATEST.CSQTTR') -Force
    Copy-Item -LiteralPath $pfLatest -Destination (Join-Path $APPDATA_DIR 'LATEST.PaperFlux') -Force

    # wintun.dll
    Extract-WintunDll -ZipPath $wintunZip -DestDir $APPDATA_DIR

    # Ярлыки
    Write-Step 'Создаю ярлыки'
    Create-AllShortcuts -TargetExe $LAUNCHER_EXE -IconPath $iconDest

    Write-Host ''
    Write-Host '========================================' -ForegroundColor Green
    Write-Host '  LaLune установлен!' -ForegroundColor Green
    Write-Host '========================================' -ForegroundColor Green
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
