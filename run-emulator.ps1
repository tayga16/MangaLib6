param(
    [string]$EmulatorPath = "$env:USERPROFILE\Downloads\HyperHLE_Windows_x86_64\touchHLE.exe"
)

$ErrorActionPreference = 'Stop'
$emulator = (Resolve-Path -LiteralPath $EmulatorPath).Path
$buildDirectory = Join-Path $PSScriptRoot 'build'
$ipa = Get-ChildItem -LiteralPath $buildDirectory -Filter '*.ipa' -Recurse |
    Where-Object { $_.Name -like '*MangaLib6*' -and $_.Name -notlike '*smoke*' } |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1
if (-not $ipa) {
    throw 'IPA not found. Run meow build MangaLib6-ipa first.'
}
Push-Location (Split-Path -Parent $emulator)
try {
    & $emulator $ipa.FullName '--device-family=ipad-1' '--ios-version=5.1.1' '--allow-network-access'
} finally {
    Pop-Location
}
