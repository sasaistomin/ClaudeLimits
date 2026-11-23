# ClaudeLimits for Windows — значок в трее с остатком лимитов Claude.
# Читает ~/.claude/limits.json, который пишет statusline.ps1 из Claude Code.
# Запуск: powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ClaudeLimits.ps1

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -Namespace ClaudeLimits -Name Native -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool DestroyIcon(IntPtr hIcon);
[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
'@

# Спрятать консольное окно, если оно всё-таки появилось
[ClaudeLimits.Native]::ShowWindow([ClaudeLimits.Native]::GetConsoleWindow(), 0) | Out-Null

# Только один экземпляр
$createdNew = $false
$mutex = New-Object System.Threading.Mutex($true, 'Local\ClaudeLimitsTray', [ref]$createdNew)
if (-not $createdNew) { exit 0 }

$LimitsFile = Join-Path $env:USERPROFILE '.claude\limits.json'
$StartupLnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'ClaudeLimits.lnk'
$ScriptPath = $MyInvocation.MyCommand.Path
$ConfigFile = Join-Path (Split-Path -Parent $ScriptPath) 'config.json'

# ---------- язык ----------

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
    }
}

# ---------- настройки (config.json) ----------
# { "language": "system|ru|en", "notifications": true, "notified": { "five_hour:80": <resets_at>, ... } }

function Read-Config {
    $cfg = @{ language = 'system'; notifications = $true; notified = @{} }
    try {
        $c = [IO.File]::ReadAllText($ConfigFile) | ConvertFrom-Json
        if (@('system', 'ru', 'en') -contains $c.language) { $cfg.language = $c.language }
        if ($null -ne $c.notifications) { $cfg.notifications = [bool]$c.notifications }
        if ($c.notified) { foreach ($p in $c.notified.PSObject.Properties) { $cfg.notified[$p.Name] = [double]$p.Value } }
    } catch { }
    return $cfg
}

function Save-Config {
    try {
        $json = $script:Config | ConvertTo-Json -Depth 5
        [IO.File]::WriteAllText($ConfigFile, $json, (New-Object Text.UTF8Encoding $false))
    } catch { }
}

$script:Config = Read-Config

function Resolve-Lang([string]$setting) {
    if ($setting -eq 'system') {
        if ((Get-UICulture).TwoLetterISOLanguageName -eq 'ru') { return 'ru' } else { return 'en' }
    }
    return $setting
}

$script:LangSetting = $script:Config.language
$script:T = $Strings[(Resolve-Lang $script:LangSetting)]

# ---------- данные ----------

function Get-Limits {
    if (-not (Test-Path $LimitsFile)) { return $null }
    try {
        $d = [IO.File]::ReadAllText($LimitsFile, [Text.Encoding]::UTF8) | ConvertFrom-Json
    } catch { return $null }
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $res = @{ Updated = [int64]$d.updated_at; Five = $null; Week = $null }
    foreach ($pair in @(@('Five', 'five_hour'), @('Week', 'seven_day'))) {
        $w = $d.rate_limits.($pair[1])
        if ($w) {
            $raw = [double]$w.used_percentage
            $reset = [int64]$w.resets_at
            $used = if ($reset -lt $now) { 0 } else { $raw }   # окно уже сбросилось
            $res[$pair[0]] = @{ Used = $used; RawUsed = $raw; Left = [math]::Max(0, 100 - $used); Reset = $reset }
        }
    }
    return $res
}

function Format-Countdown([int64]$resetAt) {
    $T = $script:T
    $s = $resetAt - [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    if ($s -le 0) { return $T.Done }
    $d = [math]::Floor($s / 86400); $h = [math]::Floor(($s % 86400) / 3600); $m = [math]::Floor(($s % 3600) / 60)
    if ($d -gt 0) { return ($T.InDH -f $d, $h) }
    if ($h -gt 0) { return ($T.InHM -f $h, $m) }
    return ($T.InM -f $m)
}

function Format-Ago([int64]$ts) {
    $T = $script:T
    $s = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - $ts
    if ($s -lt 60) { return $T.JustNow }
    if ($s -lt 3600) { return ($T.MinAgo -f [math]::Floor($s / 60)) }
    if ($s -lt 86400) { return ($T.HAgo -f [math]::Floor($s / 3600)) }
    return ($T.DAgo -f [math]::Floor($s / 86400))
}

# ---------- уведомления ----------

function Send-Notification([string]$title, [string]$body, [string]$kind = 'Info') {
    $tray.BalloonTipTitle = $title
    $tray.BalloonTipText = $body
    $tray.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::$kind
    $tray.ShowBalloonTip(10000)
}

# Проверяет одно окно лимита; каждое уведомление — один раз на окно.
function Test-WindowNotify([string]$key, [hashtable]$w, [bool]$five) {
    $T = $script:T
    $notified = $script:Config.notified
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    function Already([string]$k) { $notified.ContainsKey($k) -and [math]::Abs($notified[$k] - $w.Reset) -lt 1800 }

    if ($now -lt $w.Reset) {
        foreach ($th in @(95, 80)) {
            if ($w.RawUsed -ge $th) {
                if (-not (Already "${key}:$th")) {
                    foreach ($t in @(95, 80)) { if ($t -le $th) { $notified["${key}:$t"] = [double]$w.Reset } }
                    $used = [math]::Round($w.RawUsed)
                    $bodyFmt = if ($five) { $T.LowBodyFive } else { $T.LowBodyWeek }
                    $icon = if ($th -ge 95) { 'Warning' } else { 'Info' }
                    Send-Notification ($T.LowTitle -f [math]::Max(0, 100 - $used)) ($bodyFmt -f $used, (Format-Countdown $w.Reset)) $icon
                    Save-Config
                }
                break
            }
        }
    } elseif (($now - $w.Reset) -lt 900 -and $w.RawUsed -ge 80 -and -not (Already "${key}:reset")) {
        $notified["${key}:reset"] = [double]$w.Reset
        $body = if ($five) { $T.ResetBodyFive } else { $T.ResetBodyWeek }
        Send-Notification $T.ResetTitle $body
        Save-Config
    }
}

function Get-LevelColor([double]$used) {
    if ($used -ge 90) { return [System.Drawing.Color]::FromArgb(220, 53, 69) }
    if ($used -ge 70) { return [System.Drawing.Color]::FromArgb(230, 160, 0) }
    return [System.Drawing.Color]::FromArgb(40, 167, 69)
}

# ---------- иконка с числом ----------

$script:lastIconKey = ''
$script:lastHIcon = [IntPtr]::Zero

function Set-TrayIcon([string]$text, [System.Drawing.Color]$bg) {
    $key = "$text|$($bg.ToArgb())"
    if ($key -eq $script:lastIconKey) { return }
    $script:lastIconKey = $key

    $size = 32
    $bmp = New-Object System.Drawing.Bitmap($size, $size)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $g.TextRenderingHint = 'AntiAliasGridFit'
    $brush = New-Object System.Drawing.SolidBrush($bg)
    $g.FillEllipse($brush, 0, 0, $size - 1, $size - 1)
    $fontSize = if ($text.Length -ge 3) { 11 } else { 15 }
    $font = New-Object System.Drawing.Font('Segoe UI', $fontSize, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
    $sf = New-Object System.Drawing.StringFormat
    $sf.Alignment = 'Center'; $sf.LineAlignment = 'Center'
    $g.DrawString($text, $font, [System.Drawing.Brushes]::White, (New-Object System.Drawing.RectangleF(0, 1, $size, $size)), $sf)
    $g.Dispose(); $font.Dispose(); $brush.Dispose()

    $hIcon = $bmp.GetHicon()
    $tray.Icon = [System.Drawing.Icon]::FromHandle($hIcon)
    $bmp.Dispose()
    if ($script:lastHIcon -ne [IntPtr]::Zero) { [ClaudeLimits.Native]::DestroyIcon($script:lastHIcon) | Out-Null }
    $script:lastHIcon = $hIcon
}

# ---------- трей и меню ----------

[System.Windows.Forms.Application]::EnableVisualStyles()

$tray = New-Object System.Windows.Forms.NotifyIcon
$menu = New-Object System.Windows.Forms.ContextMenuStrip

$miTitle   = $menu.Items.Add('');  $miTitle.Font = New-Object System.Drawing.Font($miTitle.Font, [System.Drawing.FontStyle]::Bold); $miTitle.Enabled = $false
$miFive    = $menu.Items.Add(''); $miFive.Enabled = $false
$miFiveR   = $menu.Items.Add(''); $miFiveR.Enabled = $false
$miWeek    = $menu.Items.Add(''); $miWeek.Enabled = $false
$miWeekR   = $menu.Items.Add(''); $miWeekR.Enabled = $false
$miUpdated = $menu.Items.Add(''); $miUpdated.Enabled = $false
$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null
$miStartup = $menu.Items.Add('')
$miNotif   = $menu.Items.Add('')
$miLang   = New-Object System.Windows.Forms.ToolStripMenuItem
$menu.Items.Add($miLang) | Out-Null
$miLangSys = $miLang.DropDownItems.Add('')
$miLangRu  = $miLang.DropDownItems.Add('Русский')
$miLangEn  = $miLang.DropDownItems.Add('English')
$miQuit    = $menu.Items.Add('')

$tray.ContextMenuStrip = $menu
$tray.Visible = $true

function Update-StaticTexts {
    $T = $script:T
    $miTitle.Text   = $T.Title
    $miStartup.Text = $T.Startup
    $miNotif.Text   = $T.Notifications
    $miNotif.Checked = [bool]$script:Config.notifications
    $miLang.Text    = $T.Language
    $miLangSys.Text = $T.System
    $miQuit.Text    = $T.Quit
    $miLangSys.Checked = ($script:LangSetting -eq 'system')
    $miLangRu.Checked  = ($script:LangSetting -eq 'ru')
    $miLangEn.Checked  = ($script:LangSetting -eq 'en')
}

function Update-UI {
    $T = $script:T
    $l = Get-Limits
    if (-not $l -or (-not $l.Five -and -not $l.Week)) {
        Set-TrayIcon '–' ([System.Drawing.Color]::Gray)
        $tray.Text = $T.TipNoData.Substring(0, [math]::Min(63, $T.TipNoData.Length))
        $miFive.Text = $T.NoDataLong
        $miFiveR.Text = $T.SendMsg
        $miWeek.Visible = $false; $miWeekR.Visible = $false; $miUpdated.Visible = $false
        return
    }
    $miWeek.Visible = $true; $miWeekR.Visible = $true; $miUpdated.Visible = $true

    $worst = 0
    if ($l.Five) {
        $miFive.Text  = ($T.LeftUsed -f $T.Five, [math]::Round($l.Five.Left), [math]::Round($l.Five.Used))
        $miFiveR.Text = '      ' + ($T.Reset -f (Format-Countdown $l.Five.Reset))
        $worst = [math]::Max($worst, $l.Five.Used)
    } else { $miFive.Text = "$($T.Five): $($T.NoData)"; $miFiveR.Text = '' }
    if ($l.Week) {
        $miWeek.Text  = ($T.LeftUsed -f $T.Week, [math]::Round($l.Week.Left), [math]::Round($l.Week.Used))
        $miWeekR.Text = '      ' + ($T.Reset -f (Format-Countdown $l.Week.Reset))
        $worst = [math]::Max($worst, $l.Week.Used)
    } else { $miWeek.Text = "$($T.Week): $($T.NoData)"; $miWeekR.Text = '' }
    $miUpdated.Text = ($T.Updated -f (Format-Ago $l.Updated))

    $main = if ($l.Five) { $l.Five } else { $l.Week }
    Set-TrayIcon ([string][math]::Round($main.Left)) (Get-LevelColor $worst)

    $tip = 'Claude'
    if ($l.Five) { $tip += (' · {0}: {1}%' -f $T.TipFive, [math]::Round($l.Five.Left)) }
    if ($l.Week) { $tip += (' · {0}: {1}%' -f $T.TipWeek, [math]::Round($l.Week.Left)) }
    $tray.Text = $tip.Substring(0, [math]::Min(63, $tip.Length))

    if ($script:Config.notifications) {
        if ($l.Five) { Test-WindowNotify 'five_hour' $l.Five $true }
        if ($l.Week) { Test-WindowNotify 'seven_day' $l.Week $false }
    }
}

function Set-Language([string]$lang) {
    $script:LangSetting = $lang
    $script:T = $Strings[(Resolve-Lang $lang)]
    $script:Config.language = $lang
    Save-Config
    Update-StaticTexts
    Update-UI
}

$miNotif.Add_Click({
    $script:Config.notifications = -not $script:Config.notifications
    Save-Config
    Update-StaticTexts
    if ($script:Config.notifications) { Send-Notification $script:T.NotifOnTitle $script:T.NotifOnBody }
})

$miLangSys.Add_Click({ Set-Language 'system' })
$miLangRu.Add_Click({ Set-Language 'ru' })
$miLangEn.Add_Click({ Set-Language 'en' })

# автозапуск: ярлык в папке «Автозагрузка»
function Update-StartupCheck { $miStartup.Checked = Test-Path $StartupLnk }
$miStartup.Add_Click({
    if (Test-Path $StartupLnk) {
        Remove-Item $StartupLnk -Force
    } else {
        $ws = New-Object -ComObject WScript.Shell
        $lnk = $ws.CreateShortcut($StartupLnk)
        $lnk.TargetPath = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
        $lnk.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$ScriptPath`""
        $lnk.WindowStyle = 7
        $lnk.Save()
    }
    Update-StartupCheck
})

$miQuit.Add_Click({
    $timer.Stop()
    $tray.Visible = $false
    $tray.Dispose()
    [System.Windows.Forms.Application]::Exit()
})

$menu.Add_Opening({ try { Update-UI; Update-StartupCheck } catch { } })

# левый клик тоже открывает меню
$tray.Add_MouseClick({
    param($s, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        $m = [System.Windows.Forms.NotifyIcon].GetMethod('ShowContextMenu', [Reflection.BindingFlags]'Instance,NonPublic')
        $m.Invoke($tray, $null)
    }
})

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 5000
$timer.Add_Tick({ try { Update-UI } catch { } })
$timer.Start()

Update-StaticTexts
Update-UI
Update-StartupCheck
[System.Windows.Forms.Application]::Run()

$mutex.ReleaseMutex()
