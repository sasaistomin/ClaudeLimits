# ClaudeLimits for Windows — логика без интерфейса (тексты, настройки, карточки, уведомления, график).
# Данные читают парсеры (ClaudeLimits.Parsers.ps1), опрос ведёт LimitMonitoringService (ClaudeLimits.Monitoring.ps1).
# Подключается из ClaudeLimits.ps1 и из тестов: tests/windows/run-tests.ps1
# Работает в Windows PowerShell 5.1 и PowerShell 7.

$Strings = @{ 
    ru = @{
        Title = 'Лимиты Claude'; Five = '5 часов'; Week = 'Неделя'
        NoData = 'нет данных'; NoDataLong = 'Пока нет данных.'; SendMsg = 'Отправьте любое сообщение в Claude Code.'
        TipNoData = 'Claude: нет данных — напишите в Claude Code'
        LeftUsed = '{0}: осталось {1}%  (использовано {2}%)'; Reset = 'сброс {0}'
        Done = 'сброшен'; InDH = 'через {0} д {1} ч'; InHM = 'через {0} ч {1} мин'; InM = 'через {0} мин'
        Updated = 'Обновлено {0}'; JustNow = 'только что'; MinAgo = '{0} мин назад'; HAgo = '{0} ч назад'; DAgo = '{0} д назад'
        Startup = 'Запускать при входе в Windows'; Language = 'Язык'; System = 'Системный'; Quit = 'Выход'
        CheckUpdates = 'Проверить обновления'; CheckingUpdates = 'Проверяю обновления…'
        UpToDate = 'Установлена последняя версия ({0})'; UpdateTo = 'Обновить до версии {0}'
        UpdateFailed = 'Не удалось проверить обновления — повторить'; InstallingUpdate = 'Устанавливаю обновление…'
        TipFive = '5ч'; TipWeek = 'неделя'; TipCode = 'Code'; TipDesktop = 'Desktop'
        Notifications = 'Уведомления'
        NotifOnTitle = 'Уведомления включены'; NotifOnBody = 'Сообщу, когда лимит будет заканчиваться и когда он сбросится.'
        LowTitle = '[{0}] Осталось {1}%'
        LowBodyFive = '5-часовое окно израсходовано на {0}%. Сброс {1}.'
        LowBodyWeek = 'Недельный лимит израсходован на {0}%. Сброс {1}.'
        LowBodyRolling = '5-часовое окно сообщений израсходовано на {0}%. Сброс в {1}.'
        ExhaustedBodyRolling = '5-часовое окно сообщений исчерпано. Сброс в {1}.'
        ResetTitle = '[{0}] Лимит сброшен'
        ResetBodyFive = '5-часовое окно обновилось — можно работать.'
        ResetBodyWeek = 'Недельный лимит обновился — можно работать.'
        ResetBodyRolling = '5-часовое окно сообщений обновилось — можно работать.'
        Rolling = 'Окно 5 ч (скользящее)'; ResetAt = 'сброс в {0} ({1})'; Loading = 'Загрузка…'
        DesktopNotFound = 'Claude Desktop: не подключено'; DesktopNotFoundHint = 'Логи не найдены — укажите папку в меню «Claude Desktop»'
        DesktopNoData = 'Лимиты пока не записаны.'; DesktopSendMsg = 'Отправьте сообщение в Claude Desktop.'
        DesktopFolder = 'Claude Desktop'; DesktopAuto = 'Находить папку автоматически'; DesktopPick = 'Указать папку данных…'
        DesktopPickTitle = 'Папка данных Claude Desktop (обычно %APPDATA%\Claude)'; DesktopNoPath = 'Папка не найдена'
        Chart = 'График использования…'; ChartTitle = 'Лимиты Claude — график'
        Tab5h = '5 часов'; TabWeek = 'Неделя'; Culture = 'ru-RU'
        ChartNoData = 'Окно сбросилось. График появится после следующего ответа Claude Code.'
        ForecastAt5 = 'Прогноз: при таком темпе лимит закончится в {0}'
        ForecastAtWeek = 'Прогноз: при таком темпе лимит закончится {0}'
        ForecastOK = 'Прогноз: при таком темпе лимита хватит до сброса'
    }
    en = @{
        Title = 'Claude Limits'; Five = '5 hours'; Week = 'Weekly'
        NoData = 'no data'; NoDataLong = 'No data yet.'; SendMsg = 'Send any message in Claude Code.'
        TipNoData = 'Claude: no data — send a message in Claude Code'
        LeftUsed = '{0}: {1}% left  ({2}% used)'; Reset = 'resets {0}'
        Done = 'done'; InDH = 'in {0}d {1}h'; InHM = 'in {0}h {1}m'; InM = 'in {0}m'
        Updated = 'Updated {0}'; JustNow = 'just now'; MinAgo = '{0} min ago'; HAgo = '{0} h ago'; DAgo = '{0} d ago'
        Startup = 'Launch at Windows sign-in'; Language = 'Language'; System = 'System'; Quit = 'Quit'
        CheckUpdates = 'Check for updates'; CheckingUpdates = 'Checking for updates…'
        UpToDate = 'Up to date ({0})'; UpdateTo = 'Update to {0}'
        UpdateFailed = "Couldn't check for updates — retry"; InstallingUpdate = 'Installing update…'
        TipFive = '5h'; TipWeek = 'week'; TipCode = 'Code'; TipDesktop = 'Desktop'
        Notifications = 'Notifications'
        NotifOnTitle = 'Notifications are on'; NotifOnBody = "I'll let you know when a limit is running low and when it resets."
        LowTitle = '[{0}] {1}% left'
        LowBodyFive = '5-hour window is {0}% used. Resets {1}.'
        LowBodyWeek = 'Weekly limit is {0}% used. Resets {1}.'
        LowBodyRolling = '5-hour message window is {0}% used. Resets at {1}.'
        ExhaustedBodyRolling = '5-hour message window is used up. Resets at {1}.'
        ResetTitle = '[{0}] Limit has reset'
        ResetBodyFive = "The 5-hour window has reset — you're good to go."
        ResetBodyWeek = "The weekly limit has reset — you're good to go."
        ResetBodyRolling = "The 5-hour message window has reset — you're good to go."
        Rolling = '5-hour window (rolling)'; ResetAt = 'resets at {0} ({1})'; Loading = 'Loading…'
        DesktopNotFound = 'Claude Desktop: not connected'; DesktopNotFoundHint = 'Logs not found — set the folder in the «Claude Desktop» menu'
        DesktopNoData = 'No limits recorded yet.'; DesktopSendMsg = 'Send a message in Claude Desktop.'
        DesktopFolder = 'Claude Desktop'; DesktopAuto = 'Find the folder automatically'; DesktopPick = 'Choose data folder…'
        DesktopPickTitle = 'Claude Desktop data folder (usually %APPDATA%\Claude)'; DesktopNoPath = 'Folder not found'
        Chart = 'Usage chart…'; ChartTitle = 'Claude Limits — chart'
        Tab5h = '5 hours'; TabWeek = 'Week'; Culture = 'en-US'
        ChartNoData = "The window has reset. The chart will appear after Claude Code's next reply."
        ForecastAt5 = "Forecast: at this pace you'll hit the limit at {0}"
        ForecastAtWeek = "Forecast: at this pace you'll hit the limit at {0}"
        ForecastOK = 'Forecast: at this pace the limit will last until reset'
    }
}


$Sources = @('code', 'desktop')
$SourceNames = @{ code = 'Claude Code'; desktop = 'Claude Desktop' }

function Get-UnixNow { [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() }

function ConvertTo-LocalTime([int64]$t) { [DateTimeOffset]::FromUnixTimeSeconds($t).LocalDateTime }

# ---------- настройки (config.json) ----------
# { "language": "system|ru|en", "notifications": true, "active_tab": 0|1, "desktop_path": "",
#   "notified": { "five_hour:80": <resets_at>, "desktop:five_hour:95": <resets_at>, ... } }

function Read-Config([string]$Path) {
    $cfg = @{ language = 'system'; notifications = $true; notified = @{}; active_tab = 0; desktop_path = '' }
    try {
        if (-not (Test-Path -LiteralPath $Path)) { return $cfg }
        $c = [IO.File]::ReadAllText($Path) | ConvertFrom-Json
        if (@('system', 'ru', 'en') -contains $c.language) { $cfg.language = [string]$c.language }
        if ($null -ne $c.notifications) { $cfg.notifications = [bool]$c.notifications }
        $tab = $c.active_tab -as [int]
        if ($null -ne $tab -and $tab -ge 0 -and $tab -lt $Sources.Count) { $cfg.active_tab = $tab }
        if ($c.desktop_path -is [string]) { $cfg.desktop_path = $c.desktop_path }
        if ($c.notified) { foreach ($p in $c.notified.PSObject.Properties) { $cfg.notified[$p.Name] = [double]$p.Value } }
    } catch { }
    return $cfg
}

function Save-Config([hashtable]$Config, [string]$Path) {
    try {
        $json = $Config | ConvertTo-Json -Depth 5
        [IO.File]::WriteAllText($Path, $json, (New-Object Text.UTF8Encoding $false))
    } catch { }
}

function Resolve-Lang([string]$Setting, [string]$UiLang = (Get-UICulture).TwoLetterISOLanguageName) {
    if ($Setting -eq 'ru' -or $Setting -eq 'en') { return $Setting }
    if ($UiLang -eq 'ru') { return 'ru' }
    return 'en'
}

# ---------- форматирование ----------

function Format-Countdown([int64]$ResetAt, [hashtable]$T, [int64]$Now = (Get-UnixNow)) {
    $s = $ResetAt - $Now
    if ($s -le 0) { return $T.Done }
    $d = [math]::Floor($s / 86400); $h = [math]::Floor(($s % 86400) / 3600); $m = [math]::Floor(($s % 3600) / 60)
    if ($d -gt 0) { return ($T.InDH -f $d, $h) }
    if ($h -gt 0) { return ($T.InHM -f $h, $m) }
    return ($T.InM -f $m)
}

function Format-Ago([int64]$Ts, [hashtable]$T, [int64]$Now = (Get-UnixNow)) {
    $s = $Now - $Ts
    if ($s -lt 60) { return $T.JustNow }
    if ($s -lt 3600) { return ($T.MinAgo -f [math]::Floor($s / 60)) }
    if ($s -lt 86400) { return ($T.HAgo -f [math]::Floor($s / 3600)) }
    return ($T.DAgo -f [math]::Floor($s / 86400))
}

function Format-ClockTime([int64]$Ts, [hashtable]$T) {
    (ConvertTo-LocalTime $Ts).ToString('HH:mm', [Globalization.CultureInfo]::GetCultureInfo($T.Culture))
}

# 'green' | 'yellow' | 'red'
function Get-Level([double]$Used) {
    if ($Used -ge 90) { return 'red' }
    if ($Used -ge 70) { return 'yellow' }
    return 'green'
}

function Get-MetricsWindow($Metrics, [string]$Id) {
    if (-not $Metrics -or $Metrics.Status -ne 'Ok') { return $null }
    foreach ($w in $Metrics.Windows) { if ($w.Id -eq $Id) { return $w } }
    return $null
}

# Подсказка у значка в трее по всем источникам с данными (в .NET Framework — не длиннее 63 символов)
function Get-TrayTooltip([object[]]$Metrics, [hashtable]$T) {
    $parts = @(foreach ($m in $Metrics) {
        if (-not $m -or $m.Status -ne 'Ok') { continue }
        $windows = @(foreach ($w in $m.Windows) { '{0} {1}%' -f $(if ($w.Id -eq 'five_hour') { $T.TipFive } else { $T.TipWeek }), [math]::Round($w.Left) })
        '{0}: {1}' -f $(if ($m.Source -eq 'desktop') { $T.TipDesktop } else { $T.TipCode }), ($windows -join ' · ')
    })
    $tip = if ($parts.Count) { $parts -join ' | ' } else { $T.TipNoData }
    return $tip.Substring(0, [math]::Min(63, $tip.Length))
}

# Две строки карточки окна: «что осталось» и «когда сброс». Скользящее окно Desktop показывает время сброса.
function Format-WindowLines($Window, [hashtable]$T, [int64]$Now = (Get-UnixNow)) {
    $label = if ($Window.Rolling) { $T.Rolling } elseif ($Window.Id -eq 'five_hour') { $T.Five } else { $T.Week }
    $main = $T.LeftUsed -f $label, [math]::Round($Window.Left), [math]::Round($Window.Used)
    $countdown = Format-Countdown $Window.Reset $T $Now
    $reset = if ($Window.Rolling -and $Window.Reset -gt $Now) { $T.ResetAt -f (Format-ClockTime $Window.Reset $T), $countdown } else { $T.Reset -f $countdown }
    return @($main, ('      ' + $reset))
}

# Две строки для вкладки без данных: загрузка / не подключено / нет данных.
function Get-EmptyStateLines([string]$Source, $Metrics, [hashtable]$T) {
    if (-not $Metrics) { return @($T.Loading, '') }
    if ($Source -eq 'desktop') {
        if ($Metrics.Status -eq 'NotFound') { return @($T.DesktopNotFound, $T.DesktopNotFoundHint) }
        return @($T.DesktopNoData, $T.DesktopSendMsg)
    }
    return @($T.NoDataLong, $T.SendMsg)
}

# ---------- уведомления (решение, без отправки) ----------

function Get-NotifyKey([string]$Source, $Window) {
    if ($Source -eq 'code') { return $Window.Id }
    return "${Source}:$($Window.Id)"
}

function Get-NotifyThresholds($Window) {
    if ($Window.Rolling) { return @(100, 95, 80) }
    return @(95, 80)
}

# $Notified — hashtable «ключ -> resets_at окна, о котором уже сообщали»; функция его дополняет.
# Возвращает @{ Type = 'low'; Threshold; Used } / @{ Type = 'reset' } / $null.
function Get-NotifyEvent([string]$Key, $Window, [hashtable]$Notified, [int64]$Now = (Get-UnixNow), [int[]]$Thresholds = @(95, 80)) {
    $w = $Window
    $already = { param($k) $Notified.ContainsKey($k) -and [math]::Abs($Notified[$k] - $w.Reset) -lt 1800 }
    if ($Now -lt $w.Reset) {
        $levels = @($Thresholds | Sort-Object -Descending)
        foreach ($th in $levels) {
            if ($w.RawUsed -ge $th) {
                if (& $already "${Key}:$th") { return $null }
                foreach ($t in $levels) { if ($t -le $th) { $Notified["${Key}:$t"] = [double]$w.Reset } }
                return @{ Type = 'low'; Threshold = $th; Used = [int][math]::Round($w.RawUsed) }
            }
        }
        return $null
    }
    if (($Now - $w.Reset) -lt 900 -and $w.RawUsed -ge 80 -and -not (& $already "${Key}:reset")) {
        $Notified["${Key}:reset"] = [double]$w.Reset
        return @{ Type = 'reset' }
    }
    return $null
}

# Текст уведомления с источником в заголовке: @{ Title; Body; Icon = 'Info'|'Warning' }
function Format-Notification([hashtable]$Ev, $Window, [string]$Source, [hashtable]$T, [int64]$Now = (Get-UnixNow)) {
    $name = $SourceNames[$Source]
    $kind = if ($Window.Rolling) { 'Rolling' } elseif ($Window.Id -eq 'five_hour') { 'Five' } else { 'Week' }
    if ($Ev.Type -eq 'reset') {
        return @{ Title = ($T.ResetTitle -f $name); Body = $T["ResetBody$kind"]; Icon = 'Info' }
    }
    $when = if ($Window.Rolling) { Format-ClockTime $Window.Reset $T } else { Format-Countdown $Window.Reset $T $Now }
    $body = if ($Window.Rolling -and $Ev.Threshold -ge 100) { $T.ExhaustedBodyRolling } else { $T["LowBody$kind"] }
    return @{
        Title = ($T.LowTitle -f $name, [math]::Max(0, 100 - $Ev.Used))
        Body  = ($body -f $Ev.Used, $when)
        Icon  = $(if ($Ev.Threshold -ge 95) { 'Warning' } else { 'Info' })
    }
}

# ---------- история и график ----------

# Дописывает в историю снимок источника (Claude Desktop) и его прошлые замеры, если проценты изменились.
function Add-MetricsHistory($Metrics, [string]$Path, [int64]$Now = (Get-UnixNow)) {
    if (-not $Metrics -or $Metrics.Status -ne 'Ok') { return $false }
    $last = @(Read-History $Path) | Select-Object -Last 1
    $lastT = if ($last) { [int64]$last.t } else { [int64]0 }
    $lastF = if ($last) { $last.f } else { $null }
    $lastW = if ($last) { $last.w } else { $null }
    $lines = New-Object System.Collections.ArrayList
    foreach ($s in @($Metrics.Samples)) {
        if ($s -and [int64]$s.t -gt $lastT -and $s.f -ne $lastF) {
            [void]$lines.Add(([ordered]@{ t = [int64]$s.t; f = [double]$s.f; fr = [int64]$s.fr } | ConvertTo-Json -Compress))
            $lastT = [int64]$s.t; $lastF = $s.f; $lastW = $null
        }
    }
    $five = Get-MetricsWindow $Metrics 'five_hour'
    $week = Get-MetricsWindow $Metrics 'seven_day'
    $f = if ($five) { $five.RawUsed } else { $null }
    $w = if ($week) { $week.RawUsed } else { $null }
    if ($lines.Count -eq 0 -and $last -and $f -eq $lastF -and $w -eq $lastW) { return $false }
    if (-not ($lines.Count -gt 0 -and $f -eq $lastF -and $w -eq $lastW)) {
        $t = if ($Metrics.Updated -gt 0) { [int64]$Metrics.Updated } else { $Now }
        $cur = [ordered]@{ t = [math]::Max($t, $lastT) }
        if ($five) { $cur.f = [double]$five.RawUsed; $cur.fr = [int64]$five.Reset }
        if ($week) { $cur.w = [double]$week.RawUsed; $cur.wr = [int64]$week.Reset }
        [void]$lines.Add(($cur | ConvertTo-Json -Compress))
    }
    try {
        $dir = Split-Path -Parent $Path
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        [IO.File]::AppendAllText($Path, (($lines -join "`n") + "`n"), (New-Object Text.UTF8Encoding $false))
    } catch { return $false }
    return $true
}

function Read-History([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    try {
        $lines = @([IO.File]::ReadAllLines($Path) | Where-Object { $_.Trim() })
        if ($lines.Count -eq 0) { return @() }
        return @(('[' + ($lines -join ',') + ']') | ConvertFrom-Json)
    } catch { return @() }
}

# Модель графика окна Claude Code: точки (от начала окна с 0% через историю к «сейчас») и прогноз по среднему темпу.
function Get-ChartModel($Window, $History, [int64]$Now = (Get-UnixNow)) {
    $w = $Window
    if (-not $w -or $w.Reset -le $Now) { return $null }
    $Five = $w.Id -eq 'five_hour'
    $dur = if ($Five) { 5 * 3600 } else { 7 * 86400 }
    $start = [int64]($w.Reset - $dur)
    $pts = New-Object System.Collections.ArrayList
    [void]$pts.Add(@($start, 0.0))
    foreach ($s in @($History)) {
        if (-not $s) { continue }
        $v = if ($Five) { $s.f } else { $s.w }
        if ($null -ne $v -and [int64]$s.t -ge $start -and [int64]$s.t -le $Now) {
            if ($pts[$pts.Count - 1][0] -eq [int64]$s.t) { $pts.RemoveAt($pts.Count - 1) }
            [void]$pts.Add(@([int64]$s.t, [double]$v))
        }
    }
    [void]$pts.Add(@([int64]$Now, [double]$w.Used))
    $elapsed = $Now - $start
    $rate = 0.0
    if ($elapsed -gt 300 -and $w.Used -gt 0) { $rate = $w.Used / $elapsed }
    $runOut = $null
    if ($rate -gt 0) {
        $t100 = $Now + (100 - $w.Used) / $rate
        if ($t100 -lt $w.Reset) { $runOut = [int64]$t100 }
    }
    return @{ Five = $Five; Start = $start; End = [int64]$w.Reset; Now = [int64]$Now; Used = [double]$w.Used
              Points = $pts; Rate = $rate; RunOut = $runOut }
}

# ---------- обновления (VERSION на GitHub, установка — тем же install.ps1) ----------

function Get-RepoRaw {
    if ($env:CLAUDE_LIMITS_REPO_RAW) { return $env:CLAUDE_LIMITS_REPO_RAW }
    return 'https://raw.githubusercontent.com/sasaistomin/ClaudeLimits/main'
}

function Get-InstalledVersion([string]$Dir) {
    $p = Join-Path $Dir 'VERSION'
    try { if (Test-Path -LiteralPath $p) { $v = [IO.File]::ReadAllText($p).Trim(); if ($v) { return $v } } } catch { }
    return '0.0.0'
}

# 'v2.10.1-beta' -> 2, 10, 1
function Get-VersionParts([string]$Version) {
    $s = "$Version".Trim().TrimStart('v', 'V')
    return @(foreach ($p in $s.Split('.')) { if ($p -match '^(\d+)') { [int]$Matches[1] } else { 0 } })
}

# Новее ли Remote, чем Local. Пустая или нечисловая версия на сервере — не обновление.
function Test-NewerVersion([string]$Remote, [string]$Local) {
    $r = @(Get-VersionParts $Remote); $l = @(Get-VersionParts $Local)
    if (-not ($r | Where-Object { $_ -gt 0 })) { return $false }
    for ($i = 0; $i -lt [math]::Max($r.Count, $l.Count); $i++) {
        $a = if ($i -lt $r.Count) { $r[$i] } else { 0 }
        $b = if ($i -lt $l.Count) { $l[$i] } else { 0 }
        if ($a -ne $b) { return $a -gt $b }
    }
    return $false
}

# Самодостаточна: её текст выполняется в фоновом runspace (см. ClaudeLimits.ps1).
function Get-RemoteVersion([string]$Url, [int]$TimeoutMs = 15000) {
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
    $req = [Net.WebRequest]::Create($Url)
    $req.Timeout = $TimeoutMs
    if ($req -is [Net.HttpWebRequest]) {
        $req.UserAgent = 'ClaudeLimits'
        $req.CachePolicy = New-Object Net.Cache.RequestCachePolicy([Net.Cache.RequestCacheLevel]::NoCacheNoStore)
    }
    $resp = $req.GetResponse()
    try {
        $reader = New-Object IO.StreamReader($resp.GetResponseStream())
        return $reader.ReadToEnd().Trim()
    } finally { $resp.Close() }
}

# Аргументы powershell.exe для обновления: скачать install.ps1 и выполнить (он остановит значок и запустит новый).
function Get-UpdateArguments([string]$RepoRaw = (Get-RepoRaw)) {
    $cmd = "[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 'Tls12'; " +
           "Invoke-WebRequest -UseBasicParsing -Uri '$RepoRaw/windows/install.ps1' -OutFile `"`$env:TEMP\cl-install.ps1`"; " +
           "& `"`$env:TEMP\cl-install.ps1`""
    return "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command `"$($cmd -replace '"', '\"')`""
}

# ---------- settings.json Claude Code (для install.ps1 / uninstall.ps1) ----------

function Get-StatusLineCommand([string]$InstallDir) {
    $sl = (Join-Path $InstallDir 'statusline.ps1') -replace '\\', '/'
    return "powershell -NoProfile -ExecutionPolicy Bypass -File `"$sl`""
}

# Прописывает наш statusLine, сохраняя остальные ключи. Возвращает @{ Ok; Replaced = <прежняя чужая команда или $null> }.
# Битый JSON не трогает (Ok = $false). Делает копию settings.json.bak.
function Set-ClaudeStatusLine([string]$SettingsPath, [string]$Command) {
    $dir = Split-Path -Parent $SettingsPath
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $obj = New-Object PSObject
    $replaced = $null
    if (Test-Path -LiteralPath $SettingsPath) {
        $text = [IO.File]::ReadAllText($SettingsPath)
        if ($text.Trim()) {
            try { $obj = $text | ConvertFrom-Json } catch { return @{ Ok = $false; Replaced = $null } }
            if ($obj -isnot [PSCustomObject]) { return @{ Ok = $false; Replaced = $null } }
        }
        Copy-Item -Force -LiteralPath $SettingsPath -Destination "$SettingsPath.bak"
        if ($obj.statusLine -and $obj.statusLine.command -and ($obj.statusLine.command -notlike '*ClaudeLimits*')) {
            $replaced = [string]$obj.statusLine.command
        }
    }
    $statusLine = [ordered]@{ type = 'command'; command = $Command }
    $obj | Add-Member -Force -NotePropertyName statusLine -NotePropertyValue $statusLine
    [IO.File]::WriteAllText($SettingsPath, ($obj | ConvertTo-Json -Depth 32), (New-Object Text.UTF8Encoding $false))
    return @{ Ok = $true; Replaced = $replaced }
}

# Убирает statusLine, только если он наш. Возвращает $true, если что-то поменяли.
function Remove-ClaudeStatusLine([string]$SettingsPath) {
    if (-not (Test-Path -LiteralPath $SettingsPath)) { return $false }
    try { $obj = [IO.File]::ReadAllText($SettingsPath) | ConvertFrom-Json } catch { return $false }
    if (-not ($obj.statusLine -and ($obj.statusLine.command -like '*ClaudeLimits*'))) { return $false }
    Copy-Item -Force -LiteralPath $SettingsPath -Destination "$SettingsPath.bak"
    $obj.PSObject.Properties.Remove('statusLine')
    [IO.File]::WriteAllText($SettingsPath, ($obj | ConvertTo-Json -Depth 32), (New-Object Text.UTF8Encoding $false))
    return $true
}
