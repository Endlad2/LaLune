#Requires -Version 5.1
<#
.SYNOPSIS
    Downloads and runs the LaLune Token Fetcher.

.DESCRIPTION
    Sets PLAYWRIGHT_BROWSERS_PATH, downloads the latest LaLuneTokenFetcher_Windows.zip
    from GitHub releases, extracts it to a temp folder, runs LaLuneTokenFetcher.exe
    and waits until it exits before cleaning up.

.NOTES
    Run in PowerShell 5.1+ or PowerShell 7+.
#>

[CmdletBinding()]
param(
    [string]$BrowsersPath = "$env:APPDATA\.la-lune\vk-token-fetcher\browsers",
    [string]$ZipUrl       = "https://github.com/Endlad2/LaLune/releases/latest/download/LaLuneTokenFetcher_Windows.zip",
    [string]$ExeName      = "LaLuneTokenFetcher.exe"
)

$ErrorActionPreference = 'Stop'

# --- 1. Set Playwright browsers path -----------------------------------------
$env:PLAYWRIGHT_BROWSERS_PATH = $BrowsersPath
if (-not (Test-Path -LiteralPath $BrowsersPath)) {
    New-Item -ItemType Directory -Force -Path $BrowsersPath | Out-Null
    Write-Host "Created Playwright browsers directory: $BrowsersPath" -ForegroundColor DarkGray
}

# --- 2. Prepare temp workspace ------------------------------------------------
$workDir = Join-Path $env:TEMP ("LaLuneTokenFetcher_" + [Guid]::NewGuid().ToString('N').Substring(0,8))
$zipPath = Join-Path $workDir "LaLuneTokenFetcher_Windows.zip"
New-Item -ItemType Directory -Force -Path $workDir | Out-Null

try {
    # --- 3. Download zip ------------------------------------------------------
    Write-Host "Downloading LaLuneTokenFetcher..." -ForegroundColor Cyan
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $ZipUrl -OutFile $zipPath -UseBasicParsing

    # --- 4. Extract -----------------------------------------------------------
    Write-Host "Extracting to $workDir" -ForegroundColor Cyan
    Expand-Archive -LiteralPath $zipPath -DestinationPath $workDir -Force

    # Locate the exe (may be nested in a subfolder)
    $exe = Get-ChildItem -Path $workDir -Filter $ExeName -Recurse -File |
           Select-Object -First 1
    if (-not $exe) {
        throw "Could not find $ExeName inside the downloaded archive."
    }

    # --- 5. Run and wait ------------------------------------------------------
    Write-Host "Starting $($exe.FullName) ..." -ForegroundColor Green
    $proc = Start-Process -FilePath $exe.FullName -WorkingDirectory $exe.DirectoryName -PassThru
    $proc.WaitForExit()

    Write-Host "LaLuneTokenFetcher exited with code $($proc.ExitCode)." -ForegroundColor Green
}
finally {
    # --- 6. Cleanup temp workspace (leave browsers dir intact) ----------------
    if (Test-Path -LiteralPath $workDir) {
        Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}