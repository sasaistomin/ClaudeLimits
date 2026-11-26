# Тесты Windows-версии ClaudeLimits.
# Запуск:  powershell -NoProfile -ExecutionPolicy Bypass -File tests\windows\run-tests.ps1
#          (или pwsh -File tests/windows/run-tests.ps1 — на macOS/Linux выполнится всё, кроме Windows-only части)
#
# Части:
#   1. Файлы: кодировка UTF-8 с BOM (нужна Windows PowerShell 5.1 для кириллицы), синтаксис, полнота переводов
#   2. Юнит-тесты логики (Core), парсеров Claude Code / Claude Desktop (поддельные LevelDB-логи) и фонового опроса
#   3. statusline.ps1 как отдельный процесс (так его запускает Claude Code)
#   4. Только Windows: настоящая установка в изолированные папки, команда из settings.json через cmd и Git Bash,
#      установка «одной командой» со скачиванием, самопроверка значка в трее (WinForms + график), удаление

$ErrorActionPreference = 'Stop'
$Repo = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$WinDir = Join-Path $Repo 'windows'
$OnWindows = $env:OS -eq 'Windows_NT'
$PsExe = (Get-Process -Id $PID).Path

. (Join-Path $WinDir 'ClaudeLimits.Core.ps1')
. (Join-Path $WinDir 'ClaudeLimits.Parsers.ps1')
. (Join-Path $WinDir 'ClaudeLimits.Monitoring.ps1')

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
    $c = Read-Config $p
    Eq $c.active_tab 0 'вкладка по умолчанию:'; Eq $c.desktop_path '' 'папка Desktop по умолчанию:'
    $c.active_tab = 1; $c.desktop_path = 'D:\Claude'
    Save-Config $c $p
    $c2 = Read-Config $p
    Eq $c2.active_tab 1 'вкладка сохраняется:'; Eq $c2.desktop_path 'D:\Claude' 'папка Desktop сохраняется:'
    Write-Utf8 $p '{"active_tab":7,"desktop_path":5}'
    $c3 = Read-Config $p
    Ok ($c3.active_tab -eq 0 -and $c3.desktop_path -eq '') 'мусорные active_tab / desktop_path игнорируются'
    Remove-Item -Recurse -Force $d
}

Test 'ClaudeCodeParser (limits.json)' {
    $d = New-TempDir
    $p = Join-Path $d 'limits.json'
    $parser = [ClaudeCodeParser]::new($p)
    Eq $parser.GetLogPath() $p 'GetLogPath:'
    Ok (-not $parser.IsInstalled()) 'нет файла -> IsInstalled = false'
    Eq $parser.ParseAt($Now).Status 'NoData' 'нет файла:'
    Eq ([ClaudeCodeParser]::new((Join-Path $d 'нет/limits.json'))).ParseAt($Now).Status 'NotFound' 'нет папки:'
    Write-Utf8 $p ('{"updated_at":' + $Now + ',"model":"Opus","rate_limits":{"five_hour":{"used_percentage":23.5,"resets_at":' + ($Now + 3600) + '},"seven_day":{"used_percentage":90,"resets_at":' + ($Now - 10) + '}}}')
    $m = $parser.ParseAt($Now)
    Eq $m.Status 'Ok'; Eq $m.Source 'code'; Eq $m.Updated $Now
    $five = Get-MetricsWindow $m 'five_hour'; $week = Get-MetricsWindow $m 'seven_day'
    Eq $five.Used 23.5; Eq $five.Left 76.5; Eq $five.Reset ($Now + 3600); Ok (-not $five.Rolling) 'окно Code не скользящее'
    Eq $week.Used 0 'сброшенное окно = 0%:'; Eq $week.RawUsed 90 'RawUsed сохраняется:'
    Write-Utf8 $p '{"updated_at":1,"rate_limits":{"seven_day":{"used_percentage":5,"resets_at":9999999999}}}'
    $m = $parser.ParseAt($Now)
    Ok ($null -eq (Get-MetricsWindow $m 'five_hour') -and (Get-MetricsWindow $m 'seven_day').Used -eq 5) 'только недельное окно'
    Ok ($parser.GetResetTime() -is [datetime]) 'GetResetTime -> DateTime'
    Write-Utf8 $p 'не json'
    Eq $parser.ParseAt($Now).Status 'NoData' 'битый файл:'
    Remove-Item -Recurse -Force $d
}

Test 'Get-TrayTooltip: оба источника, не длиннее 63 символов' {
    $code = @{ Source = 'code'; Status = 'Ok'; Windows = @(@{ Id = 'five_hour'; Left = 86.4 }, @{ Id = 'seven_day'; Left = 49 }) }
    $desk = @{ Source = 'desktop'; Status = 'Ok'; Windows = @(@{ Id = 'five_hour'; Left = 82; Rolling = $true }) }
    Eq (Get-TrayTooltip @($code, $null) $ru) 'Code: 5ч 86% · неделя 49%'
    Eq (Get-TrayTooltip @($code, $desk) $en) 'Code: 5h 86% · week 49% | Desktop: 5h 82%'
    Eq (Get-TrayTooltip @($null, @{ Source = 'desktop'; Status = 'NotFound' }) $ru) $ru.TipNoData 'без данных:'
    foreach ($T in @($ru, $en)) {
        Ok ((Get-TrayTooltip @() $T).Length -le 63) 'без данных <= 63'
        Ok ((Get-TrayTooltip @($code, $desk) $T).Length -le 63) 'с данными <= 63'
    }
}

Test 'Карточки: окна Code и скользящее окно Desktop, пустые состояния' {
    $l = Format-WindowLines @{ Id = 'five_hour'; Used = 14; Left = 86; Reset = ($Now + 3600) } $ru $Now
    Eq $l[0] '5 часов: осталось 86%  (использовано 14%)'
    Eq $l[1] '      сброс через 1 ч 0 мин'
    $reset = $Now + 2 * 3600 + 600
    $l = Format-WindowLines @{ Id = 'five_hour'; Used = 18; Left = 82; Reset = $reset; Rolling = $true } $en $Now
    Eq $l[0] '5-hour window (rolling): 82% left  (18% used)'
    Eq $l[1] ('      resets at {0} (in 2h 10m)' -f (ConvertTo-LocalTime $reset).ToString('HH:mm'))
    Eq (Get-EmptyStateLines 'desktop' $null $ru)[0] $ru.Loading 'ещё нет снимка:'
    Eq (Get-EmptyStateLines 'desktop' @{ Status = 'NotFound' } $ru)[0] 'Claude Desktop: не подключено'
    Eq (Get-EmptyStateLines 'desktop' @{ Status = 'NoData' } $en)[1] 'Send a message in Claude Desktop.'
    Eq (Get-EmptyStateLines 'code' @{ Status = 'NoData' } $ru)[0] $ru.NoDataLong 'Code без данных — как раньше:'
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

Test 'Get-NotifyEvent: скользящее окно Desktop — порог 100% и отдельный ключ' {
    $n = @{}
    $w = @{ Id = 'five_hour'; RawUsed = 100; Reset = ($Now + 3600); Rolling = $true }
    Eq (Get-NotifyKey 'desktop' $w) 'desktop:five_hour'
    Eq (Get-NotifyKey 'code' $w) 'five_hour' 'ключ Code не изменился (совместимость с config.json):'
    $e = Get-NotifyEvent (Get-NotifyKey 'desktop' $w) $w $n $Now (Get-NotifyThresholds $w)
    Ok ($e.Threshold -eq 100) 'исчерпано -> порог 100'
    Ok ($n.ContainsKey('desktop:five_hour:80') -and $n.ContainsKey('desktop:five_hour:95')) 'нижние пороги помечены'
    Ok (-not $n.ContainsKey('five_hour:80')) 'Code не затронут'
}

Test 'Format-Notification: источник в заголовке' {
    $w = @{ Id = 'five_hour'; RawUsed = 81; Reset = ($Now + 3600) }
    $m = Format-Notification @{ Type = 'low'; Threshold = 80; Used = 81 } $w 'code' $ru $Now
    Eq $m.Title '[Claude Code] Осталось 19%'
    Eq $m.Body '5-часовое окно израсходовано на 81%. Сброс через 1 ч 0 мин.'
    Eq $m.Icon 'Info'
    $ww = @{ Id = 'seven_day'; RawUsed = 97; Reset = ($Now + 3600) }
    $m = Format-Notification @{ Type = 'low'; Threshold = 95; Used = 97 } $ww 'code' $en $Now
    Eq $m.Title '[Claude Code] 3% left'; Eq $m.Icon 'Warning'
    Ok ($m.Body -like 'Weekly limit is 97% used*') 'тело на английском'
    $m = Format-Notification @{ Type = 'reset' } $ww 'code' $ru $Now
    Eq $m.Title '[Claude Code] Лимит сброшен'; Ok ($m.Body -like 'Недельный*') 'сброс недели'

    $reset = $Now + 5400
    $at = (ConvertTo-LocalTime $reset).ToString('HH:mm')
    $wd = @{ Id = 'five_hour'; RawUsed = 100; Reset = $reset; Rolling = $true }
    $m = Format-Notification @{ Type = 'low'; Threshold = 100; Used = 100 } $wd 'desktop' $ru $Now
    Eq $m.Title '[Claude Desktop] Осталось 0%'
    Eq $m.Body "5-часовое окно сообщений исчерпано. Сброс в $at."
    $m = Format-Notification @{ Type = 'low'; Threshold = 80; Used = 84 } $wd 'desktop' $en $Now
    Eq $m.Body "5-hour message window is 84% used. Resets at $at."
    $m = Format-Notification @{ Type = 'reset' } $wd 'desktop' $ru $Now
    Eq $m.Title '[Claude Desktop] Лимит сброшен'
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
    $five = @{ Id = 'five_hour'; Used = 40.0; Reset = ($Now + 3600) }
    $week = @{ Id = 'seven_day'; Used = 9.0; Reset = ($Now + 86400) }
    $hist = @(
        [pscustomobject]@{ t = ($start - 100); f = 99 },
        [pscustomobject]@{ t = ($start + 600); f = 10; w = 5 },
        [pscustomobject]@{ t = ($start + 7200); f = 25 },
        [pscustomobject]@{ t = ($Now + 100); f = 77 }
    )
    $m = Get-ChartModel $five $hist $Now
    Eq (($m.Points | ForEach-Object { $_[1] }) -join ',') '0,10,25,40' 'точки 5ч:'
    Eq $m.Start $start; Eq $m.End ($Now + 3600)
    Ok ($null -eq $m.RunOut) '40% за 4ч, остался 1ч — хватит'
    $mw = Get-ChartModel $week $hist $Now
    Eq (($mw.Points | ForEach-Object { $_[1] }) -join ',') '0,5,9' 'точки недели:'

    # 60% за 2 часа -> 100% через 80 минут, до сброса 3 часа
    $m2 = Get-ChartModel @{ Id = 'five_hour'; Used = 60.0; Reset = ($Now + 3 * 3600) } @() $Now
    Ok ([math]::Abs($m2.RunOut - ($Now + 4800)) -le 1) "прогноз через 80 мин (получено $($m2.RunOut - $Now) с)"
    Ok ($null -eq (Get-ChartModel @{ Id = 'five_hour'; Used = 10; Reset = ($Now - 1) } @() $Now)) 'окно сброшено -> нет графика'
    Ok ($null -eq (Get-ChartModel $null @() $Now)) 'нет данных -> нет графика'
}

Test 'Обновления: сравнение версий, VERSION по URL, команда обновления' {
    Ok (Test-NewerVersion '2.1.0' '2.0.0') '2.1.0 > 2.0.0'
    Ok (Test-NewerVersion '2.0.10' '2.0.9') 'числа, а не строки'
    Ok (Test-NewerVersion 'v3' '2.9.9') 'префикс v'
    Ok (Test-NewerVersion "2.0.0`n" '0.0.0') 'перевод строки, версия не была известна'
    Ok (-not (Test-NewerVersion '2.0.0' '2.0.0')) 'та же версия'
    Ok (-not (Test-NewerVersion '1.9.0' '2.0.0')) 'старая версия на сервере — не откатываемся'
    Ok (-not (Test-NewerVersion '' '2.0.0')) 'пустой файл'
    Ok (-not (Test-NewerVersion '<html>404</html>' '0.0.0')) 'страница ошибки'
    Eq ((Get-VersionParts '2.10.1-beta') -join '.') '2.10.1'
    $d = New-TempDir
    Eq (Get-InstalledVersion $d) '0.0.0' 'нет файла:'
    Write-Utf8 (Join-Path $d 'VERSION') "2.0.0`n"
    Eq (Get-InstalledVersion $d) '2.0.0'
    $fileUrl = { param($path) if ($OnWindows) { ([Uri]$path).AbsoluteUri } else { 'file://' + $path } }
    Eq (Get-RemoteVersion (& $fileUrl (Join-Path $d 'VERSION'))) '2.0.0' 'VERSION по file://:'
    $failed = $false
    try { [void](Get-RemoteVersion (& $fileUrl (Join-Path $d 'нет'))) } catch { $failed = $true }
    Ok $failed 'недоступный адрес -> ошибка, а не обновление'
    $a = Get-UpdateArguments 'https://example.test/repo'
    Ok ($a -like '*https://example.test/repo/windows/install.ps1*' -and $a -like '*-ExecutionPolicy Bypass*') "команда обновления: $a"
    $tokens = $null; $errors = $null
    $inner = ($a -replace '^.*-Command "', '' -replace '"$', '') -replace '\\"', '"'
    [void][System.Management.Automation.Language.Parser]::ParseInput($inner, [ref]$tokens, [ref]$errors)
    Eq $errors.Count 0 "команда обновления без синтаксических ошибок ($inner):"
    Remove-Item -Recurse -Force $d
}

Test 'settings.json: прописать и убрать statusLine' {
    $d = New-TempDir
    $p = Join-Path $d '.claude/settings.json'
    $cmd = Get-StatusLineCommand 'C:\Users\Иван Петров\AppData\Local\ClaudeLimits'
    Eq $cmd 'powershell -NoProfile -ExecutionPolicy Bypass -File "C:/Users/Иван Петров/AppData/Local/ClaudeLimits/statusline.ps1"' 'команда с / и кавычками:'

    $r = Set-ClaudeStatusLine $p $cmd
    Ok $r.Ok 'создаёт settings.json, если его нет'
    Eq ([IO.File]::ReadAllText($p) | ConvertFrom-Json).statusLine.command $cmd 'команда в settings.json:'

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

# ============================================================ 2б. Claude Desktop (поддельные LevelDB-логи)
Write-Host '== ClaudeDesktopParser'

$Latin1 = [Text.Encoding]::GetEncoding(28591)
function New-DesktopRecord([double]$Util, [int64]$Reset, [double]$Observed, [bool]$AtWall = $false) {
    $inv = [Globalization.CultureInfo]::InvariantCulture
    '{{"resetsAt":{0},"utilization":{1},"prevUtilization":0.1,"observedAt":{2},"atWall":{3},"fired":[],"shown":false}}' -f $Reset, $Util.ToString($inv), $Observed.ToString($inv), $AtWall.ToString().ToLower()
}
function New-FakeDesktop {
    $root = New-TempDir
    $db = [IO.Path]::Combine($root, 'Local Storage', 'leveldb')
    New-Item -ItemType Directory -Force -Path $db | Out-Null
    [IO.File]::WriteAllText((Join-Path $db 'CURRENT'), "MANIFEST-000001`n")
    return @{ Root = $root; Db = $db }
}
function Add-JournalRecord([string]$Path, [string]$Json) {
    [byte[]]$bytes = [byte[]](0x9a, 0x01, 0x00, 0x00, 0x01) + $Latin1.GetBytes('_https://claude.ai') + [byte[]](0x00, 0x01) + $Latin1.GetBytes('ochre.test') + [byte[]](0x8f, 0x01) + $Latin1.GetBytes($Json) + [byte[]](0x00, 0x7b, 0xff)
    $fs = [IO.File]::Open($Path, 'Append', 'Write', 'ReadWrite')
    try { $fs.Write($bytes, 0, $bytes.Length) } finally { $fs.Dispose() }
}
function ConvertTo-Varint([int64]$v) {
    $out = New-Object System.Collections.Generic.List[byte]
    do { $b = [byte]($v -band 0x7f); $v = $v -shr 7; if ($v -gt 0) { $b = $b -bor 0x80 }; $out.Add($b) } while ($v -gt 0)
    return , $out.ToArray()
}
function New-BlockBytes([byte[]]$Key, [byte[]]$Value) {
    $b = New-Object System.Collections.Generic.List[byte]
    $b.AddRange((ConvertTo-Varint 0)); $b.AddRange((ConvertTo-Varint $Key.Length)); $b.AddRange((ConvertTo-Varint $Value.Length))
    $b.AddRange($Key); $b.AddRange($Value)
    $b.AddRange([BitConverter]::GetBytes([int32]0)); $b.AddRange([BitConverter]::GetBytes([int32]1))
    return , $b.ToArray()
}
# Snappy: литерал до 60 байт, затем копирование всего литерала со смещением = его длине
function ConvertTo-SnappyRepeat([byte[]]$Chunk, [int]$Times) {
    $b = New-Object System.Collections.Generic.List[byte]
    $b.AddRange((ConvertTo-Varint ($Chunk.Length * $Times)))
    $b.Add([byte](($Chunk.Length - 1) -shl 2)); $b.AddRange($Chunk)
    for ($i = 1; $i -lt $Times; $i++) { $b.Add([byte]((($Chunk.Length - 1) -shl 2) -bor 2)); $b.Add([byte]$Chunk.Length); $b.Add(0) }
    return , $b.ToArray()
}
# SSTable: один блок данных (сжатый Snappy или нет), индекс, footer с magic
function New-FakeTable([string]$Path, [string]$Json, [bool]$Compress) {
    $data = New-BlockBytes $Latin1.GetBytes('_https://claude.ai.ochre.test') ([byte[]](0x01) + $Latin1.GetBytes($Json))
    if ($Compress) {
        $s = New-Object System.Collections.Generic.List[byte]
        $s.AddRange((ConvertTo-Varint $data.Length))
        $i = 0
        while ($i -lt $data.Length) {
            $n = [math]::Min(60, $data.Length - $i)
            $s.Add([byte](($n - 1) -shl 2)); $s.AddRange([byte[]]$data[$i..($i + $n - 1)])
            $i += $n
        }
        $block = $s.ToArray(); $type = 1
    } else { $block = $data; $type = 0 }
    $file = New-Object System.Collections.Generic.List[byte]
    $file.AddRange([byte[]]$block); $file.Add([byte]$type); $file.AddRange([byte[]](0, 0, 0, 0))
    $handle = [byte[]]((ConvertTo-Varint 0) + (ConvertTo-Varint $block.Length))
    $indexOffset = $file.Count
    $index = New-BlockBytes $Latin1.GetBytes('z') $handle
    $file.AddRange($index); $file.Add(0); $file.AddRange([byte[]](0, 0, 0, 0))
    $footer = New-Object System.Collections.Generic.List[byte]
    $footer.AddRange((ConvertTo-Varint $indexOffset)); $footer.AddRange((ConvertTo-Varint 0))
    $footer.AddRange((ConvertTo-Varint $indexOffset)); $footer.AddRange((ConvertTo-Varint ($index.Length)))
    while ($footer.Count -lt 40) { $footer.Add(0) }
    $footer.AddRange([byte[]](0x57, 0xfb, 0x80, 0x8b, 0x24, 0x75, 0x47, 0xdb))
    $file.AddRange($footer)
    [IO.File]::WriteAllBytes($Path, $file.ToArray())
}

Test 'Snappy: литералы и копирование с перекрытием' {
    $ldb = 'ClaudeLimits.LevelDb' -as [type]
    $out = $ldb::Snappy([byte[]](0x0C, 0x0C, 0x61, 0x62, 0x63, 0x64, 0x11, 0x04))
    Eq $Latin1.GetString($out) 'abcdabcdabcd'
    Eq $Latin1.GetString($ldb::Snappy((ConvertTo-SnappyRepeat $Latin1.GetBytes('xyz') 4))) 'xyzxyzxyzxyz' 'копирование 2-байтовым смещением:'
    $bad = $false
    try { [void]$ldb::Snappy([byte[]](0x0C, 0x11, 0x04)) } catch { $bad = $true }
    Ok $bad 'битый поток -> исключение, а не мусор'
}

Test 'ClaudeDesktopParser: не установлен / пустая база' {
    $missing = Join-Path ([IO.Path]::GetTempPath()) ('cl-none-' + [guid]::NewGuid().ToString('N'))
    $p = [ClaudeDesktopParser]::new($missing)
    Eq $p.GetLogPath() '' 'GetLogPath:'
    Ok (-not $p.IsInstalled()) 'IsInstalled = false'
    Eq $p.ParseAt($Now).Status 'NotFound'
    Ok ($null -eq $p.GetResetTime()) 'GetResetTime = $null'
    $f = New-FakeDesktop
    $p = [ClaudeDesktopParser]::new($f.Root)
    Ok $p.IsInstalled() 'есть Local Storage/leveldb -> установлен'
    Eq $p.GetLogPath() $f.Db 'путь к leveldb из корня Claude:'
    Eq ([ClaudeDesktopParser]::new($f.Db)).GetLogPath() $f.Db 'путь прямо на папку leveldb:'
    Eq $p.ParseAt($Now).Status 'NoData' 'база без записи о лимитах:'
    Remove-Item -Recurse -Force $f.Root
}

Test 'ClaudeDesktopParser: журнал .log — проценты, время сброса, самая свежая запись' {
    $f = New-FakeDesktop
    $log = Join-Path $f.Db '000003.log'
    Add-JournalRecord $log (New-DesktopRecord 0.35 ($Now + 600) ($Now - 7200))
    Add-JournalRecord $log (New-DesktopRecord 0.18 ($Now + 3 * 3600) ($Now - 60))
    Add-JournalRecord $log (New-DesktopRecord 0.9 ($Now + 3 * 3600) ($Now - 3600))
    $p = [ClaudeDesktopParser]::new($f.Root)
    $m = $p.ParseAt($Now)
    Eq $m.Status 'Ok'; Eq $m.Source 'desktop'; Eq $m.LogPath $f.Db
    Eq $m.Windows.Count 1 'одно окно:'
    $w = $m.Windows[0]
    Eq $w.Id 'five_hour'; Ok $w.Rolling 'окно скользящее'
    Ok ([math]::Abs($w.Used - 18) -lt 1e-9) "по observedAt выбрана самая свежая запись (получено $($w.Used))"
    Ok ([math]::Abs($w.Left - 82) -lt 1e-9) 'осталось 82%'
    Eq $w.Reset ($Now + 3 * 3600) 'время сброса:'
    Eq $m.Updated ($Now - 60) 'Updated = observedAt:'
    Eq $p.ParseAt($Now + 3 * 3600 + 1).Windows[0].Used 0 'после resetsAt окно обнулено:'
    Remove-Item -Recurse -Force $f.Root
}

Test 'ClaudeDesktopParser: дочитывание с offset, обрыв записи, atWall, мусор' {
    $f = New-FakeDesktop
    $log = Join-Path $f.Db '000005.log'
    Add-JournalRecord $log (New-DesktopRecord 0.2 ($Now + 3600) ($Now - 300))
    $p = [ClaudeDesktopParser]::new($f.Root)
    Ok ([math]::Abs($p.ParseAt($Now).Windows[0].Used - 20) -lt 1e-9) 'первое чтение'
    $key = (Get-Item -LiteralPath $log).FullName
    $offset = $p.Journals[$key].Offset
    Eq $offset (Get-Item $log).Length 'offset = размер файла:'

    $rec = New-DesktopRecord 0.55 ($Now + 3600) ($Now - 100)
    $half = [int]($rec.Length / 2)
    $fs = [IO.File]::Open($log, 'Append', 'Write', 'ReadWrite')
    try { $b = $Latin1.GetBytes($rec.Substring(0, $half)); $fs.Write($b, 0, $b.Length) } finally { $fs.Dispose() }
    Ok ([math]::Abs($p.ParseAt($Now).Windows[0].Used - 20) -lt 1e-9) 'недописанная запись не ломает результат'
    $fs = [IO.File]::Open($log, 'Append', 'Write', 'ReadWrite')
    try { $b = $Latin1.GetBytes($rec.Substring($half)); $fs.Write($b, 0, $b.Length) } finally { $fs.Dispose() }
    Ok ([math]::Abs($p.ParseAt($Now).Windows[0].Used - 55) -lt 1e-9) 'дописанная запись собрана из хвоста'
    Ok ($p.Journals[$key].Offset -gt $offset) 'offset сдвинулся, файл не перечитывается с нуля'

    Add-JournalRecord $log '{"resetsAt":"сломано","utilization":}{"resetsAt":1,"observedAt":2}{{{'
    Add-JournalRecord $log (New-DesktopRecord 0.97 ($Now + 1800) ($Now - 10) $true)
    $w = $p.ParseAt($Now).Windows[0]
    Ok ($w.Used -eq 100 -and $w.Left -eq 0) "atWall = окно исчерпано (получено $($w.Used))"
    Eq $w.Reset ($Now + 1800)

    [IO.File]::WriteAllBytes($log, [byte[]](1, 2, 3))
    Eq $p.ParseAt($Now).Status 'NoData' 'журнал пересоздан (стал короче) -> читается заново:'
    Remove-Item -Recurse -Force $f.Root
}

Test 'ClaudeDesktopParser: чтение при открытом на запись журнале (FileShare.ReadWrite)' {
    $f = New-FakeDesktop
    $log = Join-Path $f.Db '000007.log'
    $writer = New-Object IO.FileStream($log, 'Create', 'Write', 'ReadWrite')
    try {
        $b = $Latin1.GetBytes((New-DesktopRecord 0.42 ($Now + 3600) ($Now - 5)))
        $writer.Write($b, 0, $b.Length); $writer.Flush()
        $m = ([ClaudeDesktopParser]::new($f.Root)).ParseAt($Now)
        Ok ($m.Status -eq 'Ok' -and [math]::Abs($m.Windows[0].Used - 42) -lt 1e-9) "прочитано, пока файл открыт Claude Desktop ($($m.Status))"
    } finally { $writer.Dispose() }
    Remove-Item -Recurse -Force $f.Root
}

Test 'ClaudeDesktopParser: таблицы .ldb (Snappy и без сжатия), кэш, битые файлы' {
    $f = New-FakeDesktop
    New-FakeTable (Join-Path $f.Db '000010.ldb') (New-DesktopRecord 0.31 ($Now + 7200) ($Now - 900)) $true
    $ldb = 'ClaudeLimits.LevelDb' -as [type]
    Ok ($ldb::ReadTableText((Join-Path $f.Db '000010.ldb')) -like '*"utilization":0.31*') 'блок Snappy распакован'
    $p = [ClaudeDesktopParser]::new($f.Root)
    $m = $p.ParseAt($Now)
    Ok ($m.Status -eq 'Ok' -and [math]::Abs($m.Windows[0].Used - 31) -lt 1e-9) "запись из сжатой таблицы ($($m.Status))"
    Ok $p.Tables.ContainsKey((Get-Item -LiteralPath (Join-Path $f.Db '000010.ldb')).FullName) 'таблица закэширована'

    New-FakeTable (Join-Path $f.Db '000011.ldb') (New-DesktopRecord 0.6 ($Now + 7200) ($Now - 100)) $false
    [IO.File]::WriteAllBytes((Join-Path $f.Db '000012.ldb'), [byte[]](1..200))
    $m = $p.ParseAt($Now)
    Ok ([math]::Abs($m.Windows[0].Used - 60) -lt 1e-9) 'свежая запись из несжатой таблицы, битая таблица пропущена'

    Add-JournalRecord (Join-Path $f.Db '000013.log') (New-DesktopRecord 0.05 ($Now + 7200) ($Now - 5000))
    Ok ([math]::Abs($p.ParseAt($Now).Windows[0].Used - 60) -lt 1e-9) 'старая запись в журнале не перекрывает свежую из таблицы'

    $gone = (Get-Item -LiteralPath (Join-Path $f.Db '000011.ldb')).FullName
    Remove-Item -LiteralPath $gone
    [void]$p.ParseAt($Now)
    Ok (-not $p.Tables.ContainsKey($gone)) 'удалённая (после компакции) таблица убрана из кэша'
    Remove-Item -Recurse -Force $f.Root
}

function ConvertTo-V8String([string]$Text) { [byte[]](@(0x22, $Text.Length) + [byte[]]$Latin1.GetBytes($Text)) }
function ConvertTo-V8Number([double]$X) { [byte[]](@(0x4e) + [BitConverter]::GetBytes($X)) }
function New-V8Window([double]$Util, [double]$Reset) {
    [byte[]](@(0x6f) + (ConvertTo-V8String 'status') + (ConvertTo-V8String 'within_limit') + (ConvertTo-V8String 'resets_at') + (ConvertTo-V8Number $Reset) +
        (ConvertTo-V8String 'utilization') + (ConvertTo-V8Number $Util) + (ConvertTo-V8String 'surpassed_threshold') + @(0x30, 0x7b, 0x04))
}
# Кэш ответа claude.ai в IndexedDB: обёртка Chromium (ff 11 02) + Snappy (литералы) + V8
function New-IdbBlob([string]$Path, [double[]]$Five, [double[]]$Week, [double]$UpdatedMs) {
    $win = [byte[]]@(0x6f)
    if ($Five) { $win += (ConvertTo-V8String '5h') + (New-V8Window $Five[0] $Five[1]) }
    if ($Week) { $win += (ConvertTo-V8String '7d') + (New-V8Window $Week[0] $Week[1]) }
    $win += [byte[]](0x7b, 0x02)
    $v8 = [byte[]](@(0xff, 0x15, 0x6f) + (ConvertTo-V8String 'messageLimits') + @(0x6f) + (ConvertTo-V8String 'windows') + $win +
        @(0x7b, 0x01, 0x7b, 0x01) + @(0x22, 0x0d) + [byte[]]$Latin1.GetBytes('dataUpdatedAt') + (ConvertTo-V8Number $UpdatedMs))
    $out = New-Object System.Collections.Generic.List[byte]
    $out.AddRange([byte[]](0xff, 0x11, 0x02)); $out.AddRange((ConvertTo-Varint $v8.Length))
    for ($i = 0; $i -lt $v8.Length; $i += 60) {
        $n = [math]::Min(60, $v8.Length - $i)
        $out.Add([byte](($n - 1) -shl 2)); $out.AddRange([byte[]]$v8[$i..($i + $n - 1)])
    }
    $dir = Split-Path -Parent $Path
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    [IO.File]::WriteAllBytes($Path, $out.ToArray())
}

Test 'ClaudeDesktopParser: IndexedDB — недельный лимит, свежее 5-часовое окно, история' {
    $f = New-FakeDesktop
    New-IdbBlob ([IO.Path]::Combine($f.Root, 'IndexedDB', 'https_claude.ai_0.indexeddb.blob', '1', '00', '1d')) @(0.42, ($Now + 3 * 3600)) @(0.08, ($Now + 5 * 86400)) (($Now - 30) * 1000)
    Add-JournalRecord (Join-Path $f.Db '000003.log') (New-DesktopRecord 0.3 ($Now + 3 * 3600) ($Now - 600))
    $p = [ClaudeDesktopParser]::new($f.Root)
    $m = $p.ParseAt($Now)
    Eq $m.Status 'Ok'
    Eq (($m.Windows | ForEach-Object { $_.Id }) -join ',') 'five_hour,seven_day' 'окна:'
    Ok ([math]::Abs((Get-MetricsWindow $m 'five_hour').Used - 42) -lt 1e-9) '5ч из IndexedDB (свежее Local Storage)'
    $week = Get-MetricsWindow $m 'seven_day'
    Ok ([math]::Abs($week.Used - 8) -lt 1e-9 -and [math]::Abs($week.Left - 92) -lt 1e-9 -and -not $week.Rolling) "неделя: осталось 92% ($($week.Left))"
    Eq $week.Reset ($Now + 5 * 86400) 'сброс недели:'
    Eq $m.Updated ($Now - 30) 'Updated = dataUpdatedAt:'
    Add-JournalRecord (Join-Path $f.Db '000003.log') (New-DesktopRecord 0.5 ($Now + 3 * 3600) ($Now - 5))
    $m = $p.ParseAt($Now)
    Ok ([math]::Abs((Get-MetricsWindow $m 'five_hour').Used - 50) -lt 1e-9) 'свежая запись Local Storage перекрывает кэш'
    Eq (($m.Samples | ForEach-Object { [math]::Round($_.f) }) -join ',') '30,50' 'прошлые замеры окна:'

    $hist = Join-Path $f.Root 'desktop-history.jsonl'
    Ok (Add-MetricsHistory $m $hist $Now) 'история записана'
    Eq ((Read-History $hist | ForEach-Object { '{0}/{1}' -f $_.f, $_.w }) -join ',') '30/,50/,50/8' 'замеры + текущий снимок с неделей:'
    Ok (-not (Add-MetricsHistory $m $hist $Now)) 'без изменений — не дописываем'
    $model = Get-ChartModel (Get-MetricsWindow $m 'five_hour') (Read-History $hist) $Now
    Eq (($model.Points | ForEach-Object { $_[1] }) -join ',') '0,30,50,50' 'точки с одинаковым временем не дублируются:'
    Remove-Item -Recurse -Force $f.Root
}

Test 'New-LimitParser: единый контракт для обоих источников' {
    foreach ($s in $Sources) {
        $p = New-LimitParser $s (Join-Path ([IO.Path]::GetTempPath()) 'cl-nothing')
        Ok ($p -is [LimitParser]) "$s реализует LimitParser"
        Eq $p.Source $s
        foreach ($method in 'ParseLimits', 'GetResetTime', 'IsInstalled', 'GetLogPath') { Ok ($null -ne $p.GetType().GetMethod($method)) "$s.$method" }
    }
}

# ============================================================ 2в. Фоновый опрос
Write-Host '== LimitMonitoringService'

Test 'LimitMonitoringService: runspace, подписка, обновление по изменению файла' {
    $d = New-TempDir
    $code = Join-Path $d 'limits.json'
    $json = { param($u) '{"updated_at":' + (Get-UnixNow) + ',"rate_limits":{"five_hour":{"used_percentage":' + $u + ',"resets_at":' + ((Get-UnixNow) + 3600) + '}}}' }
    Write-Utf8 $code (& $json 10)
    $desk = New-FakeDesktop
    Add-JournalRecord (Join-Path $desk.Db '000003.log') (New-DesktopRecord 0.25 ((Get-UnixNow) + 3600) (Get-UnixNow))

    $svc = [LimitMonitoringService]::new((Join-Path $WinDir 'ClaudeLimits.Parsers.ps1'))
    $svc.IntervalMs = 1500; $svc.DebounceMs = 200
    $got = [Collections.ArrayList]::new()
    $svc.Subscribe('code', { param($m) [void]$got.Add($m) }.GetNewClosure())
    try {
        $svc.Watch('code', $code)
        $svc.Watch('desktop', $desk.Root)
        Ok ($svc.WaitForAll(30000)) "первые снимки получены (code: $($svc.Fault('code')); desktop: $($svc.Fault('desktop')))"
        Eq (Get-MetricsWindow $svc.Latest['code'] 'five_hour').Used 10 'Code:'
        Ok ([math]::Abs((Get-MetricsWindow $svc.Latest['desktop'] 'five_hour').Used - 25) -lt 1e-9) 'Desktop: 25%'
        Eq $got.Count 1 'подписчик Code вызван один раз:'

        Write-Utf8 $code (& $json 64)
        $deadline = [DateTime]::UtcNow.AddSeconds(15)
        while ([DateTime]::UtcNow -lt $deadline -and (Get-MetricsWindow $svc.Latest['code'] 'five_hour').Used -ne 64) { [void]$svc.Dispatch(); Start-Sleep -Milliseconds 100 }
        Eq (Get-MetricsWindow $svc.Latest['code'] 'five_hour').Used 64 'изменение файла доставлено:'
        Ok ($got.Count -ge 2) 'подписчик получил обновление'

        $svc.Watch('desktop', (Join-Path $d 'нет-такой-папки'))
        Ok ($svc.WaitForAll(15000)) 'смена папки Desktop'
        Eq $svc.Latest['desktop'].Status 'NotFound' 'неверная папка -> NotFound:'
    } finally { $svc.Dispose() }
    Ok ($svc.Retired.Count -eq 0 -and $svc.Workers.Count -eq 0) 'все runspace освобождены'
    Remove-Item -Recurse -Force $d, $desk.Root -ErrorAction SilentlyContinue
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
    $r = Invoke-StatusLine '{"model":{"display_name":"Opus"},"rate_limits":{}}' $d
    Eq $r.Out '[Opus]' 'пустой rate_limits:'
    Eq ([IO.File]::ReadAllText($limits)) $before 'пустой rate_limits limits.json не трогается:'
    $one = { param($u) '{"model":{"display_name":"Opus"},"rate_limits":{"five_hour":{"used_percentage":' + $u + ',"resets_at":' + ($now + 3600) + '}}}' }
    Eq (Invoke-StatusLine (& $one '1e308') $d).Out '[Opus] 5h: 100%' 'огромный процент:'
    Eq (Invoke-StatusLine (& $one '-5') $d).Out '[Opus] 5h: 0%' 'отрицательный процент:'
    Eq (Invoke-StatusLine (& $one '42.5') $d).Out '[Opus] 5h: 43%' 'округление .5 вверх, как на macOS и Linux:'
    Eq (Invoke-StatusLine (& $one '"42"') $d).Out '[Opus]' 'процент строкой не показывается:'
    Eq (Invoke-StatusLine (& $one 'true') $d).Out '[Opus]' 'true — не процент:'

    # очистка истории > 512 КБ
    $old = $now - 20 * 86400
    $line = '{"t":' + $old + ',"f":1,"fr":1,"w":1,"wr":1}'
    [IO.File]::WriteAllText($hist, (($line + "`n") * 15000), (New-Object Text.UTF8Encoding $false))
    [void](Invoke-StatusLine (& $p 70 80) $d)
    $lines = @([IO.File]::ReadAllLines($hist) | Where-Object { $_ })
    Ok ($lines.Count -eq 1 -and $lines[0] -like '*"f":70*') "старая история очищена (строк: $($lines.Count))"
    Remove-Item -Recurse -Force $d
}

# ============================================================ 3б. Виджет на телефоне
Write-Host '== Виджет на телефоне (ClaudeLimits.Phone.ps1, phone.ps1)'
. (Join-Path $WinDir 'ClaudeLimits.Phone.ps1')

function New-PhoneMetrics([double]$Five = 42.5, [int64]$Now = 1800000000) {
    $c = [LimitMetrics]::new('code'); $c.Status = 'Ok'; $c.Updated = $Now - 100
    $c.Windows = @([LimitParser]::NewWindow('five_hour', $Five, $Now + 10000, $false, $Now), [LimitParser]::NewWindow('seven_day', 13, $Now + 300000, $false, $Now))
    $d = [LimitMetrics]::new('desktop'); $d.Status = 'Ok'; $d.Updated = $Now - 10000
    $d.Windows = @([LimitParser]::NewWindow('five_hour', 80, $Now + 5000, $true, $Now), [LimitParser]::NewWindow('seven_day', 20, $Now + 300000, $false, $Now))
    return @{ code = $c; desktop = $d }
}

function Start-FakeGitHub {
    $names = if ($OnWindows) { @('python', 'python3') } else { @('python3', 'python') }
    $py = $names | Where-Object { Get-Command $_ -ErrorAction SilentlyContinue } | Select-Object -First 1
    if (-not $py) { return $null }
    $dir = New-TempDir
    $spArgs = @{ FilePath = (Get-Command $py).Source; ArgumentList = @("`"$(Join-Path $Repo 'tests/fake_github.py')`"", "`"$dir`""); PassThru = $true }
    if ($OnWindows) { $spArgs.WindowStyle = 'Hidden' }
    $proc = Start-Process @spArgs
    $portFile = Join-Path $dir 'port'
    for ($i = 0; $i -lt 100 -and -not (Test-Path $portFile); $i++) { Start-Sleep -Milliseconds 100 }
    if (-not (Test-Path $portFile)) { Stop-Process -Id $proc.Id -Force; return $null }
    return @{ Proc = $proc; Dir = $dir; Api = "http://127.0.0.1:$([IO.File]::ReadAllText($portFile).Trim())" }
}

Test 'Phone: снимок совпадает с форматом виджета (tests/scriptable/payload.json)' {
    $fixture = [IO.File]::ReadAllText((Join-Path $Repo 'tests/scriptable/payload.json')) | ConvertFrom-Json
    $p = Get-PhonePayload (New-PhoneMetrics) 1800000000
    Eq ($p | ConvertTo-Json -Depth 6 -Compress) ($fixture | ConvertTo-Json -Depth 6 -Compress) 'снимок:'
    $m = New-PhoneMetrics
    $m.desktop = [LimitMetrics]::new('desktop'); $m.desktop.Status = 'NotFound'
    $m.code.Windows[0] = [LimitParser]::NewWindow('five_hour', 90, 1799999999, $false, 1800000000)
    $p = Get-PhonePayload $m 1800000000
    Eq (@($p.sources.Keys) -join ',') 'code' 'источник без данных пропущен:'
    Eq $p.sources.code.windows[0].used 90 'процент как есть:'
    Eq (Get-PhonePayloadKey (Get-PhonePayload (New-PhoneMetrics) 1)) (Get-PhonePayloadKey (Get-PhonePayload (New-PhoneMetrics) 99)) 'ключ без времени отправки:'
    Eq (Get-PhonePayload @{} 1).sources.Count 0 'нет данных:'
}

Test 'Phone: когда отправлять' {
    $n = 1800000000
    Ok (Test-PhoneShouldSend 'a' $null 0 0 $n) 'первый раз'
    Ok (-not (Test-PhoneShouldSend 'a' 'a' 0 0 $n)) 'без изменений'
    Ok (-not (Test-PhoneShouldSend 'b' 'a' ($n - 59) 0 $n)) 'чаще раза в минуту'
    Ok (Test-PhoneShouldSend 'b' 'a' ($n - 60) 0 $n) 'через минуту'
    Ok (-not (Test-PhoneShouldSend 'b' 'a' 0 ($n - 299) $n)) 'после ошибки ждём'
    Ok (Test-PhoneShouldSend 'b' 'a' 0 ($n - 300) $n) 'через 5 минут после ошибки'
}

Test 'Phone: настройки и тело запроса' {
    $d = New-TempDir
    $cfg = Join-Path $d '.claude/limits-phone.json'
    Ok ($null -eq (Read-PhoneConfig $cfg)) 'нет настроек'
    Save-PhoneConfig 'tok' 'gid' $cfg
    $c = Read-PhoneConfig $cfg
    Ok ($c.token -eq 'tok' -and $c.gist_id -eq 'gid') 'настройки сохранены'
    [IO.File]::WriteAllText($cfg, '{"token":""}')
    Ok ($null -eq (Read-PhoneConfig $cfg)) 'пустой токен — не настроено'
    $b = Get-PhoneGistBody (Get-PhonePayload (New-PhoneMetrics) 5) -Create | ConvertFrom-Json
    Eq $b.public $false 'gist секретный:'
    $content = $b.files.'claude-limits.json'.content | ConvertFrom-Json
    Eq $content.sources.code.windows[0].used 42.5 'в gist уходит снимок:'
    Eq $content.sources.desktop.windows[0].rolling $true 'скользящее окно Desktop:'
    Eq (Get-PhoneErrorText 401).Contains('401') $true 'текст ошибки 401:'
    Remove-Item -Recurse -Force $d
}

Test 'Phone: фоновая выгрузка и phone.ps1 с поддельным GitHub' {
    $gh = Start-FakeGitHub
    if (-not $gh) { Write-Host '   (пропущено: нет python для поддельного GitHub)'; return }
    $d = New-TempDir
    $saved = @{ USERPROFILE = $env:USERPROFILE; API = $env:CLAUDE_LIMITS_GITHUB_API; TOKEN = $env:CLAUDE_LIMITS_GITHUB_TOKEN }
    try {
        $env:USERPROFILE = $d
        $env:CLAUDE_LIMITS_GITHUB_API = $gh.Api
        $psArgs = @('-NoProfile')
        if ($OnWindows) { $psArgs += @('-ExecutionPolicy', 'Bypass') }
        $psArgs += @('-File', (Join-Path $WinDir 'phone.ps1'))
        $env:CLAUDE_LIMITS_GITHUB_TOKEN = 'bad'
        $out = (& $PsExe @psArgs setup) -join "`n"
        Eq $LASTEXITCODE 1 "неверный токен ($out):"
        Ok ($out -like '*401*') "понятная ошибка: $out"
        $env:CLAUDE_LIMITS_GITHUB_TOKEN = 'good'
        $out = (& $PsExe @psArgs setup) -join "`n"
        Eq $LASTEXITCODE 0 "setup ($out):"
        Ok ($out -like '*ID для виджета:  g1*') "напечатан ID: $out"
        Eq (([IO.File]::ReadAllText((Join-Path $gh.Dir 'g1.json')) | ConvertFrom-Json).public) $false 'gist секретный:'
        $out = (& $PsExe @psArgs setup) -join "`n"
        Ok (@(Get-ChildItem $gh.Dir -Filter 'g*.json').Count -eq 1) 'повторная настройка использует тот же gist'
        Ok (((& $PsExe @psArgs status) -join ' ') -like '*g1*') 'status'

        $sync = New-PhoneSync
        Ok (-not (Step-PhoneSync $sync)) 'нет снимка — нечего слать'
        $sync.Pending = New-PhoneMetrics 61
        Ok (Step-PhoneSync $sync) 'выгрузка началась'
        for ($i = 0; $i -lt 200 -and -not $sync.Job.Handle.IsCompleted; $i++) { Start-Sleep -Milliseconds 50 }
        Complete-PhoneSync $sync
        Ok ($null -eq $sync.LastError) "без ошибок ($($sync.LastError))"
        $content = (([IO.File]::ReadAllText((Join-Path $gh.Dir 'g1.json')) | ConvertFrom-Json).files.'claude-limits.json'.content | ConvertFrom-Json)
        Eq $content.sources.code.windows[0].used 61 'цифры в gist:'
        Ok (-not (Step-PhoneSync $sync)) 'те же цифры — не отправляем'

        $out = (& $PsExe @psArgs disable) -join ' '
        Ok (-not (Test-Path (Join-Path $d '.claude/limits-phone.json'))) "disable удаляет токен: $out"
        Ok (-not (Step-PhoneSync $sync) -and -not $sync.Config) 'настройки удалены — выгрузка выключена'
    } finally {
        $env:USERPROFILE = $saved.USERPROFILE; $env:CLAUDE_LIMITS_GITHUB_API = $saved.API; $env:CLAUDE_LIMITS_GITHUB_TOKEN = $saved.TOKEN
        Stop-Process -Id $gh.Proc.Id -Force -ErrorAction SilentlyContinue
        Remove-Item -Recurse -Force $d, $gh.Dir -ErrorAction SilentlyContinue
    }
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
            foreach ($f in @('ClaudeLimits.Core.ps1', 'ClaudeLimits.Parsers.ps1', 'ClaudeLimits.Monitoring.ps1', 'ClaudeLimits.Phone.ps1', 'ClaudeLimits.ps1', 'statusline.ps1', 'phone.ps1', 'uninstall.ps1')) {
                Ok (Test-Path (Join-Path $inst $f)) "установлен $f"
            }
            $cfg = Read-Config (Join-Path $inst 'config.json')
            Ok ((Test-Path (Join-Path $inst 'config.json')) -and $cfg.active_tab -eq 0 -and $cfg.desktop_path -eq '') 'config.json с настройками по умолчанию'
            Ok (($out -join ' ') -like '*Claude Desktop*') 'установщик сообщает о Claude Desktop'
            Eq (Get-InstalledVersion $inst) ([IO.File]::ReadAllText((Join-Path $Repo 'VERSION')).Trim()) 'версия записана:'
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
