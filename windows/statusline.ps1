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
    $dir = Join-Path $env:USERPROFILE '.claude'
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
    $out = [ordered]@{
        updated_at  = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        rate_limits = $rl
        model       = $model
    }
    $json = $out | ConvertTo-Json -Depth 10
    $file = Join-Path $dir 'limits.json'
    $tmp  = "$file.tmp"
    [IO.File]::WriteAllText($tmp, $json, (New-Object Text.UTF8Encoding $false))
    Move-Item -Force $tmp $file
}

$parts = @()
if ($rl -and $rl.five_hour) { $parts += ('5h: {0}%' -f [math]::Round([double]$rl.five_hour.used_percentage)) }
if ($rl -and $rl.seven_day) { $parts += ('7d: {0}%' -f [math]::Round([double]$rl.seven_day.used_percentage)) }
if ($parts.Count -gt 0) { Write-Output ("[$model] " + ($parts -join ' ')) } else { Write-Output "[$model]" }
