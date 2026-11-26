# ClaudeLimits — statusline-команда для Claude Code (Windows).
# Получает JSON сессии на stdin, сохраняет rate_limits в ~/.claude/limits.json
# и печатает короткую строку статуса.
$ErrorActionPreference = 'SilentlyContinue'
try { [Console]::InputEncoding  = [Text.Encoding]::UTF8 } catch { }
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }

$raw = [Console]::In.ReadToEnd()
try { $data = $raw | ConvertFrom-Json } catch { Write-Output '[Claude]'; exit 0 }

$model = 'Claude'
if ($data.model -and $data.model.display_name) { $model = $data.model.display_name }
$rl = $data.rate_limits
if (-not ($rl -is [Management.Automation.PSCustomObject] -and @($rl.PSObject.Properties).Count -gt 0)) { $rl = $null }

function Get-Number($v) {
    if ($v -is [int] -or $v -is [long] -or $v -is [double] -or $v -is [decimal]) {
        $d = [double]$v
        if (-not [double]::IsNaN($d) -and -not [double]::IsInfinity($d)) { return $d }
    }
    return $null
}
function Get-Used($r, $k) { if ($r -and $r.$k) { Get-Number $r.$k.used_percentage } else { $null } }
function Get-Reset($r, $k) { $v = if ($r -and $r.$k) { Get-Number $r.$k.resets_at } else { $null }; if ($null -eq $v) { [int64]0 } else { [int64]$v } }

if ($rl) {
    $userHome = if ($env:USERPROFILE) { $env:USERPROFILE } else { $HOME }
    $dir = Join-Path $userHome '.claude'
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
    $out = [ordered]@{
        updated_at  = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        rate_limits = $rl
        model       = $model
    }
    $json = $out | ConvertTo-Json -Depth 10
    $file = Join-Path $dir 'limits.json'

    # История для графиков: строка в limits-history.jsonl, только если проценты изменились
    $hist = Join-Path $dir 'limits-history.jsonl'
    $old = $null
    if (Test-Path $file) { try { $old = [IO.File]::ReadAllText($file) | ConvertFrom-Json } catch { } }
    $changed = ((Get-Used $old.rate_limits 'five_hour') -ne (Get-Used $rl 'five_hour')) -or
               ((Get-Used $old.rate_limits 'seven_day') -ne (Get-Used $rl 'seven_day'))
    if ($changed -or -not (Test-Path $hist)) {
        $s = [ordered]@{ t = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() }
        if ($rl.five_hour) { $s.f = Get-Used $rl 'five_hour'; $s.fr = Get-Reset $rl 'five_hour' }
        if ($rl.seven_day) { $s.w = Get-Used $rl 'seven_day'; $s.wr = Get-Reset $rl 'seven_day' }
        $utf8 = New-Object Text.UTF8Encoding $false
        [IO.File]::AppendAllText($hist, ($s | ConvertTo-Json -Compress) + "`n", $utf8)
        # Не даём файлу расти: оставляем последние 8 дней
        if ((Get-Item $hist).Length -gt 512KB) {
            $cutoff = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - 8 * 86400
            $kept = [IO.File]::ReadAllLines($hist) | Where-Object { $_ -match '"t":(\d+)' -and [int64]$Matches[1] -ge $cutoff }
            [IO.File]::WriteAllText($hist, (($kept -join "`n") + "`n"), $utf8)
        }
    }
    $tmp  = "$file.tmp"
    [IO.File]::WriteAllText($tmp, $json, (New-Object Text.UTF8Encoding $false))
    Move-Item -Force $tmp $file
}

$parts = @()
foreach ($k in @(@('five_hour', '5h'), @('seven_day', '7d'))) {
    $u = Get-Used $rl $k[0]
    if ($null -ne $u) { $parts += ('{0}: {1}%' -f $k[1], [math]::Round([math]::Min(100.0, [math]::Max(0.0, $u)), [MidpointRounding]::AwayFromZero)) }
}
if ($parts.Count -gt 0) { Write-Output ("[$model] " + ($parts -join ' ')) } else { Write-Output "[$model]" }
