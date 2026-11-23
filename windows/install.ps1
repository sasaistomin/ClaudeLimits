# Установка ClaudeLimits для Windows.
# Одной командой (PowerShell):
#   irm https://raw.githubusercontent.com/OWNER/claude-limits/main/windows/install.ps1 -OutFile "$env:TEMP\cl-install.ps1"; powershell -ExecutionPolicy Bypass -File "$env:TEMP\cl-install.ps1"
# Или из скачанной папки проекта:
#   powershell -ExecutionPolicy Bypass -File windows\install.ps1

$ErrorActionPreference = 'Stop'
$RepoRaw    = 'https://raw.githubusercontent.com/OWNER/claude-limits/main'
$InstallDir = Join-Path $env:LOCALAPPDATA 'ClaudeLimits'
$ClaudeDir  = Join-Path $env:USERPROFILE '.claude'
$Settings   = Join-Path $ClaudeDir 'settings.json'
$Files      = @('ClaudeLimits.ps1', 'statusline.ps1', 'uninstall.ps1')
$Utf8NoBom  = New-Object Text.UTF8Encoding $false

Write-Host '==> ClaudeLimits: установка' -ForegroundColor Cyan

# 1. Остановить запущенный экземпляр
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -like '*ClaudeLimits.ps1*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

# 2. Скопировать или скачать файлы
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
$localDir = if ($PSCommandPath) { Split-Path -Parent $PSCommandPath } else { $null }
foreach ($f in $Files) {
    $dst = Join-Path $InstallDir $f
    if ($localDir -and (Test-Path (Join-Path $localDir $f))) {
        Copy-Item -Force (Join-Path $localDir $f) $dst
    } else {
        Write-Host "    скачиваю $f"
        Invoke-WebRequest -UseBasicParsing -Uri "$RepoRaw/windows/$f" -OutFile $dst
    }
    Unblock-File $dst -ErrorAction SilentlyContinue
}

# 3. Прописать statusLine в ~/.claude/settings.json
New-Item -ItemType Directory -Force -Path $ClaudeDir | Out-Null
$obj = New-Object PSObject
if (Test-Path $Settings) {
    $text = [IO.File]::ReadAllText($Settings)
    if ($text.Trim()) {
        try { $obj = $text | ConvertFrom-Json }
        catch { throw "Не удалось разобрать $Settings — исправьте JSON и запустите установку снова." }
    }
    Copy-Item -Force $Settings "$Settings.bak"
    if ($obj.statusLine -and $obj.statusLine.command -and ($obj.statusLine.command -notlike '*ClaudeLimits*')) {
        Write-Host "Внимание: прежний statusLine ($($obj.statusLine.command)) заменён. Копия: settings.json.bak" -ForegroundColor Yellow
    }
}
$slPath = (Join-Path $InstallDir 'statusline.ps1') -replace '\\', '/'
$statusLine = [ordered]@{
    type    = 'command'
    command = "powershell -NoProfile -ExecutionPolicy Bypass -File `"$slPath`""
}
$obj | Add-Member -Force -NotePropertyName statusLine -NotePropertyValue $statusLine
[IO.File]::WriteAllText($Settings, ($obj | ConvertTo-Json -Depth 32), $Utf8NoBom)
Write-Host "==> statusLine прописан в $Settings"

# 4. Автозапуск при входе в Windows
$trayScript = Join-Path $InstallDir 'ClaudeLimits.ps1'
$psExe = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
$psArgs = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$trayScript`""
$lnkPath = Join-Path ([Environment]::GetFolderPath('Startup')) 'ClaudeLimits.lnk'
$ws = New-Object -ComObject WScript.Shell
$lnk = $ws.CreateShortcut($lnkPath)
$lnk.TargetPath = $psExe
$lnk.Arguments = $psArgs
$lnk.WindowStyle = 7
$lnk.Save()

# 5. Запуск
Start-Process -FilePath $psExe -ArgumentList $psArgs -WindowStyle Hidden

Write-Host ''
Write-Host 'Готово! Значок появился в трее (справа внизу, возможно под стрелкой ^).' -ForegroundColor Green
Write-Host 'Отправьте любое сообщение в Claude Code, чтобы появились цифры.'
