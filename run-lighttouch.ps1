param(
    [string]$EmulatorPath = 'D:\LightTouch-v0.0.13-Windows-x86_64\lighttouch.exe',
    [ValidatePattern('^[a-f0-9]{32}$')]
    [string]$RecordId = '9812c532f73217efafa4660900b0c52b',
    [string]$DataRoot,
    [ValidateRange(60, 600)]
    [int]$Seconds = 90,
    [switch]$Smoke
)

$ErrorActionPreference = 'Stop'
$emulator = (Resolve-Path -LiteralPath $EmulatorPath).Path
$previousDataRoot = $env:LIGHTTOUCH_DATA
if ($DataRoot) {
    $DataRoot = (Resolve-Path -LiteralPath $DataRoot).Path
}
$buildDirectory = Join-Path $PSScriptRoot 'build'
$ipa = Get-ChildItem -LiteralPath $buildDirectory -Filter '*.ipa' -Recurse |
    Where-Object { $_.Name -like '*MangaLib6*' -and ($_.Name -like '*smoke*') -eq $Smoke.IsPresent } |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1
if (-not $ipa) {
    throw 'IPA not found. Build MangaLib6-ipa; for -Smoke also run tools/make_smoke_ipa.py.'
}
Write-Host "Installing $($ipa.Name). Stop the selected guest in LightTouch before running this script."
Write-Host "Allow $Seconds seconds for iOS to boot, install the IPA, and shut down safely."
$installed = $false
$cleanShutdown = $false
Push-Location (Split-Path -Parent $emulator)
try {
    if ($DataRoot) {
        $env:LIGHTTOUCH_DATA = $DataRoot
    }
    $ErrorActionPreference = 'Continue'
    & $emulator run $RecordId --seconds $Seconds --network direct --lan --install $ipa.FullName 2>&1 |
        ForEach-Object {
            $line = "$_"
            Write-Host $line
            if ($line -match 'installed InstalledApp') {
                $installed = $true
            }
            if ($line -match 'exit clean=true dirty=false') {
                $cleanShutdown = $true
            }
        }
    $exitCode = $LASTEXITCODE
} finally {
    $env:LIGHTTOUCH_DATA = $previousDataRoot
    $ErrorActionPreference = 'Stop'
    Pop-Location
}
if ($exitCode -ne 0) {
    throw "LightTouch exited with code $exitCode."
}
if (-not $installed -or -not $cleanShutdown) {
    throw 'Installation or clean shutdown was not confirmed. Inspect the LightTouch output before restarting the guest.'
}
Write-Host 'Installation and clean shutdown confirmed.'
Write-Host 'For reading, enable Direct internet and Local network access in the LightTouch GUI.'
Write-Host 'Open LightTouch, start this iPad, unlock it, and tap MangaLib6 on the second Home Screen.'
Write-Host 'MangaLib6 uses the direct API by default, with a five-page RAM buffer. The mode button selects the optional offline snapshot.'
