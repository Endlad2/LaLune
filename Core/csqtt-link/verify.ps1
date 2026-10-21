# Quick verification of a csqtt:// link on Windows via the compiled CLI.
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$Link
)

$ErrorActionPreference = 'Stop'
Push-Location $PSScriptRoot
try {
    cargo run --quiet -- --url $Link
} finally {
    Pop-Location
}
