# ClaudeLimits for Windows — слой парсеров (Strategy): один контракт LimitParser, по реализации на источник.
#   ClaudeCodeParser    — ~/.claude/limits.json, который пишет statusline.ps1
#   ClaudeDesktopParser — данные клиента Claude Desktop:
#     Local Storage (LevelDB): запись {"resetsAt","utilization","observedAt",...} — 5-часовое окно;
#     IndexedDB (кэш ответа claude.ai, V8 + Snappy): messageLimits.windows {"5h", "7d"} — 5-часовое и недельное окна.
# Файлы читаются только с FileShare.ReadWrite|Delete; журнал .log дочитывается с сохранённого offset,
# неизменяемые таблицы .ldb разбираются один раз и кэшируются по размеру и времени записи.

if (-not ('ClaudeLimits.LevelDb' -as [type])) {
    try { Add-Type -ErrorAction Stop -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Text;

namespace ClaudeLimits {
    public static class LevelDb {
        const ulong TableMagic = 0xdb4775248b80fb57UL;

        public static byte[] ReadShared(string path, long offset) {
            using (var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete)) {
                if (offset < 0 || offset > fs.Length) offset = 0;
                fs.Seek(offset, SeekOrigin.Begin);
                var buf = new byte[fs.Length - offset];
                int read = 0;
                while (read < buf.Length) {
                    int n = fs.Read(buf, read, buf.Length - read);
                    if (n <= 0) break;
                    read += n;
                }
                if (read < buf.Length) Array.Resize(ref buf, read);
                return buf;
            }
        }

        public static long FileLength(string path) {
            using (var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
                return fs.Length;
        }

        public static string Latin1(byte[] bytes) {
            return Encoding.GetEncoding(28591).GetString(bytes);
        }

        public static string ReadTableText(string path) {
            byte[] file = ReadShared(path, 0);
            if (file.Length < 48 || BitConverter.ToUInt64(file, file.Length - 8) != TableMagic)
                throw new InvalidDataException("not a LevelDB table");
            int p = file.Length - 48;
            ReadVarint(file, ref p);
            ReadVarint(file, ref p);
            long indexOffset = ReadVarint(file, ref p);
            long indexSize = ReadVarint(file, ref p);
            var text = new StringBuilder();
            foreach (long[] handle in BlockHandles(ReadBlock(file, indexOffset, indexSize)))
                text.Append(Latin1(ReadBlock(file, handle[0], handle[1]))).Append('\n');
            return text.ToString();
        }

        public static byte[] Snappy(byte[] src) {
            int p = 0;
            long size = ReadVarint(src, ref p);
            if (size < 0 || size > 256L * 1024 * 1024) throw new InvalidDataException("bad snappy length");
            var dst = new byte[size];
            int o = 0;
            while (p < src.Length) {
                int tag = src[p++];
                int len, off;
                switch (tag & 3) {
                    case 0:
                        len = (tag >> 2) + 1;
                        if (len > 60) {
                            int extra = len - 60;
                            len = 0;
                            for (int i = 0; i < extra; i++) len |= src[p++] << (8 * i);
                            len += 1;
                        }
                        if (len < 0 || p + len > src.Length || o + len > dst.Length) throw new InvalidDataException("bad snappy literal");
                        Buffer.BlockCopy(src, p, dst, o, len);
                        p += len;
                        o += len;
                        continue;
                    case 1:
                        len = ((tag >> 2) & 7) + 4;
                        off = ((tag >> 5) << 8) | src[p++];
                        break;
                    case 2:
                        len = (tag >> 2) + 1;
                        off = src[p] | (src[p + 1] << 8);
                        p += 2;
                        break;
                    default:
                        len = (tag >> 2) + 1;
                        off = BitConverter.ToInt32(src, p);
                        p += 4;
                        break;
                }
                if (off <= 0 || off > o || o + len > dst.Length) throw new InvalidDataException("bad snappy copy");
                for (int i = 0; i < len; i++, o++) dst[o] = dst[o - off];
            }
            if (o != dst.Length) throw new InvalidDataException("truncated snappy block");
            return dst;
        }

        public static byte[] ReadIndexedDbValue(string path) {
            if (path.EndsWith(".ldb", StringComparison.OrdinalIgnoreCase)) return Encoding.GetEncoding(28591).GetBytes(ReadTableText(path));
            byte[] b = ReadShared(path, 0);
            if (b.Length > 3 && b[0] == 0xff && b[1] == 0x11 && b[2] == 0x02) {
                var raw = new byte[b.Length - 3];
                Buffer.BlockCopy(b, 3, raw, 0, raw.Length);
                return Snappy(raw);
            }
            return b;
        }

        // { observedAt, fiveUtil, fiveReset, fiveAtWall, weekUtil, weekReset, weekAtWall }; NaN — окна нет
        public static List<double[]> FindWindows(byte[] b, double fallbackTime) {
            var result = new List<double[]>();
            byte[] key = Encoding.ASCII.GetBytes("\"\u0007windows");
            byte[] updated = Encoding.ASCII.GetBytes("\"\u000ddataUpdatedAt");
            int i = 0;
            while ((i = IndexOf(b, key, i)) >= 0) {
                i += key.Length;
                int p = i;
                Dictionary<string, object> obj;
                try { obj = V8Read(b, ref p, 0) as Dictionary<string, object>; } catch (Exception) { continue; }
                if (obj == null) continue;
                double observed = fallbackTime;
                int u = IndexOf(b, updated, p);
                if (u >= 0 && u - p < 4096 && u + updated.Length + 9 <= b.Length && b[u + updated.Length] == 0x4e) {
                    double v = BitConverter.ToDouble(b, u + updated.Length + 1);
                    if (v > 0) observed = v > 1e11 ? v / 1000 : v;
                }
                var row = new double[] { observed, double.NaN, double.NaN, 0, double.NaN, double.NaN, 0 };
                bool any = false;
                foreach (var w in new[] { new { Key = "5h", At = 1 }, new { Key = "7d", At = 4 } }) {
                    object o;
                    if (!obj.TryGetValue(w.Key, out o)) continue;
                    var win = o as Dictionary<string, object>;
                    if (win == null || !(win.ContainsKey("resets_at") && win["resets_at"] is double) || !(win.ContainsKey("utilization") && win["utilization"] is double)) continue;
                    double reset = (double)win["resets_at"];
                    row[w.At] = Math.Max(0, (double)win["utilization"]);
                    row[w.At + 1] = reset > 1e11 ? reset / 1000 : reset;
                    row[w.At + 2] = (win.ContainsKey("status") && (win["status"] as string) == "exceeded_limit") ? 1 : 0;
                    any = true;
                }
                if (any) result.Add(row);
            }
            return result;
        }

        static object V8Read(byte[] b, ref int p, int depth) {
            if (depth > 16) throw new InvalidDataException("too deep");
            while (p < b.Length && b[p] == 0) p++;
            if (p >= b.Length) throw new InvalidDataException("truncated v8");
            byte tag = b[p++];
            switch (tag) {
                case 0x6f: {
                    var obj = new Dictionary<string, object>();
                    while (true) {
                        while (p < b.Length && b[p] == 0) p++;
                        if (p >= b.Length) throw new InvalidDataException("truncated v8 object");
                        if (b[p] == 0x7b) { p++; ReadVarint(b, ref p); return obj; }
                        object k = V8Read(b, ref p, depth + 1);
                        object v = V8Read(b, ref p, depth + 1);
                        obj[Convert.ToString(k, System.Globalization.CultureInfo.InvariantCulture) ?? ""] = v;
                    }
                }
                case 0x22:
                case 0x63: {
                    int n = (int)ReadVarint(b, ref p);
                    if (n < 0 || p + n > b.Length) throw new InvalidDataException("truncated v8 string");
                    string s = tag == 0x22 ? Encoding.GetEncoding(28591).GetString(b, p, n) : Encoding.Unicode.GetString(b, p, n);
                    p += n;
                    return s;
                }
                case 0x4e: {
                    if (p + 8 > b.Length) throw new InvalidDataException("truncated v8 double");
                    double d = BitConverter.ToDouble(b, p);
                    p += 8;
                    return d;
                }
                case 0x49: { long z = ReadVarint(b, ref p); return (double)((z >> 1) ^ -(z & 1)); }
                case 0x55: return (double)ReadVarint(b, ref p);
                case 0x30:
                case 0x5f: return null;
                case 0x54: return true;
                case 0x46: return false;
                default: throw new InvalidDataException("unsupported v8 tag");
            }
        }

        static int IndexOf(byte[] b, byte[] needle, int start) {
            for (int i = Math.Max(0, start); i <= b.Length - needle.Length; i++) {
                int j = 0;
                while (j < needle.Length && b[i + j] == needle[j]) j++;
                if (j == needle.Length) return i;
            }
            return -1;
        }

        static byte[] ReadBlock(byte[] file, long offset, long size) {
            if (offset < 0 || size < 0 || offset + size + 5 > file.Length) throw new InvalidDataException("bad block handle");
            var raw = new byte[size];
            Buffer.BlockCopy(file, (int)offset, raw, 0, (int)size);
            switch (file[offset + size]) {
                case 0: return raw;
                case 1: return Snappy(raw);
                default: throw new InvalidDataException("unknown block compression");
            }
        }

        static List<long[]> BlockHandles(byte[] block) {
            var handles = new List<long[]>();
            if (block.Length < 4) return handles;
            int restarts = BitConverter.ToInt32(block, block.Length - 4);
            int limit = block.Length - 4 - restarts * 4;
            int p = 0;
            while (p < limit) {
                ReadVarint(block, ref p);
                long keyLength = ReadVarint(block, ref p);
                long valueLength = ReadVarint(block, ref p);
                p += (int)keyLength;
                int v = p;
                long offset = ReadVarint(block, ref v);
                long size = ReadVarint(block, ref v);
                handles.Add(new long[] { offset, size });
                p += (int)valueLength;
            }
            return handles;
        }

        static long ReadVarint(byte[] b, ref int p) {
            long result = 0;
            for (int shift = 0; shift < 64; shift += 7) {
                if (p >= b.Length) throw new InvalidDataException("truncated varint");
                byte c = b[p++];
                result |= (long)(c & 0x7f) << shift;
                if ((c & 0x80) == 0) return result;
            }
            throw new InvalidDataException("bad varint");
        }
    }
}
'@ } catch { if (-not ('ClaudeLimits.LevelDb' -as [type])) { throw } }
}

class LimitWindow {
    [string]$Id
    [double]$Used
    [double]$RawUsed
    [double]$Left
    [int64]$Reset
    [bool]$Rolling
}

class LimitMetrics {
    [string]$Source
    [string]$Status = 'NoData'
    [int64]$Updated
    [string]$LogPath
    [LimitWindow[]]$Windows = @()
    [object[]]$Samples = @()

    LimitMetrics([string]$source) { $this.Source = $source }
}

class LimitParser {
    [string]$Source

    LimitParser([string]$source) { $this.Source = $source }

    [LimitMetrics] ParseLimits() { return $this.ParseAt([DateTimeOffset]::UtcNow.ToUnixTimeSeconds()) }

    [LimitMetrics] ParseAt([int64]$now) { throw [NotImplementedException]::new('ParseAt') }

    [string] GetLogPath() { throw [NotImplementedException]::new('GetLogPath') }

    [bool] IsInstalled() {
        $path = $this.GetLogPath()
        return [bool]$path -and (Test-Path -LiteralPath $path)
    }

    [Nullable[datetime]] GetResetTime() {
        $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        $next = [int64]0
        foreach ($w in $this.ParseAt($now).Windows) {
            if ($w.Reset -gt $now -and ($next -eq 0 -or $w.Reset -lt $next)) { $next = $w.Reset }
        }
        if ($next -eq 0) { return $null }
        return [DateTimeOffset]::FromUnixTimeSeconds($next).LocalDateTime
    }

    static [LimitWindow] NewWindow([string]$id, [double]$rawUsed, [int64]$reset, [bool]$rolling, [int64]$now) {
        $w = [LimitWindow]::new()
        $w.Id = $id
        $w.RawUsed = $rawUsed
        $w.Used = if ($reset -le $now) { 0.0 } else { [math]::Min(100.0, [math]::Max(0.0, $rawUsed)) }
        $w.Left = [math]::Max(0.0, 100.0 - $w.Used)
        $w.Reset = $reset
        $w.Rolling = $rolling
        return $w
    }

    static [type] LevelDb() { return 'ClaudeLimits.LevelDb' -as [type] }

    static [string] UserHome() {
        if ($env:USERPROFILE) { return $env:USERPROFILE }
        return [Environment]::GetFolderPath('UserProfile')
    }
}

class ClaudeCodeParser : LimitParser {
    [string]$Path
    hidden [string]$Stamp = ''
    hidden [object]$Data

    ClaudeCodeParser([string]$limitsPath) : base('code') {
        if (-not $limitsPath) { $limitsPath = [IO.Path]::Combine([LimitParser]::UserHome(), '.claude', 'limits.json') }
        $this.Path = $limitsPath
    }

    [string] GetLogPath() { return $this.Path }

    [LimitMetrics] ParseAt([int64]$now) {
        $m = [LimitMetrics]::new('code')
        $m.LogPath = $this.Path
        if (-not (Test-Path -LiteralPath (Split-Path -Parent $this.Path))) { $m.Status = 'NotFound'; return $m }
        if (-not (Test-Path -LiteralPath $this.Path)) { return $m }
        try {
            $file = [IO.FileInfo]::new($this.Path)
            $current = '{0}|{1}' -f $file.Length, $file.LastWriteTimeUtc.Ticks
            if ($current -ne $this.Stamp) {
                $ldb = [LimitParser]::LevelDb()
                $text = [Text.Encoding]::UTF8.GetString($ldb::ReadShared($this.Path, 0)).TrimStart([char]0xFEFF)
                $this.Data = $text | ConvertFrom-Json
                $this.Stamp = $current
            }
        } catch {
            $this.Data = $null
            $this.Stamp = ''
        }
        $d = $this.Data
        if (-not $d -or -not $d.rate_limits) { return $m }
        $m.Updated = [int64]$d.updated_at
        foreach ($id in 'five_hour', 'seven_day') {
            $w = $d.rate_limits.$id
            if ($w) { $m.Windows += [LimitParser]::NewWindow($id, [double]$w.used_percentage, [int64]$w.resets_at, $false, $now) }
        }
        if ($m.Windows.Count -gt 0) { $m.Status = 'Ok' }
        return $m
    }
}

class ClaudeDesktopParser : LimitParser {
    [string]$CustomPath
    hidden [hashtable]$Tables = @{}
    hidden [hashtable]$Journals = @{}
    hidden [hashtable]$Blobs = @{}
    hidden [hashtable]$Records = @{}

    ClaudeDesktopParser([string]$customPath) : base('desktop') { $this.CustomPath = $customPath }

    static [string[]] DataRoots() {
        $roots = [Collections.Generic.List[string]]::new()
        foreach ($base in @($env:APPDATA, $env:LOCALAPPDATA)) { if ($base) { $roots.Add((Join-Path $base 'Claude')) } }
        if ($env:LOCALAPPDATA) {
            $packages = Join-Path $env:LOCALAPPDATA 'Packages'
            if (Test-Path -LiteralPath $packages) {
                foreach ($p in Get-ChildItem -LiteralPath $packages -Directory -Filter 'Claude*' -ErrorAction SilentlyContinue) {
                    $roots.Add([IO.Path]::Combine($p.FullName, 'LocalCache', 'Roaming', 'Claude'))
                }
            }
        }
        $userHome = [LimitParser]::UserHome()
        $roots.Add([IO.Path]::Combine($userHome, 'Library', 'Application Support', 'Claude'))
        $roots.Add([IO.Path]::Combine($userHome, '.config', 'Claude'))
        return $roots.ToArray()
    }

    static [string] LevelDbDir([string]$root) {
        if (-not $root) { return '' }
        $nested = [IO.Path]::Combine($root, 'Local Storage', 'leveldb')
        if (Test-Path -LiteralPath $nested -PathType Container) { return $nested }
        if (Test-Path -LiteralPath (Join-Path $root 'CURRENT') -PathType Leaf) { return $root }
        return ''
    }

    [string] GetLogPath() {
        if ($this.CustomPath) { return [ClaudeDesktopParser]::LevelDbDir($this.CustomPath) }
        foreach ($root in [ClaudeDesktopParser]::DataRoots()) {
            $dir = [ClaudeDesktopParser]::LevelDbDir($root)
            if ($dir) { return $dir }
        }
        return ''
    }

    [LimitMetrics] ParseAt([int64]$now) {
        $m = [LimitMetrics]::new('desktop')
        $dir = $this.GetLogPath()
        $m.LogPath = $dir
        if (-not $dir) { $m.Status = 'NotFound'; return $m }
        $best = $null
        $seen = @{}
        foreach ($f in Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue) {
            $rec = $null
            if ($f.Extension -eq '.log') { $rec = $this.ScanJournal($f) }
            elseif ($f.Extension -eq '.ldb' -or $f.Extension -eq '.sst') { $rec = $this.ScanTable($f) }
            else { continue }
            $seen[$f.FullName] = $true
            $best = [ClaudeDesktopParser]::Newest($best, @($rec))
        }
        $idb = $null
        foreach ($path in [ClaudeDesktopParser]::IndexedDbFiles($dir)) {
            $seen[$path] = $true
            $idb = [ClaudeDesktopParser]::NewestWindows($idb, $this.ScanIndexedDb($path))
        }
        foreach ($cache in @($this.Tables, $this.Journals, $this.Blobs, $this.Records)) {
            foreach ($k in @($cache.Keys)) { if (-not $seen.ContainsKey($k)) { $cache.Remove($k) } }
        }
        $five = $best
        if ($idb -and $idb.Five -and (-not $five -or $idb.Five.ObservedAt -gt $five.ObservedAt)) { $five = $idb.Five }
        if ($five) {
            $m.Windows += [LimitParser]::NewWindow('five_hour', [ClaudeDesktopParser]::Percent($five), [int64]$five.ResetsAt, $true, $now)
            $times = @{}
            $all = @(foreach ($list in $this.Records.Values) { foreach ($r in $list) { $r } }) | Sort-Object ObservedAt
            $m.Samples = @(foreach ($r in $all) {
                if ($r.ResetsAt -eq $five.ResetsAt -and $r.ObservedAt -gt 0 -and $r.ObservedAt -le $now -and -not $times.ContainsKey($r.ObservedAt)) {
                    $times[$r.ObservedAt] = $true
                    [pscustomobject]@{ t = [int64]$r.ObservedAt; f = [ClaudeDesktopParser]::Percent($r); fr = [int64]$r.ResetsAt }
                }
            })
        }
        if ($idb -and $idb.Week) {
            $m.Windows += [LimitParser]::NewWindow('seven_day', [ClaudeDesktopParser]::Percent($idb.Week), [int64]$idb.Week.ResetsAt, $false, $now)
        }
        if ($m.Windows.Count -eq 0) { return $m }
        $observed = 0.0
        if ($five) { $observed = $five.ObservedAt }
        if ($idb -and $idb.ObservedAt -gt $observed) { $observed = $idb.ObservedAt }
        $m.Updated = [int64]$observed
        $m.Status = 'Ok'
        return $m
    }

    static [double] Percent([object]$r) {
        if ($r.AtWall) { return 100.0 }
        $u = if ($r.Utilization -le 1) { $r.Utilization * 100 } else { $r.Utilization }
        return [math]::Round($u, 3)
    }

    static [string[]] IndexedDbFiles([string]$localStorageDir) {
        $leaf = Split-Path -Leaf $localStorageDir
        $parent = Split-Path -Parent $localStorageDir
        if ($leaf -ne 'leveldb' -or (Split-Path -Leaf $parent) -ne 'Local Storage') { return @() }
        $idb = Join-Path (Split-Path -Parent $parent) 'IndexedDB'
        if (-not (Test-Path -LiteralPath $idb -PathType Container)) { return @() }
        $files = [Collections.Generic.List[string]]::new()
        foreach ($base in Get-ChildItem -LiteralPath $idb -Directory -Filter 'https_claude.ai*' -ErrorAction SilentlyContinue | Sort-Object Name) {
            foreach ($f in Get-ChildItem -LiteralPath $base.FullName -File -Recurse -ErrorAction SilentlyContinue) {
                if ($base.Name -like '*.blob' -or $f.Extension -eq '.log' -or $f.Extension -eq '.ldb') { $files.Add($f.FullName) }
            }
        }
        return $files.ToArray()
    }

    hidden [object] ScanIndexedDb([string]$path) {
        $file = [IO.FileInfo]::new($path)
        if (-not $file.Exists) { return $null }
        $stamp = '{0}|{1}' -f $file.Length, $file.LastWriteTimeUtc.Ticks
        $cached = $this.Blobs[$path]
        if ($cached -and $cached.Stamp -eq $stamp) { return $cached.Best }
        $best = $null
        try {
            $ldb = [LimitParser]::LevelDb()
            $mtime = [double]([DateTimeOffset]$file.LastWriteTimeUtc).ToUnixTimeSeconds()
            foreach ($row in $ldb::FindWindows($ldb::ReadIndexedDbValue($path), $mtime)) {
                $best = [ClaudeDesktopParser]::NewestWindows($best, [ClaudeDesktopParser]::WindowsFromRow($row))
            }
        } catch { }
        $this.Blobs[$path] = @{ Stamp = $stamp; Best = $best }
        return $best
    }

    static [object] WindowsFromRow([double[]]$row) {
        $five = $null; $week = $null
        if (-not [double]::IsNaN($row[1])) { $five = [pscustomobject]@{ Utilization = $row[1]; ResetsAt = $row[2]; ObservedAt = $row[0]; AtWall = $row[3] -eq 1 } }
        if (-not [double]::IsNaN($row[4])) { $week = [pscustomobject]@{ Utilization = $row[4]; ResetsAt = $row[5]; ObservedAt = $row[0]; AtWall = $row[6] -eq 1 } }
        return [pscustomobject]@{ ObservedAt = $row[0]; Five = $five; Week = $week }
    }

    static [object] NewestWindows([object]$a, [object]$b) {
        if ($null -eq $a) { return $b }
        if ($null -eq $b) { return $a }
        if ($b.ObservedAt -ge $a.ObservedAt) { return $b }
        return $a
    }

    hidden [object] ScanJournal([IO.FileInfo]$file) {
        $len = $file.Length
        try { $len = ([LimitParser]::LevelDb())::FileLength($file.FullName) } catch { }
        $j = $this.Journals[$file.FullName]
        if (-not $j -or $len -lt $j.Offset) {
            $j = @{ Offset = [int64]0; Tail = ''; Best = $null }
            $this.Journals[$file.FullName] = $j
            $this.Records[$file.FullName] = @()
        }
        if ($len -eq $j.Offset) { return $j.Best }
        try {
            $ldb = [LimitParser]::LevelDb()
            $bytes = $ldb::ReadShared($file.FullName, $j.Offset)
            $text = $j.Tail + $ldb::Latin1($bytes)
            $found = [ClaudeDesktopParser]::FindRecords($text)
            $j.Best = [ClaudeDesktopParser]::Newest($j.Best, $found)
            $list = @($this.Records[$file.FullName]) + @($found) | Where-Object { $null -ne $_ }
            $this.Records[$file.FullName] = @($list | Select-Object -Last 500)
            $j.Offset += $bytes.Length
            $j.Tail = $text.Substring([math]::Max(0, $text.Length - 4096))
        } catch { }
        return $j.Best
    }

    hidden [object] ScanTable([IO.FileInfo]$file) {
        $stamp = '{0}|{1}' -f $file.Length, $file.LastWriteTimeUtc.Ticks
        $cached = $this.Tables[$file.FullName]
        if ($cached -and $cached.Stamp -eq $stamp) { return $cached.Best }
        $found = @()
        try {
            $ldb = [LimitParser]::LevelDb()
            $found = [ClaudeDesktopParser]::FindRecords($ldb::ReadTableText($file.FullName))
        } catch { }
        $best = [ClaudeDesktopParser]::Newest($null, $found)
        $this.Records[$file.FullName] = @($found | Select-Object -Last 500)
        $this.Tables[$file.FullName] = @{ Stamp = $stamp; Best = $best }
        return $best
    }

    static [object[]] FindRecords([string]$text) {
        $found = [Collections.Generic.List[object]]::new()
        foreach ($match in [regex]::Matches($text, '\{[^{}]{0,2048}?"resetsAt"[^{}]{0,2048}?\}')) {
            $s = $match.Value
            $reset = [regex]::Match($s, '"resetsAt"\s*:\s*(\d+(?:\.\d+)?)')
            $util = [regex]::Match($s, '"utilization"\s*:\s*(-?\d+(?:\.\d+)?(?:[eE][-+]?\d+)?)')
            if (-not ($reset.Success -and $util.Success)) { continue }
            $observed = [regex]::Match($s, '"observedAt"\s*:\s*(\d+(?:\.\d+)?)')
            $resetsAt = [double]$reset.Groups[1].Value
            if ($resetsAt -gt 1e11) { $resetsAt = $resetsAt / 1000 }
            $observedAt = if ($observed.Success) { [double]$observed.Groups[1].Value } else { 0.0 }
            if ($observedAt -gt 1e11) { $observedAt = $observedAt / 1000 }
            $found.Add([pscustomobject]@{
                ResetsAt    = $resetsAt
                Utilization = [math]::Max(0.0, [double]$util.Groups[1].Value)
                ObservedAt  = $observedAt
                AtWall      = [regex]::IsMatch($s, '"atWall"\s*:\s*true')
            })
        }
        return $found.ToArray()
    }

    static [object] Newest([object]$current, [object[]]$records) {
        $best = $current
        foreach ($r in $records) {
            if ($null -ne $r -and ($null -eq $best -or $r.ObservedAt -ge $best.ObservedAt)) { $best = $r }
        }
        return $best
    }
}

function New-LimitParser([string]$Source, [string]$Path) {
    switch ($Source) {
        'code' { return [ClaudeCodeParser]::new($Path) }
        'desktop' { return [ClaudeDesktopParser]::new($Path) }
    }
    throw "Unknown limit source: $Source"
}
