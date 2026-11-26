# ClaudeLimits — виджет на телефоне (Scriptable): лимиты выгружаются в секретный GitHub Gist,
# виджет на iPhone читает его по ID. Настройки — %USERPROFILE%\.claude\limits-phone.json {"token", "gist_id"}.
# Настройка — phone.ps1 setup; значок в трее выгружает данные сам (Step-PhoneSync), не чаще раза в минуту
# и только когда цифры изменились.

$PhoneGistFile = 'claude-limits.json'
$PhoneMinInterval = 60
$PhoneRetryAfter = 300

function Get-PhoneConfigPath {
    $h = if ($env:USERPROFILE) { $env:USERPROFILE } else { [Environment]::GetFolderPath('UserProfile') }
    return Join-Path (Join-Path $h '.claude') 'limits-phone.json'
}

function Get-GitHubApi {
    $base = if ($env:CLAUDE_LIMITS_GITHUB_API) { $env:CLAUDE_LIMITS_GITHUB_API } else { 'https://api.github.com' }
    return $base.TrimEnd('/')
}

function Read-PhoneConfig([string]$Path = (Get-PhoneConfigPath)) {
    try {
        if (-not (Test-Path -LiteralPath $Path)) { return $null }
        $c = [IO.File]::ReadAllText($Path) | ConvertFrom-Json
        if ($c.token -is [string] -and $c.token -and $c.gist_id -is [string] -and $c.gist_id) {
            return @{ token = $c.token; gist_id = $c.gist_id }
        }
    } catch { }
    return $null
}

function Save-PhoneConfig([string]$Token, [string]$GistId, [string]$Path = (Get-PhoneConfigPath)) {
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $json = [ordered]@{ token = $Token; gist_id = $GistId } | ConvertTo-Json
    [IO.File]::WriteAllText($Path, $json, (New-Object Text.UTF8Encoding $false))
}

# Снимок для виджета: только источники с данными, проценты как есть (виджет сам обнуляет прошедшие окна).
function Get-PhonePayload([hashtable]$Metrics, [int64]$Now = (Get-UnixNow)) {
    $bySource = [ordered]@{}
    foreach ($source in $Sources) {
        $m = $Metrics[$source]
        if (-not $m -or $m.Status -ne 'Ok' -or @($m.Windows).Count -eq 0) { continue }
        $bySource[$source] = [ordered]@{
            updated = [int64]$m.Updated
            windows = @(foreach ($w in $m.Windows) {
                [ordered]@{ id = $w.Id; used = [double]$w.RawUsed; resets_at = [int64]$w.Reset; rolling = [bool]$w.Rolling }
            })
        }
    }
    return [ordered]@{ v = 1; sent_at = $Now; sources = $bySource }
}

function Get-PhonePayloadKey($Payload) { $Payload.sources | ConvertTo-Json -Depth 6 -Compress }

function Test-PhoneShouldSend([string]$Key, [string]$LastKey, [double]$LastSent, [double]$FailedAt, [double]$Now) {
    if ($Key -eq $LastKey) { return $false }
    if ($Now - $LastSent -lt $PhoneMinInterval) { return $false }
    return ($FailedAt -eq 0 -or $Now - $FailedAt -ge $PhoneRetryAfter)
}

function Get-PhoneGistBody($Payload, [switch]$Create) {
    $body = [ordered]@{ files = @{ $PhoneGistFile = @{ content = ($Payload | ConvertTo-Json -Depth 6) } } }
    if ($Create) { $body.description = 'Claude Limits — widget data'; $body.public = $false }
    return $body | ConvertTo-Json -Depth 8 -Compress
}

# Самодостаточна: её текст выполняется в фоновом runspace. Возвращает @{ Status; Body } (Status 0 — нет связи).
function Invoke-GistRequest([string]$Method, [string]$Url, [string]$Token, [string]$Json, [int]$TimeoutMs = 20000) {
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
    $resp = $null
    try {
        $req = [Net.WebRequest]::Create($Url)
        $req.Method = $Method
        $req.Timeout = $TimeoutMs
        $req.UserAgent = 'ClaudeLimits'
        $req.Accept = 'application/vnd.github+json'
        $req.ContentType = 'application/json'
        $req.Headers['Authorization'] = "Bearer $Token"
        $req.Headers['X-GitHub-Api-Version'] = '2022-11-28'
        $bytes = [Text.Encoding]::UTF8.GetBytes($Json)
        $req.ContentLength = $bytes.Length
        $s = $req.GetRequestStream(); $s.Write($bytes, 0, $bytes.Length); $s.Close()
        $resp = $req.GetResponse()
    } catch {
        $ex = $_.Exception
        while ($ex -and -not ($ex -is [Net.WebException])) { $ex = $ex.InnerException }
        if (-not $ex -or -not $ex.Response) { return @{ Status = 0; Body = '' } }
        $resp = $ex.Response
    }
    try {
        $reader = New-Object IO.StreamReader($resp.GetResponseStream(), [Text.Encoding]::UTF8)
        return @{ Status = [int]$resp.StatusCode; Body = $reader.ReadToEnd() }
    } finally { $resp.Close() }
}

function Get-PhoneErrorText([int]$Status) {
    switch ($Status) {
        0       { return 'Нет связи с GitHub.' }
        401     { return 'GitHub не принял токен (401). Проверьте, что он скопирован целиком и не просрочен.' }
        { $_ -eq 403 -or $_ -eq 404 } { return "У токена нет доступа к gist ($Status). Нужен classic-токен с галочкой «gist»." }
        default { return "GitHub ответил $Status." }
    }
}

# ---------- фоновая выгрузка для значка в трее ----------

function New-PhoneSync([string]$Path = (Get-PhoneConfigPath)) {
    return @{ Path = $Path; Stamp = $null; Config = $null; Pending = $null; LastKey = $null
              LastSent = 0.0; FailedAt = 0.0; LastError = $null; Job = $null }
}

function Update-PhoneSyncConfig([hashtable]$Sync) {
    $stamp = $null
    try {
        $fi = New-Object IO.FileInfo $Sync.Path
        if ($fi.Exists) { $stamp = "$($fi.Length)|$($fi.LastWriteTimeUtc.Ticks)" }
    } catch { }
    if ($stamp -ne $Sync.Stamp) {
        $Sync.Stamp = $stamp
        $Sync.Config = if ($stamp) { Read-PhoneConfig $Sync.Path } else { $null }
        $Sync.LastKey = $null; $Sync.FailedAt = 0.0; $Sync.LastError = $null
    }
}

function Complete-PhoneSync([hashtable]$Sync) {
    $job = $Sync.Job
    if (-not $job -or -not $job.Handle.IsCompleted) { return }
    $Sync.Job = $null
    $status = 0
    try { $r = @($job.Shell.EndInvoke($job.Handle)) | Select-Object -Last 1; if ($r) { $status = [int]$r.Status } } catch { } finally { $job.Shell.Dispose() }
    $t = [double](Get-UnixNow)
    if ($status -eq 200) { $Sync.LastKey = $job.Key; $Sync.LastSent = $t; $Sync.FailedAt = 0.0; $Sync.LastError = $null }
    else { $Sync.FailedAt = $t; $Sync.LastError = $status }
}

# Раз в несколько секунд из таймера UI: завершает прошлую выгрузку и при необходимости начинает новую.
function Step-PhoneSync([hashtable]$Sync, [int64]$Now = (Get-UnixNow)) {
    Complete-PhoneSync $Sync
    Update-PhoneSyncConfig $Sync
    if (-not $Sync.Config -or -not $Sync.Pending -or $Sync.Job) { return $false }
    $p = Get-PhonePayload $Sync.Pending $Now
    if ($p.sources.Count -eq 0) { return $false }
    $key = Get-PhonePayloadKey $p
    if (-not (Test-PhoneShouldSend $key $Sync.LastKey $Sync.LastSent $Sync.FailedAt $Now)) { return $false }
    $shell = [powershell]::Create()
    $def = ${function:Invoke-GistRequest}.ToString()
    [void]$shell.AddScript("function Invoke-GistRequest { $def }`nInvoke-GistRequest 'PATCH' `$args[0] `$args[1] `$args[2]")
    [void]$shell.AddArgument("$(Get-GitHubApi)/gists/$($Sync.Config.gist_id)").AddArgument($Sync.Config.token).AddArgument((Get-PhoneGistBody $p))
    $Sync.Job = @{ Shell = $shell; Handle = $shell.BeginInvoke(); Key = $key }
    return $true
}

function Stop-PhoneSync([hashtable]$Sync) {
    if ($Sync.Job) { try { $Sync.Job.Shell.Stop(); $Sync.Job.Shell.Dispose() } catch { }; $Sync.Job = $null }
}
