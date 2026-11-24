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
    function Get-Used($r, $k) { if ($r -and $r.$k) { [double]$r.$k.used_percentage } else { $null } }
    $changed = ((Get-Used $old.rate_limits 'five_hour') -ne (Get-Used $rl 'five_hour')) -or
               ((Get-Used $old.rate_limits 'seven_day') -ne (Get-Used $rl 'seven_day'))
    if ($changed -or -not (Test-Path $hist)) {
        $s = [ordered]@{ t = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() }
        if ($rl.five_hour) { $s.f = [double]$rl.five_hour.used_percentage; $s.fr = [int64]$rl.five_hour.resets_at }
        if ($rl.seven_day) { $s.w = [double]$rl.seven_day.used_percentage; $s.wr = [int64]$rl.seven_day.resets_at }
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
if ($rl -and $rl.five_hour) { $parts += ('5h: {0}%' -f [math]::Round([double]$rl.five_hour.used_percentage)) }
if ($rl -and $rl.seven_day) { $parts += ('7d: {0}%' -f [math]::Round([double]$rl.seven_day.used_percentage)) }
if ($parts.Count -gt 0) { Write-Output ("[$model] " + ($parts -join ' ')) } else { Write-Output "[$model]" }
