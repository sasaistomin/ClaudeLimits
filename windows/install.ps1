# Установка ClaudeLimits для Windows.
# Одной командой (в PowerShell или cmd):
#   powershell -NoProfile -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/sasaistomin/ClaudeLimits/main/windows/install.ps1 -OutFile $env:TEMP\cl-install.ps1; & $env:TEMP\cl-install.ps1"
# Или из скачанной папки проекта:
#   powershell -ExecutionPolicy Bypass -File windows\install.ps1
#
# Переменные для тестов:
#   CLAUDE_LIMITS_REPO_RAW     откуда скачивать файлы (по умолчанию GitHub)
#   CLAUDE_LIMITS_NO_LAUNCH=1  не останавливать и не запускать значок
#   CLAUDE_LIMITS_STARTUP_DIR  куда класть ярлык автозапуска (по умолчанию «Автозагрузка»)

$ErrorActionPreference = 'Stop'
$RepoRaw    = if ($env:CLAUDE_LIMITS_REPO_RAW) { $env:CLAUDE_LIMITS_REPO_RAW } else { 'https://raw.githubusercontent.com/sasaistomin/ClaudeLimits/main' }
$InstallDir = Join-Path $env:LOCALAPPDATA 'ClaudeLimits'
$Settings   = Join-Path $env:USERPROFILE '.claude\settings.json'
$StartupDir = if ($env:CLAUDE_LIMITS_STARTUP_DIR) { $env:CLAUDE_LIMITS_STARTUP_DIR } else { [Environment]::GetFolderPath('Startup') }
$NoLaunch   = [bool]$env:CLAUDE_LIMITS_NO_LAUNCH
$Files      = @('ClaudeLimits.Core.ps1', 'ClaudeLimits.ps1', 'statusline.ps1', 'uninstall.ps1')

Write-Host '==> ClaudeLimits: установка' -ForegroundColor Cyan

# 1. Остановить запущенный экземпляр
if (-not $NoLaunch) {
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
        Where-Object { $_.CommandLine -like '*ClaudeLimits.ps1*' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}

# 2. Скопировать или скачать файлы
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
$localDir = if ($PSCommandPath) { Split-Path -Parent $PSCommandPath } else { $null }
$useLocal = $localDir -and (Test-Path (Join-Path $localDir 'ClaudeLimits.Core.ps1'))
foreach ($f in $Files) {
    $dst = Join-Path $InstallDir $f
    if ($useLocal) {
        Copy-Item -Force (Join-Path $localDir $f) $dst
    } else {
        Write-Host "    скачиваю $f"
        Invoke-WebRequest -UseBasicParsing -Uri "$RepoRaw/windows/$f" -OutFile $dst
    }
    Unblock-File $dst -ErrorAction SilentlyContinue
}

. (Join-Path $InstallDir 'ClaudeLimits.Core.ps1')

# 3. Прописать statusLine в ~/.claude/settings.json
$r = Set-ClaudeStatusLine $Settings (Get-StatusLineCommand $InstallDir)
if (-not $r.Ok) { throw "Не удалось разобрать $Settings — исправьте JSON и запустите установку снова." }
if ($r.Replaced) { Write-Host "Внимание: прежний statusLine ($($r.Replaced)) заменён. Копия: settings.json.bak" -ForegroundColor Yellow }
Write-Host "==> statusLine прописан в $Settings"

# 4. Автозапуск при входе в Windows
$trayScript = Join-Path $InstallDir 'ClaudeLimits.ps1'
$psExe = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
$psArgs = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$trayScript`""
New-Item -ItemType Directory -Force -Path $StartupDir | Out-Null
$ws = New-Object -ComObject WScript.Shell
$lnk = $ws.CreateShortcut((Join-Path $StartupDir 'ClaudeLimits.lnk'))
$lnk.TargetPath = $psExe
$lnk.Arguments = $psArgs
$lnk.WindowStyle = 7
$lnk.Save()

# 5. Запуск
if (-not $NoLaunch) {
    Start-Process -FilePath $psExe -ArgumentList $psArgs -WindowStyle Hidden
    Write-Host ''
    Write-Host 'Готово! Значок появился в трее (справа внизу, возможно под стрелкой ^).' -ForegroundColor Green
    Write-Host 'Отправьте любое сообщение в Claude Code, чтобы появились цифры.'
} else {
    Write-Host 'Готово (без запуска).'
}
