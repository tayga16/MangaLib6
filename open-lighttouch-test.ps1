param(
    [string]$EmulatorPath = 'D:\LightTouch-v0.0.13-Windows-x86_64\lighttouch.exe',
    [string]$DataRoot = 'D:\MangaPad-LightTouch-test'
)

$ErrorActionPreference = 'Stop'
$emulator = (Resolve-Path -LiteralPath $EmulatorPath).Path
$dataDirectory = (Resolve-Path -LiteralPath $DataRoot).Path
if (-not (Test-Path -LiteralPath (Join-Path $dataDirectory 'library\records') -PathType Container)) {
    throw 'The test device library is missing.'
}
$activeWorkers = Get-CimInstance Win32_Process -Filter "Name = 'lighttouch.exe'" |
    Where-Object { $_.CommandLine -match '\sworker\s' }
if ($activeWorkers) {
    throw 'An emulator guest is running. Shut it down in LightTouch before opening the test library.'
}
$previousDataRoot = $env:LIGHTTOUCH_DATA
try {
    $env:LIGHTTOUCH_DATA = $dataDirectory
    Start-Process -FilePath $emulator -WorkingDirectory (Split-Path -Parent $emulator) -WindowStyle Hidden
} finally {
    $env:LIGHTTOUCH_DATA = $previousDataRoot
}
Write-Host "LightTouch opened with the separate test library: $dataDirectory"
Write-Host 'Enable Direct internet and Local network access, start the iPad, and open MangaLib6.'
