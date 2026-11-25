# Удаление ClaudeLimits для Windows.
#   powershell -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\ClaudeLimits\uninstall.ps1"

$ErrorActionPreference = 'SilentlyContinue'
$InstallDir = Join-Path $env:LOCALAPPDATA 'ClaudeLimits'
$ClaudeDir  = Join-Path $env:USERPROFILE '.claude'
$StartupDir = if ($env:CLAUDE_LIMITS_STARTUP_DIR) { $env:CLAUDE_LIMITS_STARTUP_DIR } else { [Environment]::GetFolderPath('Startup') }

if (-not $env:CLAUDE_LIMITS_NO_LAUNCH) {
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
        Where-Object { $_.CommandLine -like '*ClaudeLimits.ps1*' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
}

Remove-Item -Force (Join-Path $StartupDir 'ClaudeLimits.lnk')

$core = Join-Path $InstallDir 'ClaudeLimits.Core.ps1'
if (Test-Path $core) {
    . $core
    Remove-ClaudeStatusLine (Join-Path $ClaudeDir 'settings.json') | Out-Null
}

Remove-Item -Force (Join-Path $ClaudeDir 'limits.json')
Remove-Item -Force (Join-Path $ClaudeDir 'limits-history.jsonl')
Remove-Item -Force (Join-Path $ClaudeDir 'limits-phone.json')
Set-Location $env:USERPROFILE
Remove-Item -Recurse -Force $InstallDir
Write-Host 'ClaudeLimits удалён.'
