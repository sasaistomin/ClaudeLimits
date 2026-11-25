# ClaudeLimits for Windows — значок в трее с остатком лимитов Claude (вкладки «Claude Code» и «Claude Desktop»).
# UI-слой: данные приходят от LimitMonitoringService (фоновые runspace), настройки — из config.json.
# Запуск: powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ClaudeLimits.ps1

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -Namespace ClaudeLimits -Name Native -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool DestroyIcon(IntPtr hIcon);
[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
'@

$SelfTest = [bool]$env:CLAUDE_LIMITS_SELFTEST   # автотест: прогнать интерфейс и выйти

# Спрятать консольное окно, если оно всё-таки появилось
if (-not $SelfTest) { [ClaudeLimits.Native]::ShowWindow([ClaudeLimits.Native]::GetConsoleWindow(), 0) | Out-Null }

# Только один экземпляр
$createdNew = $false
$mutexName = if ($SelfTest) { "Local\ClaudeLimitsSelfTest$PID" } else { 'Local\ClaudeLimitsTray' }
$mutex = New-Object System.Threading.Mutex($true, $mutexName, [ref]$createdNew)
if (-not $createdNew) { exit 0 }

$StartupDir = if ($env:CLAUDE_LIMITS_STARTUP_DIR) { $env:CLAUDE_LIMITS_STARTUP_DIR } else { [Environment]::GetFolderPath('Startup') }
$StartupLnk = Join-Path $StartupDir 'ClaudeLimits.lnk'
$ScriptPath = $MyInvocation.MyCommand.Path
$ConfigFile = Join-Path (Split-Path -Parent $ScriptPath) 'config.json'

. (Join-Path $PSScriptRoot 'ClaudeLimits.Core.ps1')
. (Join-Path $PSScriptRoot 'ClaudeLimits.Monitoring.ps1')
. (Join-Path $PSScriptRoot 'ClaudeLimits.Phone.ps1')

$HistoryFiles = @{
    code    = Join-Path $env:USERPROFILE '.claude\limits-history.jsonl'
    desktop = Join-Path $env:USERPROFILE '.claude\limits-desktop-history.jsonl'
}
$script:Config = Read-Config $ConfigFile
$script:Phone = New-PhoneSync
$script:LangSetting = $script:Config.language
$script:T = $Strings[(Resolve-Lang $script:LangSetting)]

function Save-Settings { Save-Config $script:Config $ConfigFile }
function Get-ActiveSource { $Sources[$script:Config.active_tab] }

$script:Monitor = [LimitMonitoringService]::new((Join-Path $PSScriptRoot 'ClaudeLimits.Parsers.ps1'))

# ---------- уведомления ----------

function Send-Notification([string]$title, [string]$body, [string]$kind = 'Info') {
    $tray.BalloonTipTitle = $title
    $tray.BalloonTipText = $body
    $tray.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::$kind
    $tray.ShowBalloonTip(10000)
}

# Каждое уведомление — один раз на окно и источник (правила — в Core).
function Test-SourceNotify([string]$source) {
    if (-not $script:Config.notifications) { return }
    $m = $script:Monitor.Latest[$source]
    if (-not $m -or $m.Status -ne 'Ok') { return }
    foreach ($w in $m.Windows) {
        $ev = Get-NotifyEvent (Get-NotifyKey $source $w) $w $script:Config.notified (Get-UnixNow) (Get-NotifyThresholds $w)
        if ($ev) {
            $n = Format-Notification $ev $w $source $script:T
            Send-Notification $n.Title $n.Body $n.Icon
            Save-Settings
        }
    }
}

function Get-LevelColor([double]$used) {
    switch (Get-Level $used) {
        'red'    { return [System.Drawing.Color]::FromArgb(220, 53, 69) }
        'yellow' { return [System.Drawing.Color]::FromArgb(230, 160, 0) }
        default  { return [System.Drawing.Color]::FromArgb(40, 167, 69) }
    }
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

# ---------- окно с графиком ----------

$script:ChartCtl = $null
$script:ChartModel = $null
$script:ChartKind = 'five'
$script:HoverX = -1
$AccentColor = [System.Drawing.Color]::FromArgb(0, 120, 215)

function Get-CurrentChartModel {
    $id = if ($script:ChartKind -eq 'five') { 'five_hour' } else { 'seven_day' }
    $source = Get-ActiveSource
    Get-ChartModel (Get-MetricsWindow $script:Monitor.Latest[$source] $id) (Read-History $HistoryFiles[$source])
}

function Draw-Chart($g, [int]$W, [int]$H) {
    $g.SmoothingMode = 'AntiAlias'
    $g.Clear([System.Drawing.Color]::White)
    $m = $script:ChartModel
    if (-not $m) { return }

    $L = 40; $R = $W - 12; $Tp = 12; $B = $H - 24
    $span = [double]($m.End - $m.Start)
    $xOf = { param($t) [single]($L + ($t - $m.Start) / $span * ($R - $L)) }
    $yOf = { param($v) [single]($B - $v / 100.0 * ($B - $Tp)) }
    $culture = [Globalization.CultureInfo]::GetCultureInfo($script:T.Culture)
    $font = New-Object System.Drawing.Font('Segoe UI', 8)
    $inkMuted = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(110, 110, 110))
    $gridPen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(230, 230, 230), 1)
    $limitPen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(150, 220, 53, 69), 1)
    $limitPen.DashStyle = 'Dash'

    # Ось Y: 0 / 50 / 100 %
    $sfR = New-Object System.Drawing.StringFormat; $sfR.Alignment = 'Far'; $sfR.LineAlignment = 'Center'
    foreach ($v in @(0, 50, 100)) {
        $y = & $yOf $v
        $pen = if ($v -eq 100) { $limitPen } else { $gridPen }
        $g.DrawLine($pen, $L, $y, $R, $y)
        $g.DrawString("$v%", $font, $inkMuted, (New-Object System.Drawing.RectangleF(0, ($y - 8), ($L - 4), 16)), $sfR)
    }

    # Ось X: часы (5 ч) или дни (неделя)
    $sfC = New-Object System.Drawing.StringFormat; $sfC.Alignment = 'Center'
    $d0 = ConvertTo-LocalTime $m.Start
    if ($m.Five) { $d = $d0.Date.AddHours($d0.Hour + 1); $step = { param($x) $x.AddHours(1) } }
    else         { $d = $d0.Date.AddDays(1);              $step = { param($x) $x.AddDays(1) } }
    while ($true) {
        $t = ([DateTimeOffset]$d).ToUnixTimeSeconds()
        if ($t -ge $m.End) { break }
        $x = & $xOf $t
        $g.DrawLine($gridPen, $x, $Tp, $x, $B)
        if ($m.Five) { $label = $d.ToString('HH', $culture); $lx = $x }
        else { $label = $d.ToString('ddd', $culture); $lx = [math]::Min($R - 10, (& $xOf ($t + 43200))) }
        $g.DrawString($label, $font, $inkMuted, (New-Object System.Drawing.RectangleF(($lx - 20), ($B + 4), 40, 16)), $sfC)
        $d = & $step $d
    }

    # Ступенчатая линия расхода + заливка
    $pts = $m.Points
    $line = New-Object 'System.Collections.Generic.List[System.Drawing.PointF]'
    for ($i = 0; $i -lt $pts.Count; $i++) {
        $x = & $xOf $pts[$i][0]; $y = & $yOf $pts[$i][1]
        if ($i -gt 0) { $line.Add((New-Object System.Drawing.PointF($x, $line[$line.Count - 1].Y))) }
        $line.Add((New-Object System.Drawing.PointF($x, $y)))
    }
    $area = New-Object 'System.Collections.Generic.List[System.Drawing.PointF]' (, $line)
    $area.Add((New-Object System.Drawing.PointF($line[$line.Count - 1].X, $B)))
    $area.Add((New-Object System.Drawing.PointF($line[0].X, $B)))
    $fill = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(45, $AccentColor))
    $g.FillPolygon($fill, $area.ToArray())
    $linePen = New-Object System.Drawing.Pen($AccentColor, 2)
    $g.DrawLines($linePen, $line.ToArray())

    # Прогноз — пунктир от «сейчас»
    if ($m.Rate -gt 0) {
        if ($m.RunOut) { $endT = $m.RunOut; $endV = 100 }
        else { $endT = $m.End; $endV = [math]::Min(100, $m.Used + $m.Rate * ($m.End - $m.Now)) }
        $fcPen = New-Object System.Drawing.Pen([System.Drawing.Color]::Gray, 1.5)
        $fcPen.DashStyle = 'Dash'
        $g.DrawLine($fcPen, (& $xOf $m.Now), (& $yOf $m.Used), (& $xOf $endT), (& $yOf $endV))
        $fcPen.Dispose()
    }

    # Наведение мышью: значение в выбранный момент
    $hx = $script:HoverX
    $xNow = & $xOf $m.Now
    if ($hx -ge $L -and $hx -le $xNow) {
        $t = $m.Start + ($hx - $L) / [double]($R - $L) * $span
        $v = 0.0
        foreach ($p in $pts) { if ($p[0] -le $t) { $v = $p[1] } }
        $hy = & $yOf $v
        $g.DrawLine($gridPen, $hx, $Tp, $hx, $B)
        $g.FillEllipse((New-Object System.Drawing.SolidBrush($AccentColor)), ($hx - 4), ($hy - 4), 8, 8)
        $fmt = if ($m.Five) { 'HH:mm' } else { 'ddd HH:mm' }
        $txt = '{0}% · {1}' -f [math]::Round($v), (ConvertTo-LocalTime ([int64]$t)).ToString($fmt, $culture)
        $sz = $g.MeasureString($txt, $font)
        $bx = [math]::Min($R - $sz.Width - 6, [math]::Max($L, $hx - $sz.Width / 2 - 3))
        $by = [math]::Max(0, $hy - $sz.Height - 10)
        $g.FillRectangle([System.Drawing.Brushes]::White, $bx, $by, ($sz.Width + 6), ($sz.Height + 2))
        $g.DrawRectangle($gridPen, $bx, $by, ($sz.Width + 6), ($sz.Height + 2))
        $g.DrawString($txt, $font, [System.Drawing.Brushes]::Black, ($bx + 3), ($by + 1))
    }

    $font.Dispose(); $inkMuted.Dispose(); $gridPen.Dispose(); $limitPen.Dispose(); $fill.Dispose(); $linePen.Dispose()
}

function Update-Chart {
    $c = $script:ChartCtl
    if (-not $c -or $c.Form.IsDisposed) { return }
    $T = $script:T
    $five = $script:ChartKind -eq 'five'
    $c.Form.Text = $T.ChartTitle
    $c.B5.Text = $T.Tab5h; $c.BW.Text = $T.TabWeek
    $c.B5.Font = New-Object System.Drawing.Font($c.Form.Font, $(if ($five) { 'Bold' } else { 'Regular' }))
    $c.BW.Font = New-Object System.Drawing.Font($c.Form.Font, $(if ($five) { 'Regular' } else { 'Bold' }))

    $script:ChartModel = Get-CurrentChartModel
    $m = $script:ChartModel
    $c.Lbl.ForeColor = [System.Drawing.Color]::DimGray
    if (-not $m) {
        $c.Lbl.Text = $T.ChartNoData
    } elseif ($m.Rate -le 0) {
        $c.Lbl.Text = ''
    } elseif ($m.RunOut) {
        $culture = [Globalization.CultureInfo]::GetCultureInfo($T.Culture)
        $fmt = if ($five) { 'HH:mm' } else { 'ddd HH:mm' }
        $when = (ConvertTo-LocalTime $m.RunOut).ToString($fmt, $culture)
        $c.Lbl.Text = $(if ($five) { $T.ForecastAt5 } else { $T.ForecastAtWeek }) -f $when
        $c.Lbl.ForeColor = [System.Drawing.Color]::FromArgb(200, 40, 50)
    } else {
        $c.Lbl.Text = $T.ForecastOK
    }
    $c.Pic.Invalidate()
}

function Show-ChartForm {
    if ($script:ChartCtl -and -not $script:ChartCtl.Form.IsDisposed) { $script:ChartCtl.Form.Activate(); return }

    $f = New-Object System.Windows.Forms.Form
    $f.ClientSize = New-Object System.Drawing.Size(500, 300)
    $f.StartPosition = 'CenterScreen'
    $f.FormBorderStyle = 'FixedSingle'
    $f.MaximizeBox = $false
    $f.BackColor = [System.Drawing.Color]::White
    $f.Font = New-Object System.Drawing.Font('Segoe UI', 9)

    $b5 = New-Object System.Windows.Forms.Button
    $b5.Location = New-Object System.Drawing.Point(12, 10); $b5.Size = New-Object System.Drawing.Size(100, 28)
    $bW = New-Object System.Windows.Forms.Button
    $bW.Location = New-Object System.Drawing.Point(116, 10); $bW.Size = New-Object System.Drawing.Size(100, 28)

    $pic = New-Object System.Windows.Forms.PictureBox
    $pic.Location = New-Object System.Drawing.Point(12, 48); $pic.Size = New-Object System.Drawing.Size(476, 210)

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Location = New-Object System.Drawing.Point(12, 264); $lbl.Size = New-Object System.Drawing.Size(476, 32)

    $f.Controls.AddRange(@($b5, $bW, $pic, $lbl))
    $script:ChartCtl = @{ Form = $f; B5 = $b5; BW = $bW; Pic = $pic; Lbl = $lbl }

    $b5.Add_Click({ $script:ChartKind = 'five'; Update-Chart })
    $bW.Add_Click({ $script:ChartKind = 'week'; Update-Chart })
    $pic.Add_Paint({ param($s, $e) try { Draw-Chart $e.Graphics $s.Width $s.Height } catch { } })
    $pic.Add_MouseMove({ param($s, $e) $script:HoverX = $e.X; $s.Invalidate() })
    $pic.Add_MouseLeave({ param($s, $e) $script:HoverX = -1; $s.Invalidate() })
    $f.Add_FormClosed({ $script:ChartCtl = $null })

    Update-Chart
    $f.Show()
    $f.Activate()
}

# ---------- трей и меню ----------

[System.Windows.Forms.Application]::EnableVisualStyles()

$tray = New-Object System.Windows.Forms.NotifyIcon
$menu = New-Object System.Windows.Forms.ContextMenuStrip

$miTitle   = $menu.Items.Add('');  $miTitle.Font = New-Object System.Drawing.Font($miTitle.Font, [System.Drawing.FontStyle]::Bold); $miTitle.Enabled = $false

$tabPanel = New-Object System.Windows.Forms.TableLayoutPanel
$tabPanel.Size = New-Object System.Drawing.Size(260, 28)
$tabPanel.ColumnCount = $Sources.Count
$tabPanel.BackColor = [System.Drawing.Color]::Transparent
$tabButtons = @()
for ($i = 0; $i -lt $Sources.Count; $i++) {
    [void]$tabPanel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, (100 / $Sources.Count))))
    $b = New-Object System.Windows.Forms.RadioButton
    $b.Appearance = 'Button'; $b.FlatStyle = 'Flat'; $b.TextAlign = 'MiddleCenter'
    $b.Dock = 'Fill'; $b.Margin = New-Object System.Windows.Forms.Padding(0)
    $b.FlatAppearance.BorderColor = $AccentColor
    $b.FlatAppearance.CheckedBackColor = $AccentColor
    $b.Text = $SourceNames[$Sources[$i]]; $b.Tag = $i
    $b.Add_Click({ param($s, $e) Set-ActiveTab ([int]$s.Tag) })
    $tabPanel.Controls.Add($b, $i, 0)
    $tabButtons += $b
}
$miTabs = New-Object System.Windows.Forms.ToolStripControlHost($tabPanel)
$miTabs.AutoSize = $false
$miTabs.Size = $tabPanel.Size
$miTabs.Margin = New-Object System.Windows.Forms.Padding(6, 2, 6, 4)
$menu.Items.Add($miTabs) | Out-Null

$miRows    = @(foreach ($i in 1..4) { $r = $menu.Items.Add(''); $r.Enabled = $false; $r })
$miUpdated = $menu.Items.Add(''); $miUpdated.Enabled = $false
$sepChart  = New-Object System.Windows.Forms.ToolStripSeparator
$menu.Items.Add($sepChart) | Out-Null
$miChart   = $menu.Items.Add('')
$miChart.Font = New-Object System.Drawing.Font($miChart.Font, [System.Drawing.FontStyle]::Bold)
$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null
$miDesktop     = New-Object System.Windows.Forms.ToolStripMenuItem
$menu.Items.Add($miDesktop) | Out-Null
$miDesktopPath = $miDesktop.DropDownItems.Add(''); $miDesktopPath.Enabled = $false
$miDesktopAuto = $miDesktop.DropDownItems.Add('')
$miDesktopPick = $miDesktop.DropDownItems.Add('')
$miStartup = $menu.Items.Add('')
$miNotif  = $menu.Items.Add('')
$miLang   = New-Object System.Windows.Forms.ToolStripMenuItem
$menu.Items.Add($miLang) | Out-Null
$miLangSys = $miLang.DropDownItems.Add('')
$miLangRu  = $miLang.DropDownItems.Add('Русский')
$miLangEn  = $miLang.DropDownItems.Add('English')
$miUpdate  = $menu.Items.Add('')
$miQuit    = $menu.Items.Add('')

$tray.ContextMenuStrip = $menu
$tray.Visible = $true

function Update-StaticTexts {
    $T = $script:T
    $miTitle.Text   = $T.Title
    $miChart.Text   = $T.Chart
    $miStartup.Text = $T.Startup
    $miDesktop.Text = $T.DesktopFolder
    $miDesktopAuto.Text = $T.DesktopAuto
    $miDesktopPick.Text = $T.DesktopPick
    $miDesktopAuto.Checked = -not $script:Config.desktop_path
    $miNotif.Text   = $T.Notifications
    $miNotif.Checked = [bool]$script:Config.notifications
    $miLang.Text    = $T.Language
    $miLangSys.Text = $T.System
    $miQuit.Text    = $T.Quit
    Set-UpdateState $script:UpdateState.Kind $script:UpdateState.Version
    $miLangSys.Checked = ($script:LangSetting -eq 'system')
    $miLangRu.Checked  = ($script:LangSetting -eq 'ru')
    $miLangEn.Checked  = ($script:LangSetting -eq 'en')
}

function Update-Tabs {
    $active = $script:Config.active_tab
    for ($i = 0; $i -lt $tabButtons.Count; $i++) {
        $b = $tabButtons[$i]
        $b.Checked = ($i -eq $active)
        $b.ForeColor = if ($b.Checked) { [System.Drawing.Color]::White } else { [System.Drawing.SystemColors]::ControlText }
        $b.BackColor = if ($b.Checked) { $AccentColor } else { [System.Drawing.SystemColors]::Window }
    }
}

function Set-Rows([string[]]$lines) {
    for ($i = 0; $i -lt $miRows.Count; $i++) {
        $text = if ($i -lt $lines.Count) { $lines[$i] } else { '' }
        $miRows[$i].Text = $text
        $miRows[$i].Visible = [bool]$text
    }
}

function Update-UI {
    $T = $script:T
    $source = Get-ActiveSource
    $m = $script:Monitor.Latest[$source]
    Update-Tabs
    $desktop = $script:Monitor.Latest['desktop']
    $miDesktopPath.Text = if ($desktop -and $desktop.LogPath) { $desktop.LogPath } else { $T.DesktopNoPath }
    $tray.Text = Get-TrayTooltip @($script:Monitor.Latest['code'], $desktop) $T

    if (-not $m -or $m.Status -ne 'Ok' -or $m.Windows.Count -eq 0) {
        Set-TrayIcon '–' ([System.Drawing.Color]::Gray)
        Set-Rows (Get-EmptyStateLines $source $m $T)
        $miUpdated.Visible = $false
        return
    }

    $lines = @(); $worst = 0
    foreach ($w in $m.Windows) {
        $lines += Format-WindowLines $w $T
        $worst = [math]::Max($worst, $w.Used)
    }
    Set-Rows $lines
    $miUpdated.Visible = $true
    $miUpdated.Text = ($T.Updated -f (Format-Ago $m.Updated $T))
    Set-TrayIcon ([string][math]::Round($m.Windows[0].Left)) (Get-LevelColor $worst)
}

function Set-ActiveTab([int]$index) {
    if ($script:Config.active_tab -ne $index) {
        $script:Config.active_tab = $index
        Save-Settings
    }
    Update-UI
    Update-Chart
}

function Set-DesktopPath([string]$path) {
    $script:Config.desktop_path = $path
    Save-Settings
    $script:Monitor.Watch('desktop', $path)
    Update-StaticTexts
    Update-UI
}

function Set-Language([string]$lang) {
    $script:LangSetting = $lang
    $script:T = $Strings[(Resolve-Lang $lang)]
    $script:Config.language = $lang
    Save-Settings
    Update-StaticTexts
    Update-UI
    Update-Chart
}

$miChart.Add_Click({ Show-ChartForm })

$miDesktopAuto.Add_Click({ if ($script:Config.desktop_path) { Set-DesktopPath '' } })
$miDesktopPick.Add_Click({
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    try {
        $dlg.Description = $script:T.DesktopPickTitle
        $dlg.ShowNewFolderButton = $false
        if ($script:Config.desktop_path -and (Test-Path -LiteralPath $script:Config.desktop_path)) { $dlg.SelectedPath = $script:Config.desktop_path }
        elseif ($env:APPDATA) { $dlg.SelectedPath = $env:APPDATA }
        if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { Set-DesktopPath $dlg.SelectedPath }
    } catch { } finally { $dlg.Dispose() }
})

$miNotif.Add_Click({
    $script:Config.notifications = -not $script:Config.notifications
    Save-Settings
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

# ---------- обновления ----------

$script:UpdateState = @{ Kind = 'idle'; Version = $null }
$script:UpdateJob = $null

function Set-UpdateState([string]$kind, [string]$version) {
    $script:UpdateState = @{ Kind = $kind; Version = $version }
    $T = $script:T
    $miUpdate.Text = switch ($kind) {
        'checking'   { $T.CheckingUpdates }
        'current'    { $T.UpToDate -f (Get-InstalledVersion $PSScriptRoot) }
        'available'  { $T.UpdateTo -f $version }
        'failed'     { $T.UpdateFailed }
        'installing' { $T.InstallingUpdate }
        default      { $T.CheckUpdates }
    }
    $miUpdate.Enabled = $kind -ne 'checking' -and $kind -ne 'installing'
}

function Start-UpdateCheck {
    Set-UpdateState 'checking'
    $shell = [powershell]::Create()
    $def = ${function:Get-RemoteVersion}.ToString()
    [void]$shell.AddScript("function Get-RemoteVersion { $def }`nGet-RemoteVersion `$args[0]").AddArgument("$(Get-RepoRaw)/VERSION")
    $script:UpdateJob = @{ Shell = $shell; Handle = $shell.BeginInvoke() }
}

function Complete-UpdateCheck {
    $job = $script:UpdateJob
    if (-not $job -or -not $job.Handle.IsCompleted) { return }
    $script:UpdateJob = $null
    try {
        $remote = [string](@($job.Shell.EndInvoke($job.Handle)) | Select-Object -Last 1)
        if ($job.Shell.HadErrors -or -not $remote) { Set-UpdateState 'failed' }
        elseif (Test-NewerVersion $remote (Get-InstalledVersion $PSScriptRoot)) { Set-UpdateState 'available' $remote }
        else { Set-UpdateState 'current' }
    } catch { Set-UpdateState 'failed' } finally { $job.Shell.Dispose() }
}

$miUpdate.Add_Click({
    if ($script:UpdateState.Kind -eq 'available') {
        Set-UpdateState 'installing' $script:UpdateState.Version
        Start-Process -FilePath "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList (Get-UpdateArguments) -WindowStyle Hidden
    } else {
        Start-UpdateCheck
    }
})

$miQuit.Add_Click({
    $timer.Stop()
    Stop-PhoneSync $script:Phone
    $script:Monitor.Dispose()
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

foreach ($source in $Sources) {
    $script:Monitor.Subscribe($source, {
        param($m)
        if ($m.Source -eq 'desktop') { [void](Add-MetricsHistory $m $HistoryFiles.desktop) }
        $script:Phone.Pending = $script:Monitor.Latest.Clone()
        Test-SourceNotify $m.Source
        if ($m.Source -eq (Get-ActiveSource)) { Update-UI }
        if ($m.Source -eq (Get-ActiveSource) -and $script:ChartCtl) { Update-Chart }
    })
}
$script:Monitor.Watch('code', '')
$script:Monitor.Watch('desktop', $script:Config.desktop_path)

$script:Tick = 0
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 1000
$timer.Add_Tick({
    try { [void]$script:Monitor.Dispatch() } catch { }
    try { Complete-UpdateCheck } catch { }
    try { Complete-PhoneSync $script:Phone } catch { }
    $script:Tick++
    if ($script:Tick % 5 -ne 0) { return }
    try { Update-UI; foreach ($source in $Sources) { Test-SourceNotify $source } } catch { }
    try { [void](Step-PhoneSync $script:Phone) } catch { }
    if ($script:ChartCtl) { try { Update-Chart } catch { } }
})
$timer.Start()

Update-StaticTexts
Update-UI
Update-StartupCheck

if ($SelfTest) {
    # Автотест (CI): прогоняем весь интерфейс без показа пользователю; любая ошибка -> код выхода 1
    try {
        if (-not $script:Monitor.WaitForAll(30000)) {
            throw ('monitoring timeout: ' + (($Sources | ForEach-Object { "$_=" + $script:Monitor.Fault($_) }) -join '; '))
        }
        foreach ($lang in @('en', 'ru', 'system')) { Set-Language $lang }
        $tabs = @()
        for ($i = $Sources.Count - 1; $i -ge 0; $i--) {
            Set-ActiveTab $i
            $tabs += '{0}: {1}' -f $Sources[$i], $miRows[0].Text
        }
        $script:Monitor.Watch('desktop', (Join-Path ([IO.Path]::GetTempPath()) "cl-missing-$PID"))
        if (-not $script:Monitor.WaitForAll(10000)) { throw 'monitoring timeout after desktop path change' }
        Set-ActiveTab 1
        if ($miRows[0].Text -ne $script:T.DesktopNotFound) { throw "desktop not-found state: $($miRows[0].Text)" }
        Set-ActiveTab 0
        Update-UI
        Update-StartupCheck
        Show-ChartForm
        foreach ($k in @('five', 'week')) {
            $script:ChartKind = $k
            Update-Chart
            $script:HoverX = 300
            $bmp = New-Object System.Drawing.Bitmap(476, 210)
            $g = [System.Drawing.Graphics]::FromImage($bmp)
            Draw-Chart $g 476 210
            if ($env:CLAUDE_LIMITS_SELFTEST_OUT) { $bmp.Save((Join-Path $env:CLAUDE_LIMITS_SELFTEST_OUT "chart-$k.png")) }
            $g.Dispose(); $bmp.Dispose()
        }
        $label = $script:ChartCtl.Lbl.Text
        $script:ChartCtl.Form.Close()
        Send-Notification $script:T.NotifOnTitle $script:T.NotifOnBody
        Write-Output "SELFTEST OK | tooltip: $($tray.Text) | $($tabs -join ' | ') | chart: $label"
        $code = 0
    } catch {
        Write-Output "SELFTEST FAIL: $($_.Exception.Message) at $($_.InvocationInfo.PositionMessage)"
        $code = 1
    }
    $timer.Stop(); $script:Monitor.Dispose(); $tray.Visible = $false; $tray.Dispose()
    $mutex.ReleaseMutex()
    exit $code
}

[System.Windows.Forms.Application]::Run()

$script:Monitor.Dispose()

$mutex.ReleaseMutex()
