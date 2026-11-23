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
            $used = [double]$w.used_percentage
            $reset = [int64]$w.resets_at
            if ($reset -lt $now) { $used = 0 }   # окно уже сбросилось
            $res[$pair[0]] = @{ Used = $used; Left = [math]::Max(0, 100 - $used); Reset = $reset }
        }
    }
    return $res
}

function Format-Countdown([int64]$resetAt) {
    $s = $resetAt - [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    if ($s -le 0) { return 'сброшен' }
    $d = [math]::Floor($s / 86400); $h = [math]::Floor(($s % 86400) / 3600); $m = [math]::Floor(($s % 3600) / 60)
    if ($d -gt 0) { return "через $d д $h ч" }
    if ($h -gt 0) { return "через $h ч $m мин" }
    return "через $m мин"
}

function Format-Ago([int64]$ts) {
    $s = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - $ts
    if ($s -lt 60) { return 'только что' }
    if ($s -lt 3600) { return ('{0} мин назад' -f [math]::Floor($s / 60)) }
    if ($s -lt 86400) { return ('{0} ч назад' -f [math]::Floor($s / 3600)) }
    return ('{0} д назад' -f [math]::Floor($s / 86400))
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

$miTitle   = $menu.Items.Add('Лимиты Claude');  $miTitle.Font = New-Object System.Drawing.Font($miTitle.Font, [System.Drawing.FontStyle]::Bold); $miTitle.Enabled = $false
$miFive    = $menu.Items.Add('5 часов: нет данных'); $miFive.Enabled = $false
$miFiveR   = $menu.Items.Add(''); $miFiveR.Enabled = $false
$miWeek    = $menu.Items.Add('Неделя: нет данных'); $miWeek.Enabled = $false
$miWeekR   = $menu.Items.Add(''); $miWeekR.Enabled = $false
$miUpdated = $menu.Items.Add(''); $miUpdated.Enabled = $false
$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null
$miStartup = $menu.Items.Add('Запускать при входе в Windows')
$miQuit    = $menu.Items.Add('Выход')

$tray.ContextMenuStrip = $menu
$tray.Visible = $true

function Update-UI {
    $l = Get-Limits
    if (-not $l -or (-not $l.Five -and -not $l.Week)) {
        Set-TrayIcon '–' ([System.Drawing.Color]::Gray)
        $tray.Text = 'Claude: нет данных — напишите в Claude Code'
        $miFive.Text = 'Пока нет данных.'
        $miFiveR.Text = 'Отправьте любое сообщение в Claude Code.'
        $miWeek.Visible = $false; $miWeekR.Visible = $false; $miUpdated.Visible = $false
        return
    }
    $miWeek.Visible = $true; $miWeekR.Visible = $true; $miUpdated.Visible = $true

    $worst = 0
    if ($l.Five) {
        $miFive.Text  = ('5 часов: осталось {0}%  (использовано {1}%)' -f [math]::Round($l.Five.Left), [math]::Round($l.Five.Used))
        $miFiveR.Text = '      сброс ' + (Format-Countdown $l.Five.Reset)
        $worst = [math]::Max($worst, $l.Five.Used)
    } else { $miFive.Text = '5 часов: нет данных'; $miFiveR.Text = '' }
    if ($l.Week) {
        $miWeek.Text  = ('Неделя: осталось {0}%  (использовано {1}%)' -f [math]::Round($l.Week.Left), [math]::Round($l.Week.Used))
        $miWeekR.Text = '      сброс ' + (Format-Countdown $l.Week.Reset)
        $worst = [math]::Max($worst, $l.Week.Used)
    } else { $miWeek.Text = 'Неделя: нет данных'; $miWeekR.Text = '' }
    $miUpdated.Text = 'Обновлено ' + (Format-Ago $l.Updated)

    $main = if ($l.Five) { $l.Five } else { $l.Week }
    Set-TrayIcon ([string][math]::Round($main.Left)) (Get-LevelColor $worst)

    $tip = 'Claude'
    if ($l.Five) { $tip += (' · 5ч: {0}%' -f [math]::Round($l.Five.Left)) }
    if ($l.Week) { $tip += (' · неделя: {0}%' -f [math]::Round($l.Week.Left)) }
    $tray.Text = $tip.Substring(0, [math]::Min(63, $tip.Length))
}

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

$menu.Add_Opening({ Update-UI; Update-StartupCheck })

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

Update-UI
Update-StartupCheck
[System.Windows.Forms.Application]::Run()

$mutex.ReleaseMutex()
