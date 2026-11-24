# Smoke-тест Windows: быстрая проверка, что главное работает (установка → данные → значок → удаление).
# Всё ставится во временные папки, ваши настройки не трогаются.
# Запуск на Windows:  powershell -NoProfile -ExecutionPolicy Bypass -File tests\windows\smoke.ps1
# На macOS/Linux (pwsh) проверяется только то, что не требует Windows.
$ErrorActionPreference = 'Continue'
$Repo  = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$Win   = Join-Path $Repo 'windows'
$IsWin = [Environment]::OSVersion.Platform -eq 'Win32NT'
$PsExe = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
$script:Fail = 0
function Check([string]$Name, [scriptblock]$Test) {
    $detail = ''
    try { $r = & $Test; $ok = [bool]($r | Select-Object -Last 1) } catch { $ok = $false; $detail = $_.Exception.Message }
    if ($ok) { Write-Host "  [OK]   $Name" -ForegroundColor Green }
    else { Write-Host "  [FAIL] $Name $detail" -ForegroundColor Red; $script:Fail++ }
}
function Invoke-Ps([string]$File, [string]$Stdin = $null) {
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $File)
    if ($null -ne $Stdin) { $Stdin | & $PsExe @a 2>&1 | Out-String } else { & $PsExe @a 2>&1 | Out-String }
}

Write-Host "### Smoke: Windows ($($PSVersionTable.PSEdition) $($PSVersionTable.PSVersion))"

$sb = Join-Path ([IO.Path]::GetTempPath()) ('cl-smoke-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path (Join-Path $sb 'home\.claude'), (Join-Path $sb 'appdata'), (Join-Path $sb 'startup') | Out-Null
$env:USERPROFILE  = Join-Path $sb 'home'
$env:HOME         = $env:USERPROFILE
$env:LOCALAPPDATA = Join-Path $sb 'appdata'
$env:CLAUDE_LIMITS_NO_LAUNCH   = '1'
$env:CLAUDE_LIMITS_STARTUP_DIR = Join-Path $sb 'startup'
$settings = Join-Path $env:USERPROFILE '.claude\settings.json'
$limits   = Join-Path $env:USERPROFILE '.claude\limits.json'
$install  = Join-Path $env:LOCALAPPDATA 'ClaudeLimits'
[IO.File]::WriteAllText($settings, '{"model":"opus"}')
$OutputEncoding = New-Object Text.UTF8Encoding $false
$r = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 3600
$payload = '{"model":{"display_name":"Opus"},"rate_limits":{"five_hour":{"used_percentage":42,"resets_at":' + $r + '},"seven_day":{"used_percentage":17,"resets_at":' + ($r + 86400) + '}}}'

try {
    Check '1. Скрипты без синтаксических ошибок' {
        $bad = 0
        foreach ($f in Get-ChildItem $Win -Filter *.ps1) {
            $e = $null; [void][Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$e)
            if ($e) { $bad++; Write-Host "         $($f.Name): $($e[0].Message)" }
        }
        $bad -eq 0
    }

    Check '2. statusline: строка статуса и limits.json' {
        $out = (Invoke-Ps (Join-Path $Win 'statusline.ps1') $payload).Trim()
        if ($out -ne '[Opus] 5h: 42% 7d: 17%') { Write-Host "         получено: $out" }
        ($out -eq '[Opus] 5h: 42% 7d: 17%') -and (Test-Path $limits)
    }

    if (-not $IsWin) { Write-Host '  (установка, значок и удаление проверяются только на Windows)' }
    else {
        Check '3. Установка' {
            $o = Invoke-Ps (Join-Path $Win 'install.ps1')
            if (-not (Test-Path (Join-Path $install 'ClaudeLimits.ps1'))) { Write-Host $o }
            (Test-Path (Join-Path $install 'ClaudeLimits.ps1')) -and (Test-Path (Join-Path $env:CLAUDE_LIMITS_STARTUP_DIR 'ClaudeLimits.lnk'))
        }
        Check '4. statusLine прописан, остальные настройки целы' {
            $s = [IO.File]::ReadAllText($settings) | ConvertFrom-Json
            ($s.model -eq 'opus') -and ($s.statusLine.command -like '*statusline.ps1*')
        }
        Check '5. Команда из settings.json работает (как её запускает Claude Code)' {
            $cmd = ([IO.File]::ReadAllText($settings) | ConvertFrom-Json).statusLine.command
            $bat = Join-Path $sb 'run.cmd'
            [IO.File]::WriteAllText($bat, "@echo off`r`n$cmd`r`n")
            $out = ($payload | & cmd.exe /d /c $bat 2>&1 | Out-String).Trim()
            if ($out -ne '[Opus] 5h: 42% 7d: 17%') { Write-Host "         команда: $cmd`n         получено: $out" }
            $out -eq '[Opus] 5h: 42% 7d: 17%'
        }
        Check '6. Значок в трее: меню, языки, график, уведомление' {
            $env:CLAUDE_LIMITS_SELFTEST = '1'
            $winPs = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
            $out = & $winPs -NoProfile -ExecutionPolicy Bypass -File (Join-Path $install 'ClaudeLimits.ps1') 2>&1 | Out-String
            Remove-Item Env:\CLAUDE_LIMITS_SELFTEST
            if ($out -notmatch 'SELFTEST OK') { Write-Host $out }
            $out -match 'SELFTEST OK'
        }
        Check '7. Удаление' {
            $o = Invoke-Ps (Join-Path $install 'uninstall.ps1')
            $s = [IO.File]::ReadAllText($settings) | ConvertFrom-Json
            -not (Test-Path $install) -and -not $s.statusLine -and ($s.model -eq 'opus')
        }
    }
} finally {
    Remove-Item -Recurse -Force $sb -ErrorAction SilentlyContinue
}

Write-Host ''
if ($script:Fail -eq 0) { Write-Host 'Smoke (Windows): всё работает' -ForegroundColor Green; exit 0 }
Write-Host "Smoke (Windows): есть проблемы ($script:Fail)" -ForegroundColor Red; exit 1
