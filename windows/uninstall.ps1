# Удаление ClaudeLimits для Windows.
#   powershell -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\ClaudeLimits\uninstall.ps1"

$ErrorActionPreference = 'SilentlyContinue'
$InstallDir = Join-Path $env:LOCALAPPDATA 'ClaudeLimits'
$Settings   = Join-Path $env:USERPROFILE '.claude\settings.json'

Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -like '*ClaudeLimits.ps1*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force }

Remove-Item -Force (Join-Path ([Environment]::GetFolderPath('Startup')) 'ClaudeLimits.lnk')

if (Test-Path $Settings) {
    $obj = [IO.File]::ReadAllText($Settings) | ConvertFrom-Json
    if ($obj.statusLine -and ($obj.statusLine.command -like '*ClaudeLimits*')) {
        Copy-Item -Force $Settings "$Settings.bak"
        $obj.PSObject.Properties.Remove('statusLine')
        [IO.File]::WriteAllText($Settings, ($obj | ConvertTo-Json -Depth 32), (New-Object Text.UTF8Encoding $false))
    }
}

Remove-Item -Force (Join-Path $env:USERPROFILE '.claude\limits.json')
Remove-Item -Force (Join-Path $env:USERPROFILE '.claude\limits-history.jsonl')
Set-Location $env:USERPROFILE
Remove-Item -Recurse -Force $InstallDir
Write-Host 'ClaudeLimits удалён.'
