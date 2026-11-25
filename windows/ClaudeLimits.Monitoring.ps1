# ClaudeLimits for Windows — фоновый опрос источников (LimitMonitoringService).
# Каждый источник опрашивается в своём runspace: FileSystemWatcher + debounce, а при его недоступности — таймер.
# Новые снимки LimitMetrics кладутся в потокобезопасную очередь; Dispatch() вызывается из UI-потока
# и раздаёт их подписчикам. Из UI объекты LimitMetrics только читаются: методы PowerShell-классов
# привязаны к runspace, где их создали.

class LimitMonitoringService {
    static [string]$WorkerScript = @'
param($ParsersScript, $Source, $Path, $IntervalMs, $DebounceMs, $Queue, $Control, $WorkerId)
. ([scriptblock]::Create($ParsersScript))
$parser = New-LimitParser $Source $Path
$watcher = $null
$signature = $null
try {
    while (-not $Control.Stop) {
        try {
            $m = $parser.ParseLimits()
            $sig = '{0}|{1}|{2}|{3}' -f $m.Status, $m.Updated, $m.LogPath, (($m.Windows | ForEach-Object { '{0}:{1}:{2}' -f $_.Id, $_.Used, $_.Reset }) -join ';')
            if ($sig -ne $signature) {
                $signature = $sig
                $Queue.Enqueue(@{ Worker = $WorkerId; Source = $Source; Metrics = $m })
            }
        } catch { }

        $target = $parser.GetLogPath()
        $dir = $null; $filter = '*'
        if ($target -and (Test-Path -LiteralPath $target -PathType Container)) { $dir = $target }
        elseif ($target) { $dir = Split-Path -Parent $target; $filter = Split-Path -Leaf $target }
        if ($watcher -and ($watcher.Path -ne $dir -or $watcher.Filter -ne $filter)) { $watcher.Dispose(); $watcher = $null }
        if (-not $watcher -and $dir -and (Test-Path -LiteralPath $dir -PathType Container)) {
            try { $watcher = New-Object IO.FileSystemWatcher $dir, $filter } catch { $watcher = $null }
        }

        $deadline = [DateTime]::UtcNow.AddMilliseconds($IntervalMs)
        $changed = $false
        while (-not $Control.Stop -and -not $changed -and [DateTime]::UtcNow -lt $deadline) {
            if ($watcher) { $changed = -not $watcher.WaitForChanged([IO.WatcherChangeTypes]::All, 500).TimedOut }
            else { Start-Sleep -Milliseconds 500 }
        }
        if ($changed) {
            $cap = [DateTime]::UtcNow.AddMilliseconds(10 * $DebounceMs)
            while (-not $Control.Stop -and [DateTime]::UtcNow -lt $cap -and
                   -not $watcher.WaitForChanged([IO.WatcherChangeTypes]::All, $DebounceMs).TimedOut) { }
        }
    }
} finally {
    if ($watcher) { $watcher.Dispose() }
}
'@

    [hashtable]$Latest = @{}
    [int]$IntervalMs = 5000
    [int]$DebounceMs = 750
    hidden [string]$ParsersScript
    hidden [Collections.Concurrent.ConcurrentQueue[object]]$Queue
    hidden [hashtable]$Workers = @{}
    hidden [hashtable]$Handlers = @{}
    hidden [Collections.Generic.List[object]]$Retired

    LimitMonitoringService([string]$parsersPath) {
        $this.ParsersScript = [IO.File]::ReadAllText($parsersPath)
        $this.Queue = [Collections.Concurrent.ConcurrentQueue[object]]::new()
        $this.Retired = [Collections.Generic.List[object]]::new()
    }

    [void] Subscribe([string]$source, [scriptblock]$handler) {
        if (-not $this.Handlers.ContainsKey($source)) { $this.Handlers[$source] = [Collections.Generic.List[scriptblock]]::new() }
        $this.Handlers[$source].Add($handler)
    }

    [void] Watch([string]$source, [string]$path) {
        $this.Unwatch($source)
        $control = [hashtable]::Synchronized(@{ Stop = $false })
        $id = [guid]::NewGuid().ToString('N')
        $runspace = [runspacefactory]::CreateRunspace()
        $runspace.Open()
        $shell = [powershell]::Create()
        $shell.Runspace = $runspace
        [void]$shell.AddScript([LimitMonitoringService]::WorkerScript)
        foreach ($arg in @($this.ParsersScript, $source, $path, $this.IntervalMs, $this.DebounceMs, $this.Queue, $control, $id)) {
            [void]$shell.AddArgument($arg)
        }
        $this.Workers[$source] = @{ Id = $id; Control = $control; Shell = $shell; Runspace = $runspace; Handle = $shell.BeginInvoke() }
    }

    [void] Unwatch([string]$source) {
        $w = $this.Workers[$source]
        if (-not $w) { return }
        $this.Workers.Remove($source)
        $this.Latest.Remove($source)
        $w.Control.Stop = $true
        $this.Retired.Add($w)
    }

    [int] Dispatch() {
        $count = 0
        $item = $null
        while ($this.Queue.TryDequeue([ref]$item)) {
            $w = $this.Workers[$item.Source]
            if (-not $w -or $w.Id -ne $item.Worker) { continue }
            $this.Latest[$item.Source] = $item.Metrics
            if ($this.Handlers.ContainsKey($item.Source)) {
                foreach ($h in $this.Handlers[$item.Source]) { try { & $h $item.Metrics } catch { } }
            }
            $count++
        }
        foreach ($w in @($this.Retired)) {
            if ($w.Handle.IsCompleted) {
                [LimitMonitoringService]::Release($w)
                [void]$this.Retired.Remove($w)
            }
        }
        return $count
    }

    [string] Fault([string]$source) {
        $w = $this.Workers[$source]
        if (-not $w -or -not $w.Handle.IsCompleted) { return '' }
        try { [void]$w.Shell.EndInvoke($w.Handle) } catch { return $_.Exception.Message }
        $err = $w.Shell.Streams.Error | Select-Object -First 1
        if ($err) { return [string]$err }
        return 'worker stopped'
    }

    [bool] WaitForAll([int]$timeoutMs) {
        $deadline = [DateTime]::UtcNow.AddMilliseconds($timeoutMs)
        while ($true) {
            [void]$this.Dispatch()
            $ready = $true
            foreach ($source in $this.Workers.Keys) { if (-not $this.Latest.ContainsKey($source)) { $ready = $false } }
            if ($ready) { return $true }
            if ([DateTime]::UtcNow -ge $deadline) { return $false }
            Start-Sleep -Milliseconds 50
        }
        return $false
    }

    [void] Dispose() {
        foreach ($source in @($this.Workers.Keys)) { $this.Unwatch($source) }
        foreach ($w in $this.Retired) {
            [void]$w.Handle.AsyncWaitHandle.WaitOne(3000)
            [LimitMonitoringService]::Release($w)
        }
        $this.Retired.Clear()
        $this.Handlers.Clear()
        $item = $null
        while ($this.Queue.TryDequeue([ref]$item)) { }
    }

    hidden static [void] Release([hashtable]$w) {
        try { if ($w.Handle.IsCompleted) { [void]$w.Shell.EndInvoke($w.Handle) } } catch { }
        try { $w.Shell.Dispose() } catch { }
        try { $w.Runspace.Dispose() } catch { }
    }
}
