# ClaudeLimits for Windows — логика без интерфейса (тексты, настройки, данные, уведомления, график).
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
        TipFive = '5ч'; TipWeek = 'неделя'
        Notifications = 'Уведомления'
        NotifOnTitle = 'Уведомления включены'; NotifOnBody = 'Сообщу, когда лимит будет заканчиваться и когда он сбросится.'
        LowTitle = 'Claude: осталось {0}%'
        LowBodyFive = '5-часовое окно израсходовано на {0}%. Сброс {1}.'
        LowBodyWeek = 'Недельный лимит израсходован на {0}%. Сброс {1}.'
        ResetTitle = 'Лимит Claude сброшен'
        ResetBodyFive = '5-часовое окно обновилось — можно работать.'
        ResetBodyWeek = 'Недельный лимит обновился — можно работать.'
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
        TipFive = '5h'; TipWeek = 'week'
        Notifications = 'Notifications'
        NotifOnTitle = 'Notifications are on'; NotifOnBody = "I'll let you know when a limit is running low and when it resets."
        LowTitle = 'Claude: {0}% left'
        LowBodyFive = '5-hour window is {0}% used. Resets {1}.'
        LowBodyWeek = 'Weekly limit is {0}% used. Resets {1}.'
        ResetTitle = 'Claude limit has reset'
        ResetBodyFive = "The 5-hour window has reset — you're good to go."
        ResetBodyWeek = "The weekly limit has reset — you're good to go."
        Chart = 'Usage chart…'; ChartTitle = 'Claude Limits — chart'
        Tab5h = '5 hours'; TabWeek = 'Week'; Culture = 'en-US'
        ChartNoData = "The window has reset. The chart will appear after Claude Code's next reply."
        ForecastAt5 = "Forecast: at this pace you'll hit the limit at {0}"
        ForecastAtWeek = "Forecast: at this pace you'll hit the limit at {0}"
        ForecastOK = 'Forecast: at this pace the limit will last until reset'
    }
}


function Get-UnixNow { [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() }

function ConvertTo-LocalTime([int64]$t) { [DateTimeOffset]::FromUnixTimeSeconds($t).LocalDateTime }

# ---------- настройки (config.json) ----------
# { "language": "system|ru|en", "notifications": true, "notified": { "five_hour:80": <resets_at>, ... } }

function Read-Config([string]$Path) {
    $cfg = @{ language = 'system'; notifications = $true; notified = @{} }
    try {
        if (-not (Test-Path -LiteralPath $Path)) { return $cfg }
        $c = [IO.File]::ReadAllText($Path) | ConvertFrom-Json
        if (@('system', 'ru', 'en') -contains $c.language) { $cfg.language = [string]$c.language }
        if ($null -ne $c.notifications) { $cfg.notifications = [bool]$c.notifications }
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

# ---------- данные ----------

# Читает limits.json. Окно, время сброса которого прошло, считается обнулённым (Used = 0, RawUsed — как было).
function Read-Limits([string]$Path, [int64]$Now = (Get-UnixNow)) {
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        $d = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8) | ConvertFrom-Json
    } catch { return $null }
    if (-not $d -or -not $d.rate_limits) { return $null }
    $res = @{ Updated = [int64]$d.updated_at; Five = $null; Week = $null }
    foreach ($pair in @(@('Five', 'five_hour'), @('Week', 'seven_day'))) {
        $w = $d.rate_limits.($pair[1])
        if ($w) {
            $raw = [double]$w.used_percentage
            $reset = [int64]$w.resets_at
            $used = if ($reset -lt $Now) { 0.0 } else { $raw }
            $res[$pair[0]] = @{ Used = $used; RawUsed = $raw; Left = [math]::Max(0, 100 - $used); Reset = $reset }
        }
    }
    return $res
}

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

# 'green' | 'yellow' | 'red'
function Get-Level([double]$Used) {
    if ($Used -ge 90) { return 'red' }
    if ($Used -ge 70) { return 'yellow' }
    return 'green'
}

# Подсказка у значка в трее (в .NET Framework — не длиннее 63 символов)
function Get-TrayTooltip($Limits, [hashtable]$T) {
    if (-not $Limits -or (-not $Limits.Five -and -not $Limits.Week)) { $tip = $T.TipNoData }
    else {
        $tip = 'Claude'
        if ($Limits.Five) { $tip += (' · {0}: {1}%' -f $T.TipFive, [math]::Round($Limits.Five.Left)) }
        if ($Limits.Week) { $tip += (' · {0}: {1}%' -f $T.TipWeek, [math]::Round($Limits.Week.Left)) }
    }
    return $tip.Substring(0, [math]::Min(63, $tip.Length))
}

# ---------- уведомления (решение, без отправки) ----------

# $Notified — hashtable «ключ -> resets_at окна, о котором уже сообщали»; функция его дополняет.
# Возвращает @{ Type = 'low'; Threshold; Used } / @{ Type = 'reset' } / $null.
function Get-NotifyEvent([string]$Key, [hashtable]$Window, [hashtable]$Notified, [int64]$Now = (Get-UnixNow)) {
    $w = $Window
    $already = { param($k) $Notified.ContainsKey($k) -and [math]::Abs($Notified[$k] - $w.Reset) -lt 1800 }
    if ($Now -lt $w.Reset) {
        foreach ($th in @(95, 80)) {
            if ($w.RawUsed -ge $th) {
                if (& $already "${Key}:$th") { return $null }
                foreach ($t in @(95, 80)) { if ($t -le $th) { $Notified["${Key}:$t"] = [double]$w.Reset } }
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

# Текст уведомления: @{ Title; Body; Icon = 'Info'|'Warning' }
function Format-Notification([hashtable]$Ev, [hashtable]$Window, [bool]$Five, [hashtable]$T, [int64]$Now = (Get-UnixNow)) {
    if ($Ev.Type -eq 'reset') {
        return @{ Title = $T.ResetTitle; Body = $(if ($Five) { $T.ResetBodyFive } else { $T.ResetBodyWeek }); Icon = 'Info' }
    }
    $fmt = if ($Five) { $T.LowBodyFive } else { $T.LowBodyWeek }
    return @{
        Title = ($T.LowTitle -f [math]::Max(0, 100 - $Ev.Used))
        Body  = ($fmt -f $Ev.Used, (Format-Countdown $Window.Reset $T $Now))
        Icon  = $(if ($Ev.Threshold -ge 95) { 'Warning' } else { 'Info' })
    }
}

# ---------- история и график ----------

function Read-History([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    try {
        $lines = @([IO.File]::ReadAllLines($Path) | Where-Object { $_.Trim() })
        if ($lines.Count -eq 0) { return @() }
        return @(('[' + ($lines -join ',') + ']') | ConvertFrom-Json)
    } catch { return @() }
}

# Модель графика текущего окна: точки (от начала окна с 0% через историю к «сейчас») и прогноз по среднему темпу.
function Get-ChartModel($Limits, $History, [bool]$Five, [int64]$Now = (Get-UnixNow)) {
    $w = $null
    if ($Limits) { $w = if ($Five) { $Limits.Five } else { $Limits.Week } }
    if (-not $w -or $w.Reset -le $Now) { return $null }
    $dur = if ($Five) { 5 * 3600 } else { 7 * 86400 }
    $start = [int64]($w.Reset - $dur)
    $pts = New-Object System.Collections.ArrayList
    [void]$pts.Add(@($start, 0.0))
    foreach ($s in @($History)) {
        if (-not $s) { continue }
        $v = if ($Five) { $s.f } else { $s.w }
        if ($null -ne $v -and [int64]$s.t -ge $start -and [int64]$s.t -le $Now) { [void]$pts.Add(@([int64]$s.t, [double]$v)) }
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
