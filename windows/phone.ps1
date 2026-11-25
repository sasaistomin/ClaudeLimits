# Виджет Claude Limits для iPhone (Scriptable): настройка выгрузки в секретный GitHub Gist.
#   powershell -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\ClaudeLimits\phone.ps1" setup
#   ... phone.ps1 disable   — выключить (сам gist остаётся на GitHub)
#   ... phone.ps1 status    — показать, настроено ли
param([ValidateSet('setup', 'disable', 'status')][string]$Action = 'status')

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ClaudeLimits.Core.ps1')
. (Join-Path $PSScriptRoot 'ClaudeLimits.Phone.ps1')
$path = Get-PhoneConfigPath

switch ($Action) {
    'setup' {
        Write-Host 'Виджет Claude Limits для iPhone (Scriptable)' -ForegroundColor Cyan
        Write-Host 'Нужен токен GitHub с правом «gist»: https://github.com/settings/tokens/new?scopes=gist&description=Claude%20Limits'
        $token = $env:CLAUDE_LIMITS_GITHUB_TOKEN
        if (-not $token) {
            $secure = Read-Host 'Токен (ввод скрыт)' -AsSecureString
            $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
            try { $token = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
        }
        $token = "$token".Trim()
        if (-not $token) { Write-Host 'Токен не введён.' -ForegroundColor Yellow; exit 1 }
        $empty = [ordered]@{ v = 1; sent_at = (Get-UnixNow); sources = [ordered]@{} }
        $api = Get-GitHubApi
        $gistId = $null
        $old = Read-PhoneConfig $path
        if ($old -and $old.token -eq $token) {
            $r = Invoke-GistRequest 'PATCH' "$api/gists/$($old.gist_id)" $token (Get-PhoneGistBody $empty)
            if ($r.Status -eq 200) { $gistId = $old.gist_id }
            elseif ($r.Status -ne 404) { Write-Host (Get-PhoneErrorText $r.Status) -ForegroundColor Red; exit 1 }
        }
        if (-not $gistId) {
            $r = Invoke-GistRequest 'POST' "$api/gists" $token (Get-PhoneGistBody $empty -Create)
            if ($r.Status -ne 201) { Write-Host (Get-PhoneErrorText $r.Status) -ForegroundColor Red; exit 1 }
            $gistId = ($r.Body | ConvertFrom-Json).id
        }
        Save-PhoneConfig $token $gistId $path
        Write-Host ''
        Write-Host "Готово. Настройки: $path" -ForegroundColor Green
        Write-Host "ID для виджета:  $gistId"
        Write-Host 'Вставьте его в поле Parameter виджета Scriptable (или в GIST_ID в начале скрипта).'
        Write-Host 'Значок в трее начнёт выгружать цифры в течение минуты после следующего ответа Claude.'
    }
    'disable' {
        if (Test-Path -LiteralPath $path) {
            Remove-Item -Force -LiteralPath $path
            Write-Host 'Выгрузка для виджета выключена. Сам gist можно удалить на https://gist.github.com/'
        } else { Write-Host 'Выгрузка для виджета и так не настроена.' }
    }
    default {
        $c = Read-PhoneConfig $path
        if ($c) { Write-Host "Настроено, ID для виджета: $($c.gist_id)" } else { Write-Host 'Не настроено. Запустите: phone.ps1 setup' }
    }
}
