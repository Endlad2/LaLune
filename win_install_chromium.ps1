#!/usr/bin/env pwsh
<#
.SYNOPSIS
    One-command installer for LaLune Token Fetcher (Playwright-based).
.DESCRIPTION
    Downloads the latest LaLuneTokenFetcher_Windows.zip from GitHub releases,
    extracts it into a temp folder, loads Microsoft.Playwright.dll from memory
    (so the DLL is not locked), and invokes Playwright's Program.Main with
    the "install chromium" argument.
.NOTES
    Usage:  pwsh -File .\Install-LaLune.ps1
    Or:     .\Install-LaLune.ps1
#>

[CmdletBinding()]
param(
    # Optional: pass-through args to Playwright. Defaults to "install chromium".
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]] $PlaywrightArgs = @('install', 'chromium')
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'   # speed up Invoke-WebRequest

# ---------------------------------------------------------------------------
# 1. Prepare a per-run working directory in TEMP
# ---------------------------------------------------------------------------
$workDir = Join-Path $env:TEMP ("LaLuneTokenFetcher_" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $workDir -Force | Out-Null

$zipPath = Join-Path $workDir 'LaLuneTokenFetcher_Windows.zip'
$url     = 'https://github.com/Endlad2/LaLune/releases/latest/download/LaLuneTokenFetcher_Windows.zip'

Write-Host "[*] Working dir : $workDir"
Write-Host "[*] Downloading : $url"

# ---------------------------------------------------------------------------
# 2. Download the ZIP
# ---------------------------------------------------------------------------
try {
    Invoke-WebRequest -Uri $url -OutFile $zipPath -UseBasicParsing
}
catch {
    Write-Error "Failed to download LaLune archive: $($_.Exception.Message)"
    exit 1
}

if (-not (Test-Path $zipPath) -or (Get-Item $zipPath).Length -eq 0) {
    Write-Error "Downloaded archive is missing or empty."
    exit 1
}

# ---------------------------------------------------------------------------
# 3. Extract
# ---------------------------------------------------------------------------
$extractDir = Join-Path $workDir 'app'
Write-Host "[*] Extracting  : $extractDir"
try {
    Expand-Archive -Path $zipPath -DestinationPath $extractDir -Force
}
catch {
    Write-Error "Failed to extract archive: $($_.Exception.Message)"
    exit 1
}

# Remove the zip to keep things tidy
Remove-Item $zipPath -Force -ErrorAction SilentlyContinue

# ---------------------------------------------------------------------------
# 4. Locate Microsoft.Playwright.dll (may be in a nested folder)
# ---------------------------------------------------------------------------
$playwrightDll = Get-ChildItem -Path $extractDir -Recurse -Filter 'Microsoft.Playwright.dll' -File |
                 Select-Object -First 1

if (-not $playwrightDll) {
    Write-Error "Microsoft.Playwright.dll was not found inside the extracted archive."
    exit 1
}

$appRoot = $playwrightDll.Directory.FullName
Write-Host "[*] App root    : $appRoot"

# ---------------------------------------------------------------------------
# 5. Set up environment & load assembly from memory (no file lock)
# ---------------------------------------------------------------------------
$Env:PLAYWRIGHT_DRIVER_SEARCH_PATH = $appRoot

# Ensure the process can resolve the other managed deps that sit next to the DLL.
# This is required on modern .NET / PowerShell where AssemblyResolve is not automatic.
$resolver = [System.ResolveEventHandler]{
    param($sender, $e)

    try {
        $asmName = ([System.Reflection.AssemblyName]$e.Name).Name
        $candidate = Join-Path $appRoot ($asmName + '.dll')
        if (Test-Path $candidate) {
            return [System.Reflection.Assembly]::Load([System.IO.File]::ReadAllBytes($candidate))
        }
    } catch { }
    return $null
}
[System.AppDomain]::CurrentDomain.add_AssemblyResolve($resolver)

try {
    $bytes = [System.IO.File]::ReadAllBytes($playwrightDll.FullName)
    [Reflection.Assembly]::Load($bytes) | Out-Null
    Write-Host "[*] Loaded Microsoft.Playwright from memory"
}
catch {
    Write-Error "Failed to load Microsoft.Playwright.dll: $($_.Exception.Message)"
    exit 1
}

# ---------------------------------------------------------------------------
# 6. Run Playwright's CLI entrypoint with our default args
# ---------------------------------------------------------------------------
Write-Host "[*] Running Playwright: $($PlaywrightArgs -join ' ')"

try {
    $exitCode = [Microsoft.Playwright.Program]::Main($PlaywrightArgs)
}
catch {
    Write-Error "Playwright invocation failed: $($_.Exception.Message)"
    exit 1
}
finally {
    [System.AppDomain]::CurrentDomain.remove_AssemblyResolve($resolver)
    # Best-effort cleanup of the temp working directory.
    # Wrapped in try/catch because Playwright may still hold file handles
    # (browser binaries live in %USERPROFILE%\AppData\Local\ms-playwright, not here).
    try { Remove-Item $workDir -Recurse -Force -ErrorAction SilentlyContinue } catch { }
}

