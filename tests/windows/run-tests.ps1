# Тесты Windows-версии ClaudeLimits.
# Запуск:  powershell -NoProfile -ExecutionPolicy Bypass -File tests\windows\run-tests.ps1
#          (или pwsh -File tests/windows/run-tests.ps1 — на macOS/Linux выполнится всё, кроме Windows-only части)
#
# Части:
#   1. Файлы: кодировка UTF-8 с BOM (нужна Windows PowerShell 5.1 для кириллицы), синтаксис, полнота переводов
#   2. Юнит-тесты логики (ClaudeLimits.Core.ps1)
#   3. statusline.ps1 как отдельный процесс (так его запускает Claude Code)
#   4. Только Windows: настоящая установка в изолированные папки, команда из settings.json через cmd и Git Bash,
#      установка «одной командой» со скачиванием, самопроверка значка в трее (WinForms + график), удаление

$ErrorActionPreference = 'Stop'
$Repo = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$WinDir = Join-Path $Repo 'windows'
$OnWindows = $env:OS -eq 'Windows_NT'
$PsExe = (Get-Process -Id $PID).Path

. (Join-Path $WinDir 'ClaudeLimits.Core.ps1')

$script:Pass = 0
$script:Fail = New-Object System.Collections.ArrayList
$script:Current = ''

function Test([string]$Name, [scriptblock]$Body) {
    $script:Current = $Name
    try { & $Body } catch { [void]$script:Fail.Add("$Name — исключение: $($_.Exception.Message) ($($_.InvocationInfo.ScriptLineNumber))") }
}
function Ok([bool]$Cond, [string]$Msg) {
    if ($Cond) { $script:Pass++ } else { [void]$script:Fail.Add("$($script:Current): $Msg") }
}
function Eq($Actual, $Expected, [string]$Msg = '') {
    Ok ($Actual -eq $Expected) "$Msg ожидалось «$Expected», получено «$Actual»"
}
function New-TempDir {
    $d = Join-Path ([IO.Path]::GetTempPath()) ('cl-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $d | Out-Null
    return $d
}
function Write-Utf8([string]$Path, [string]$Text) {
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding $false))
}

$Now = [int64]1800000000
$ru = $Strings.ru; $en = $Strings.en

Write-Host "PowerShell $($PSVersionTable.PSVersion) | Windows: $OnWindows"

# ============================================================ 1. Файлы
Write-Host '== Файлы'

Test 'все .ps1 в UTF-8 с BOM и без синтаксических ошибок' {
    foreach ($f in Get-ChildItem $WinDir -Filter *.ps1) {
        $bytes = [IO.File]::ReadAllBytes($f.FullName)
        Ok ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) "$($f.Name): нет UTF-8 BOM"
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$errors)
        Ok ($errors.Count -eq 0) "$($f.Name): синтаксис: $($errors | Select-Object -First 1)"
    }
}

Test 'переводы: одинаковые ключи на обоих языках' {
    foreach ($k in $ru.Keys) { Ok ($en.ContainsKey($k)) "нет английского перевода для $k" }
    foreach ($k in $en.Keys) { Ok ($ru.ContainsKey($k)) "нет русского перевода для $k" }
    Eq $ru.Title 'Лимиты Claude' 'кириллица читается корректно:'
}

# ============================================================ 2. Логика
Write-Host '== Логика (Core)'

Test 'Format-Countdown' {
    Eq (Format-Countdown ($Now + 300) $ru $Now) 'через 5 мин'
    Eq (Format-Countdown ($Now + 2 * 3600 + 900) $ru $Now) 'через 2 ч 15 мин'
    Eq (Format-Countdown ($Now + 3 * 86400 + 4 * 3600) $ru $Now) 'через 3 д 4 ч'
    Eq (Format-Countdown ($Now - 5) $ru $Now) 'сброшен'
    Eq (Format-Countdown ($Now + 300) $en $Now) 'in 5m'
    Eq (Format-Countdown ($Now + 2 * 3600 + 900) $en $Now) 'in 2h 15m'
    Eq (Format-Countdown ($Now + 3 * 86400 + 4 * 3600) $en $Now) 'in 3d 4h'
    Eq (Format-Countdown $Now $en $Now) 'done'
}

Test 'Format-Ago' {
    Eq (Format-Ago ($Now - 10) $ru $Now) 'только что'
    Eq (Format-Ago ($Now - 300) $ru $Now) '5 мин назад'
    Eq (Format-Ago ($Now - 7200) $en $Now) '2 h ago'
    Eq (Format-Ago ($Now - 3 * 86400) $en $Now) '3 d ago'
}

Test 'Resolve-Lang' {
    Eq (Resolve-Lang 'ru' 'en') 'ru'
    Eq (Resolve-Lang 'en' 'ru') 'en'
    Eq (Resolve-Lang 'system' 'ru') 'ru'
    Eq (Resolve-Lang 'system' 'de') 'en'
    Eq (Resolve-Lang 'мусор' 'ru') 'ru' 'неизвестное значение = системный:'
}

Test 'Get-Level' {
    Eq (Get-Level 10) 'green'; Eq (Get-Level 69.9) 'green'
    Eq (Get-Level 70) 'yellow'; Eq (Get-Level 89) 'yellow'
    Eq (Get-Level 90) 'red'; Eq (Get-Level 100) 'red'
}

Test 'Read-Config / Save-Config' {
    $d = New-TempDir
    $p = Join-Path $d 'config.json'
    $c = Read-Config $p
    Eq $c.language 'system' 'по умолчанию:'
    Ok ($c.notifications -eq $true) 'уведомления по умолчанию включены'
    $c.language = 'en'; $c.notifications = $false; $c.notified['five_hour:80'] = 1800003600.0
    Save-Config $c $p
    $c2 = Read-Config $p
    Eq $c2.language 'en'; Ok ($c2.notifications -eq $false) 'notifications сохранены'
    Eq $c2.notified['five_hour:80'] 1800003600.0 'notified сохранён:'
    Write-Utf8 $p '{сломано'
    Eq (Read-Config $p).language 'system' 'битый файл = настройки по умолчанию:'
    Write-Utf8 $p '{"language":"fr"}'
    Eq (Read-Config $p).language 'system' 'неизвестный язык игнорируется:'
    Remove-Item -Recurse -Force $d
}

Test 'Read-Limits' {
    $d = New-TempDir
    $p = Join-Path $d 'limits.json'
    Ok ($null -eq (Read-Limits $p $Now)) 'нет файла -> $null'
    Write-Utf8 $p ('{"updated_at":' + $Now + ',"model":"Opus","rate_limits":{"five_hour":{"used_percentage":23.5,"resets_at":' + ($Now + 3600) + '},"seven_day":{"used_percentage":90,"resets_at":' + ($Now - 10) + '}}}')
    $l = Read-Limits $p $Now
    Eq $l.Five.Used 23.5; Eq $l.Five.Left 76.5; Eq $l.Five.Reset ($Now + 3600)
    Eq $l.Week.Used 0 'сброшенное окно = 0%:'; Eq $l.Week.RawUsed 90 'RawUsed сохраняется:'
    Eq $l.Updated $Now
    Write-Utf8 $p '{"updated_at":1,"rate_limits":{"seven_day":{"used_percentage":5,"resets_at":9999999999}}}'
    $l = Read-Limits $p $Now
    Ok ($null -eq $l.Five -and $l.Week.Used -eq 5) 'только недельное окно'
    Write-Utf8 $p 'не json'
    Ok ($null -eq (Read-Limits $p $Now)) 'битый файл -> $null'
    Remove-Item -Recurse -Force $d
}

Test 'Get-TrayTooltip: не длиннее 63 символов' {
    $l = @{ Five = @{ Left = 86.4 }; Week = @{ Left = 49 } }
    Eq (Get-TrayTooltip $l $ru) 'Claude · 5ч: 86% · неделя: 49%'
    Eq (Get-TrayTooltip $l $en) 'Claude · 5h: 86% · week: 49%'
    foreach ($T in @($ru, $en)) {
        Ok ((Get-TrayTooltip $null $T).Length -le 63) 'без данных <= 63'
        Ok ((Get-TrayTooltip @{ Five = @{ Left = 100 }; Week = @{ Left = 100 } } $T).Length -le 63) 'с данными <= 63'
    }
}

Test 'Get-NotifyEvent: пороги 80/95, один раз за окно' {
    $n = @{}
    $r = $Now + 3600
    Ok ($null -eq (Get-NotifyEvent 'five_hour' @{ RawUsed = 50; Reset = $r } $n $Now)) '50% — тихо'
    $e = Get-NotifyEvent 'five_hour' @{ RawUsed = 81; Reset = $r } $n $Now
    Ok ($e.Type -eq 'low' -and $e.Threshold -eq 80 -and $e.Used -eq 81) '81% -> уведомление 80'
    Ok ($null -eq (Get-NotifyEvent 'five_hour' @{ RawUsed = 85; Reset = $r } $n $Now)) 'повтор 80 не нужен'
    $e = Get-NotifyEvent 'five_hour' @{ RawUsed = 96; Reset = $r } $n $Now
    Ok ($e.Threshold -eq 95) '96% -> уведомление 95'
    Ok ($null -eq (Get-NotifyEvent 'five_hour' @{ RawUsed = 99; Reset = ($r + 600) } $n $Now)) 'resets_at «плавает» — то же окно'
}

Test 'Get-NotifyEvent: сразу 96%, новое окно, независимость окон' {
    $n = @{}
    $e = Get-NotifyEvent 'seven_day' @{ RawUsed = 96; Reset = ($Now + 3600) } $n $Now
    Ok ($e.Threshold -eq 95) 'одно уведомление 95'
    Eq $n['seven_day:80'] ([double]($Now + 3600)) '80 тоже помечен:'
    Ok ($null -ne (Get-NotifyEvent 'seven_day' @{ RawUsed = 85; Reset = ($Now + 9 * 86400) } $n $Now)) 'новое окно — снова уведомляем'
    Ok ($null -ne (Get-NotifyEvent 'five_hour' @{ RawUsed = 85; Reset = ($Now + 3600) } $n $Now)) '5ч не зависит от недели'
}

Test 'Get-NotifyEvent: сброс окна' {
    $n = @{}
    $e = Get-NotifyEvent 'five_hour' @{ RawUsed = 90; Reset = ($Now - 60) } $n $Now
    Eq $e.Type 'reset'
    Ok ($null -eq (Get-NotifyEvent 'five_hour' @{ RawUsed = 90; Reset = ($Now - 60) } $n $Now)) 'один раз'
    $n2 = @{}
    Ok ($null -eq (Get-NotifyEvent 'five_hour' @{ RawUsed = 50; Reset = ($Now - 60) } $n2 $Now)) 'слабый расход — тихо'
    Ok ($null -eq (Get-NotifyEvent 'five_hour' @{ RawUsed = 90; Reset = ($Now - 3600) } $n2 $Now)) 'час назад — устарело'
}

Test 'Format-Notification' {
    $w = @{ RawUsed = 81; Reset = ($Now + 3600) }
    $m = Format-Notification @{ Type = 'low'; Threshold = 80; Used = 81 } $w $true $ru $Now
    Eq $m.Title 'Claude: осталось 19%'
    Eq $m.Body '5-часовое окно израсходовано на 81%. Сброс через 1 ч 0 мин.'
    Eq $m.Icon 'Info'
    $m = Format-Notification @{ Type = 'low'; Threshold = 95; Used = 97 } $w $false $en $Now
    Eq $m.Title 'Claude: 3% left'; Eq $m.Icon 'Warning'
    Ok ($m.Body -like 'Weekly limit is 97% used*') 'тело на английском'
    $m = Format-Notification @{ Type = 'reset' } $w $false $ru $Now
    Eq $m.Title 'Лимит Claude сброшен'; Ok ($m.Body -like 'Недельный*') 'сброс недели'
}

Test 'Read-History' {
    $d = New-TempDir
    $p = Join-Path $d 'h.jsonl'
    Eq @(Read-History $p).Count 0 'нет файла:'
    Write-Utf8 $p ("{`"t`":1,`"f`":5}`n`n{`"t`":2,`"w`":7}`n")
    $h = @(Read-History $p)
    Eq $h.Count 2 'пустые строки пропускаются:'
    Eq $h[1].w 7
    Write-Utf8 $p 'мусор'
    Eq @(Read-History $p).Count 0 'битый файл:'
    Remove-Item -Recurse -Force $d
}

Test 'Get-ChartModel: точки и прогноз' {
    $start = $Now - 4 * 3600
    $limits = @{ Five = @{ Used = 40.0; Reset = ($Now + 3600) }; Week = @{ Used = 9.0; Reset = ($Now + 86400) } }
    $hist = @(
        [pscustomobject]@{ t = ($start - 100); f = 99 },
        [pscustomobject]@{ t = ($start + 600); f = 10; w = 5 },
        [pscustomobject]@{ t = ($start + 7200); f = 25 },
        [pscustomobject]@{ t = ($Now + 100); f = 77 }
    )
    $m = Get-ChartModel $limits $hist $true $Now
    Eq (($m.Points | ForEach-Object { $_[1] }) -join ',') '0,10,25,40' 'точки 5ч:'
    Eq $m.Start $start; Eq $m.End ($Now + 3600)
    Ok ($null -eq $m.RunOut) '40% за 4ч, остался 1ч — хватит'
    $mw = Get-ChartModel $limits $hist $false $Now
    Eq (($mw.Points | ForEach-Object { $_[1] }) -join ',') '0,5,9' 'точки недели:'

    # 60% за 2 часа -> 100% через 80 минут, до сброса 3 часа
    $l2 = @{ Five = @{ Used = 60.0; Reset = ($Now + 3 * 3600) } }
    $m2 = Get-ChartModel $l2 @() $true $Now
    Ok ([math]::Abs($m2.RunOut - ($Now + 4800)) -le 1) "прогноз через 80 мин (получено $($m2.RunOut - $Now) с)"
    Ok ($null -eq (Get-ChartModel @{ Five = @{ Used = 10; Reset = ($Now - 1) } } @() $true $Now)) 'окно сброшено -> нет графика'
    Ok ($null -eq (Get-ChartModel $null @() $true $Now)) 'нет данных -> нет графика'
}

Test 'settings.json: прописать и убрать statusLine' {
    $d = New-TempDir
    $p = Join-Path $d '.claude/settings.json'
    $cmd = Get-StatusLineCommand 'C:\Users\Иван Петров\AppData\Local\ClaudeLimits'
    Eq $cmd 'powershell -NoProfile -ExecutionPolicy Bypass -File "C:/Users/Иван Петров/AppData/Local/ClaudeLimits/statusline.ps1"' 'команда с / и кавычками:'

    $r = Set-ClaudeStatusLine $p $cmd
    Ok $r.Ok 'создаёт settings.json, если его нет'
    Eq (Get-Content -Raw $p | ConvertFrom-Json).statusLine.command $cmd

    Write-Utf8 $p '{"model":"opus","theme":"dark","permissions":{"allow":["Bash(ls)"]},"statusLine":{"type":"command","command":"~/my.sh"}}'
    $r = Set-ClaudeStatusLine $p $cmd
    Ok $r.Ok 'ok'; Eq $r.Replaced '~/my.sh' 'сообщает о замене чужого:'
    $j = [IO.File]::ReadAllText($p) | ConvertFrom-Json
    Eq $j.model 'opus'; Eq $j.theme 'dark'; Eq $j.permissions.allow[0] 'Bash(ls)' 'вложенные настройки целы:'
    Eq $j.statusLine.type 'command'; Eq $j.statusLine.command $cmd
    Ok (Test-Path "$p.bak") 'есть settings.json.bak'
    $bytes = [IO.File]::ReadAllBytes($p)
    Ok (-not ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB)) 'settings.json без BOM (иначе Claude Code его не прочитает)'

    $r = Set-ClaudeStatusLine $p $cmd
    Ok ($r.Ok -and $null -eq $r.Replaced) 'повторная установка без предупреждения'

    Write-Utf8 $p '{сломано'
    $r = Set-ClaudeStatusLine $p $cmd
    Ok (-not $r.Ok) 'битый JSON — отказ'
    Eq ([IO.File]::ReadAllText($p)) '{сломано' 'битый JSON не перезаписан:'

    Write-Utf8 $p ('{"model":"opus","statusLine":{"type":"command","command":' + (ConvertTo-Json $cmd) + '}}')
    Ok (Remove-ClaudeStatusLine $p) 'свой statusLine удалён'
    $j = [IO.File]::ReadAllText($p) | ConvertFrom-Json
    Ok ($null -eq $j.statusLine -and $j.model -eq 'opus') 'остальное на месте'
    Write-Utf8 $p '{"statusLine":{"type":"command","command":"~/mine.sh"}}'
    Ok (-not (Remove-ClaudeStatusLine $p)) 'чужой statusLine не трогаем'
    Remove-Item -Recurse -Force $d
}

# ============================================================ 3. statusline.ps1
Write-Host '== statusline.ps1 (отдельный процесс)'

function Invoke-StatusLine([string]$Payload, [string]$UserProfile) {
    $old = $env:USERPROFILE; $oldEnc = $OutputEncoding
    try {
        $env:USERPROFILE = $UserProfile
        $global:OutputEncoding = New-Object Text.UTF8Encoding $false   # Claude Code передаёт UTF-8
        $psArgs = @('-NoProfile')
        if ($OnWindows) { $psArgs += @('-ExecutionPolicy', 'Bypass') }
        $psArgs += @('-File', (Join-Path $WinDir 'statusline.ps1'))
        $out = $Payload | & $PsExe @psArgs
        return @{ Out = ($out -join "`n").Trim(); Code = $LASTEXITCODE }
    } finally { $env:USERPROFILE = $old; $global:OutputEncoding = $oldEnc }
}

Test 'statusline.ps1: запись данных, история, устойчивость' {
    $d = New-TempDir
    $limits = Join-Path $d '.claude/limits.json'
    $hist = Join-Path $d '.claude/limits-history.jsonl'
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $p = { param($f, $w) '{"model":{"display_name":"Опус"},"rate_limits":{"five_hour":{"used_percentage":' + $f + ',"resets_at":' + ($now + 3600) + '},"seven_day":{"used_percentage":' + $w + ',"resets_at":' + ($now + 90000) + '}}}' }

    $r = Invoke-StatusLine (& $p 23.5 41) $d
    Eq $r.Code 0 'код выхода:'
    Ok ($r.Out -like '*5h: 24% 7d: 41%') "строка статуса: $($r.Out)"
    $j = [IO.File]::ReadAllText($limits, [Text.Encoding]::UTF8) | ConvertFrom-Json
    Eq $j.rate_limits.five_hour.used_percentage 23.5 'limits.json:'
    Eq $j.model 'Опус' 'кириллица в UTF-8 сохраняется:'
    Ok ([math]::Abs($j.updated_at - $now) -lt 120) 'updated_at = сейчас (UTC)'
    Eq @([IO.File]::ReadAllLines($hist)).Count 1 'первая строка истории:'

    [void](Invoke-StatusLine (& $p 23.5 41) $d)
    Eq @([IO.File]::ReadAllLines($hist)).Count 1 'без изменений — без новой строки:'
    [void](Invoke-StatusLine (& $p 30 42) $d)
    Eq @([IO.File]::ReadAllLines($hist)).Count 2 'изменение записано:'
    Ok (([IO.File]::ReadAllLines($hist))[1] -like '*"f":30*') 'новое значение в истории'

    $before = [IO.File]::ReadAllText($limits)
    $r = Invoke-StatusLine '{"model":{"display_name":"Opus"}}' $d
    Eq $r.Out '[Opus]' 'без rate_limits:'
    Eq ([IO.File]::ReadAllText($limits)) $before 'без rate_limits limits.json не трогается:'
    $r = Invoke-StatusLine 'не json' $d
    Ok ($r.Out -eq '[Claude]' -and $r.Code -eq 0) "битый ввод: $($r.Out) / $($r.Code)"

    # очистка истории > 512 КБ
    $old = $now - 20 * 86400
    $line = '{"t":' + $old + ',"f":1,"fr":1,"w":1,"wr":1}'
    [IO.File]::WriteAllText($hist, (($line + "`n") * 15000), (New-Object Text.UTF8Encoding $false))
    [void](Invoke-StatusLine (& $p 70 80) $d)
    $lines = @([IO.File]::ReadAllLines($hist) | Where-Object { $_ })
    Ok ($lines.Count -eq 1 -and $lines[0] -like '*"f":70*') "старая история очищена (строк: $($lines.Count))"
    Remove-Item -Recurse -Force $d
}

# ============================================================ 4. Только Windows
if ($OnWindows) {
    Write-Host '== Установка / значок / удаление (Windows)'
    # В Windows PowerShell 5.1 «2>&1» у внешних программ при Stop превращается в исключение — здесь проверяем коды выхода сами
    $ErrorActionPreference = 'Continue'
    $sb = New-TempDir
    $saved = @{ USERPROFILE = $env:USERPROFILE; LOCALAPPDATA = $env:LOCALAPPDATA }
    $env:USERPROFILE = $sb
    $env:LOCALAPPDATA = Join-Path $sb 'AppData\Local'
    $env:CLAUDE_LIMITS_NO_LAUNCH = '1'
    $env:CLAUDE_LIMITS_STARTUP_DIR = Join-Path $sb 'Startup'
    $inst = Join-Path $env:LOCALAPPDATA 'ClaudeLimits'
    $settings = Join-Path $sb '.claude/settings.json'
    $winPS = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
    try {
        Test 'install.ps1 из папки проекта' {
            Write-Utf8 $settings '{"model":"opus","statusLine":{"type":"command","command":"~/old.sh"}}'
            $out = & $PsExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $WinDir 'install.ps1') 2>&1
            Eq $LASTEXITCODE 0 "код выхода ($($out -join ' | ')):"
            foreach ($f in @('ClaudeLimits.Core.ps1', 'ClaudeLimits.ps1', 'statusline.ps1', 'uninstall.ps1')) {
                Ok (Test-Path (Join-Path $inst $f)) "установлен $f"
            }
            $j = [IO.File]::ReadAllText($settings) | ConvertFrom-Json
            Eq $j.statusLine.command (Get-StatusLineCommand $inst) 'statusLine:'
            Eq $j.model 'opus' 'остальные настройки:'
            Ok (Test-Path (Join-Path $env:CLAUDE_LIMITS_STARTUP_DIR 'ClaudeLimits.lnk')) 'ярлык автозапуска создан'
            $lnk = (New-Object -ComObject WScript.Shell).CreateShortcut((Join-Path $env:CLAUDE_LIMITS_STARTUP_DIR 'ClaudeLimits.lnk'))
            Ok ($lnk.Arguments -like "*$inst\ClaudeLimits.ps1*") "ярлык указывает на значок: $($lnk.Arguments)"
        }

        $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        $payload = '{"model":{"display_name":"Opus"},"rate_limits":{"five_hour":{"used_percentage":55,"resets_at":' + ($now + 7200) + '},"seven_day":{"used_percentage":30,"resets_at":' + ($now + 300000) + '}}}'

        Test 'команда из settings.json работает через cmd (как Claude Code без Git Bash)' {
            $cmd = ([IO.File]::ReadAllText($settings) | ConvertFrom-Json).statusLine.command
            $bat = Join-Path $sb 'run-statusline.cmd'
            [IO.File]::WriteAllText($bat, "@$cmd`r`n", [Text.Encoding]::ASCII)
            $out = $payload | cmd /c $bat
            Ok (($out -join '') -like '*5h: 55% 7d: 30%') "вывод: $out"
        }

        $gitBash = @("$env:ProgramFiles\Git\bin\bash.exe", "${env:ProgramFiles(x86)}\Git\bin\bash.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
        if ($gitBash) {
            Test 'команда из settings.json работает через Git Bash (как Claude Code с Git Bash)' {
                $cmd = ([IO.File]::ReadAllText($settings) | ConvertFrom-Json).statusLine.command
                $sh = Join-Path $sb 'run-statusline.sh'
                [IO.File]::WriteAllText($sh, "$cmd`n", (New-Object Text.UTF8Encoding $false))
                $out = $payload | & $gitBash ($sh -replace '\\', '/')
                Ok (($out -join '') -like '*5h: 55% 7d: 30%') "вывод: $out"
            }
        } else { Write-Host '   (Git Bash не найден — пропуск)' }

        Test 'значок в трее: самопроверка в Windows PowerShell 5.1 (с данными)' {
            $h = Join-Path $sb '.claude/limits-history.jsonl'
            Write-Utf8 $h ('{"t":' + ($now - 3600) + ',"f":20,"w":25}' + "`n" + '{"t":' + ($now - 600) + ',"f":50,"w":29}' + "`n")
            $env:CLAUDE_LIMITS_SELFTEST = '1'
            $env:CLAUDE_LIMITS_SELFTEST_OUT = $sb
            $out = & $winPS -NoProfile -ExecutionPolicy Bypass -File (Join-Path $inst 'ClaudeLimits.ps1') 2>&1
            $code = $LASTEXITCODE
            Remove-Item Env:\CLAUDE_LIMITS_SELFTEST, Env:\CLAUDE_LIMITS_SELFTEST_OUT
            Ok ($code -eq 0 -and ($out -join ' ') -like '*SELFTEST OK*') "вывод: $($out -join ' | ')"
            Ok ((Test-Path (Join-Path $sb 'chart-five.png')) -and (Get-Item (Join-Path $sb 'chart-five.png')).Length -gt 2000) 'график 5ч нарисован'
            Ok ((Test-Path (Join-Path $sb 'chart-week.png')) -and (Get-Item (Join-Path $sb 'chart-week.png')).Length -gt 2000) 'график недели нарисован'
            Write-Host "   $($out -join ' ')"
        }

        Test 'значок в трее: самопроверка без данных' {
            Remove-Item (Join-Path $sb '.claude/limits.json'), (Join-Path $sb '.claude/limits-history.jsonl') -ErrorAction SilentlyContinue
            $env:CLAUDE_LIMITS_SELFTEST = '1'
            $out = & $winPS -NoProfile -ExecutionPolicy Bypass -File (Join-Path $inst 'ClaudeLimits.ps1') 2>&1
            $code = $LASTEXITCODE
            Remove-Item Env:\CLAUDE_LIMITS_SELFTEST
            Ok ($code -eq 0 -and ($out -join ' ') -like '*SELFTEST OK*') "вывод: $($out -join ' | ')"
        }

        Test 'установка «одной командой» (файлы скачиваются по HTTP)' {
            $py = Get-Command python -ErrorAction SilentlyContinue
            if (-not $py) { Write-Host '   (python не найден — пропуск)'; return }
            $port = 8765
            $srv = Start-Process -FilePath $py.Source -ArgumentList @('-m', 'http.server', $port, '--bind', '127.0.0.1') -WorkingDirectory $Repo -PassThru -WindowStyle Hidden
            try {
                Start-Sleep -Seconds 2
                $lone = New-TempDir
                Copy-Item (Join-Path $WinDir 'install.ps1') $lone
                Remove-Item -Recurse -Force $inst
                $env:CLAUDE_LIMITS_REPO_RAW = "http://127.0.0.1:$port"
                $out = & $PsExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $lone 'install.ps1') 2>&1
                Remove-Item Env:\CLAUDE_LIMITS_REPO_RAW
                Eq $LASTEXITCODE 0 "код выхода ($($out -join ' | ')):"
                Ok (($out -join ' ') -like '*скачиваю ClaudeLimits.Core.ps1*') 'файлы скачаны'
                $bytes = [IO.File]::ReadAllBytes((Join-Path $inst 'ClaudeLimits.ps1'))
                Ok ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB) 'скачанный скрипт сохранил BOM'
                Remove-Item -Recurse -Force $lone
            } finally { Stop-Process -Id $srv.Id -Force -ErrorAction SilentlyContinue }
        }

        Test 'uninstall.ps1' {
            Write-Utf8 (Join-Path $sb '.claude/limits.json') '{}'
            & $PsExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $inst 'uninstall.ps1') | Out-Null
            Ok (-not (Test-Path $inst)) 'папка программы удалена'
            Ok (-not (Test-Path (Join-Path $env:CLAUDE_LIMITS_STARTUP_DIR 'ClaudeLimits.lnk'))) 'автозапуск удалён'
            Ok (-not (Test-Path (Join-Path $sb '.claude/limits.json'))) 'данные удалены'
            $j = [IO.File]::ReadAllText($settings) | ConvertFrom-Json
            Ok ($null -eq $j.statusLine -and $j.model -eq 'opus') 'statusLine убран, настройки целы'
        }
    } finally {
        $env:USERPROFILE = $saved.USERPROFILE; $env:LOCALAPPDATA = $saved.LOCALAPPDATA
        Remove-Item Env:\CLAUDE_LIMITS_NO_LAUNCH, Env:\CLAUDE_LIMITS_STARTUP_DIR -ErrorAction SilentlyContinue
        Remove-Item -Recurse -Force $sb -ErrorAction SilentlyContinue
    }
} else {
    Write-Host '== Установка / значок / удаление: пропущено (нужна Windows; выполняется в GitHub Actions)'
}

# ============================================================ Итог
Write-Host ''
if ($script:Fail.Count -eq 0) {
    Write-Host "✅ Windows tests: все $($script:Pass) проверок прошли" -ForegroundColor Green
    exit 0
}
foreach ($f in $script:Fail) { Write-Host "❌ $f" -ForegroundColor Red }
Write-Host "Windows tests: $($script:Fail.Count) провалено, $($script:Pass) прошло" -ForegroundColor Red
exit 1
