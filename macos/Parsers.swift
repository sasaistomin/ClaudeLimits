// ClaudeLimits — слой парсеров (Strategy): один контракт LimitParser, по реализации на источник.
//   ClaudeCodeParser    — ~/.claude/limits.json, который пишет режим --statusline
//   ClaudeDesktopParser — данные приложения Claude Desktop:
//     Local Storage (LevelDB): запись {"resetsAt","utilization","observedAt",...} — 5-часовое окно;
//     IndexedDB (кэш ответа claude.ai, V8 + Snappy): messageLimits.windows {"5h", "7d"} — 5-часовое и недельное окна.
// Журнал .log дочитывается с сохранённого offset, неизменяемые таблицы .ldb разбираются один раз
// и кэшируются по размеру и времени записи. Покрыто тестами: tests/macos/UnitTests.swift

import Foundation

enum LimitSource: String, CaseIterable, Identifiable {
    case code, desktop
    var id: String { rawValue }
    var title: String { self == .code ? "Claude Code" : "Claude Desktop" }
}

enum LimitStatus: Equatable { case ok, noData, notFound, invalid }

struct LimitWindow: Equatable {
    let id: String
    let raw: Double
    let resetsAt: Double
    let rolling: Bool
    let used: Double
    var left: Double { max(0, 100 - used) }
    var state: WindowState { WindowState(used: used, resetsAt: Date(timeIntervalSince1970: resetsAt)) }

    init(id: String, raw: Double, resetsAt: Double, rolling: Bool, now: Double) {
        self.id = id
        self.raw = raw
        self.resetsAt = resetsAt
        self.rolling = rolling
        self.used = resetsAt < now ? 0 : raw
    }
}

struct LimitMetrics: Equatable {
    let source: LimitSource
    var status: LimitStatus = .noData
    var updated: Double = 0
    var logPath: String = ""
    var windows: [LimitWindow] = []
    /// Прошлые замеры текущего окна, если источник их хранит (журнал Claude Desktop) — для графика.
    var samples: [Sample] = []

    func window(_ id: String) -> LimitWindow? { windows.first { $0.id == id } }
}

protocol LimitParser: AnyObject {
    var source: LimitSource { get }
    func parseLimits(now: Double) -> LimitMetrics
    func getLogPath() -> String
}

extension LimitParser {
    func parseLimits() -> LimitMetrics { parseLimits(now: Date().timeIntervalSince1970) }

    func isInstalled() -> Bool {
        let p = getLogPath()
        return !p.isEmpty && FileManager.default.fileExists(atPath: p)
    }

    func getResetTime() -> Date? {
        let now = Date().timeIntervalSince1970
        return parseLimits(now: now).windows.map(\.resetsAt).filter { $0 > now }.min()
            .map { Date(timeIntervalSince1970: $0) }
    }
}

func newLimitParser(_ source: LimitSource, path: String? = nil) -> LimitParser {
    switch source {
    case .code: return ClaudeCodeParser(path: path)
    case .desktop: return ClaudeDesktopParser(customPath: path)
    }
}

private func fileStamp(_ path: String) -> String? {
    guard let a = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
    let size = (a[.size] as? NSNumber)?.int64Value ?? -1
    let mtime = (a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
    return "\(size)|\(mtime)"
}

final class ClaudeCodeParser: LimitParser {
    let source = LimitSource.code
    let path: String
    private var stamp: String?
    private var file: LimitsFile?

    init(path: String? = nil) {
        self.path = (path?.isEmpty == false) ? path! : limitsURL.path
    }

    func getLogPath() -> String { path }

    func parseLimits(now: Double) -> LimitMetrics {
        var m = LimitMetrics(source: .code, logPath: path)
        var isDir: ObjCBool = false
        let dir = (path as NSString).deletingLastPathComponent
        guard FileManager.default.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else {
            m.status = .notFound; return m
        }
        guard let st = fileStamp(path) else { return m }
        if st != stamp {
            stamp = st
            file = (try? Data(contentsOf: URL(fileURLWithPath: path))).flatMap { try? JSONDecoder().decode(LimitsFile.self, from: $0) }
        }
        guard let f = file else { m.status = .invalid; return m }
        m.updated = f.updated_at
        for (id, w) in [("five_hour", f.rate_limits.five_hour), ("seven_day", f.rate_limits.seven_day)] {
            if let w { m.windows.append(LimitWindow(id: id, raw: w.used_percentage, resetsAt: w.resets_at, rolling: false, now: now)) }
        }
        m.status = m.windows.isEmpty ? .noData : .ok
        return m
    }
}

struct DesktopRecord: Equatable {
    let resetsAt: Double
    let utilization: Double
    let observedAt: Double
    let atWall: Bool
}

/// Окна из кэша IndexedDB: 5h и 7d, время получения данных (dataUpdatedAt).
struct DesktopWindows: Equatable {
    var observedAt: Double
    var five: DesktopRecord?
    var week: DesktopRecord?
}

final class ClaudeDesktopParser: LimitParser {
    let source = LimitSource.desktop
    let customPath: String
    private(set) var tables: [String: (stamp: String, best: DesktopRecord?)] = [:]
    private(set) var journals: [String: (offset: UInt64, tail: String, best: DesktopRecord?)] = [:]
    private var seenRecords: [String: [DesktopRecord]] = [:]
    private(set) var blobs: [String: (stamp: String, best: DesktopWindows?)] = [:]

    init(customPath: String? = nil) { self.customPath = customPath ?? "" }

    static var dataRoots: [String] {
        [home.appendingPathComponent("Library/Application Support/Claude").path]
    }

    static func levelDBDir(_ root: String) -> String {
        guard !root.isEmpty else { return "" }
        let fm = FileManager.default
        var isDir: ObjCBool = false
        let nested = (root as NSString).appendingPathComponent("Local Storage/leveldb")
        if fm.fileExists(atPath: nested, isDirectory: &isDir), isDir.boolValue { return nested }
        if fm.fileExists(atPath: (root as NSString).appendingPathComponent("CURRENT")) { return root }
        return ""
    }

    func getLogPath() -> String {
        if !customPath.isEmpty { return Self.levelDBDir(customPath) }
        return Self.dataRoots.lazy.map(Self.levelDBDir).first { !$0.isEmpty } ?? ""
    }

    func parseLimits(now: Double) -> LimitMetrics {
        let dir = getLogPath()
        var m = LimitMetrics(source: .desktop, logPath: dir)
        guard !dir.isEmpty else { m.status = .notFound; return m }
        var best: DesktopRecord?
        var idb: DesktopWindows?
        var seen = Set<String>()
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).sorted()
        for name in names {
            let path = (dir as NSString).appendingPathComponent(name)
            let rec: DesktopRecord?
            if name.hasSuffix(".log") { rec = scanJournal(path) }
            else if name.hasSuffix(".ldb") || name.hasSuffix(".sst") { rec = scanTable(path) }
            else { continue }
            seen.insert(path)
            best = Self.newest(best, [rec].compactMap { $0 })
        }
        for path in indexedDBFiles(dir) {
            seen.insert(path)
            idb = Self.newest(idb, scanIndexedDB(path))
        }
        tables = tables.filter { seen.contains($0.key) }
        journals = journals.filter { seen.contains($0.key) }
        blobs = blobs.filter { seen.contains($0.key) }
        seenRecords = seenRecords.filter { seen.contains($0.key) }

        let five = [best, idb?.five].compactMap { $0 }.max { $0.observedAt < $1.observedAt }
        if let f = five {
            m.windows.append(LimitWindow(id: "five_hour", raw: Self.percent(f), resetsAt: f.resetsAt, rolling: true, now: now))
            var times = Set<Double>()
            m.samples = seenRecords.values.joined()
                .filter { $0.resetsAt == f.resetsAt && $0.observedAt > 0 && $0.observedAt <= now && times.insert($0.observedAt).inserted }
                .sorted { $0.observedAt < $1.observedAt }
                .map { Sample(t: $0.observedAt, f: Self.percent($0), fr: $0.resetsAt, w: nil, wr: nil) }
        }
        if let w = idb?.week {
            m.windows.append(LimitWindow(id: "seven_day", raw: Self.percent(w), resetsAt: w.resetsAt, rolling: false, now: now))
        }
        guard !m.windows.isEmpty else { return m }
        m.updated = max(five?.observedAt ?? 0, idb?.observedAt ?? 0)
        m.status = .ok
        return m
    }

    private static func percent(_ r: DesktopRecord) -> Double {
        r.atWall ? 100 : ((r.utilization <= 1 ? r.utilization * 100 : r.utilization) * 1000).rounded() / 1000
    }

    /// Файлы IndexedDB claude.ai рядом с Local Storage: blob-файлы и сама база LevelDB.
    private func indexedDBFiles(_ localStorageDir: String) -> [String] {
        guard localStorageDir.hasSuffix("Local Storage/leveldb") else { return [] }
        let root = ((localStorageDir as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
        let idb = (root as NSString).appendingPathComponent("IndexedDB")
        let fm = FileManager.default
        var out: [String] = []
        for base in ((try? fm.contentsOfDirectory(atPath: idb)) ?? []).sorted() where base.hasPrefix("https_claude.ai") {
            let dir = (idb as NSString).appendingPathComponent(base)
            guard let e = fm.enumerator(atPath: dir) else { continue }
            for case let rel as String in e {
                let path = (dir as NSString).appendingPathComponent(rel)
                let name = (rel as NSString).lastPathComponent
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else { continue }
                if base.hasSuffix(".blob") || name.hasSuffix(".log") || name.hasSuffix(".ldb") { out.append(path) }
            }
        }
        return out
    }

    private func scanIndexedDB(_ path: String) -> DesktopWindows? {
        guard let st = fileStamp(path) else { return nil }
        if let c = blobs[path], c.stamp == st { return c.best }
        var best: DesktopWindows?
        if var bytes = try? [UInt8](Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)) {
            if path.hasSuffix(".ldb"), let text = try? LevelDB.tableText(path) { bytes = Array(text.data(using: .isoLatin1) ?? Data()) }
            else if bytes.starts(with: [0xff, 0x11, 0x02]), let raw = try? LevelDB.snappy(Array(bytes[3...])) { bytes = raw }
            let mtime = ((try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date)?.timeIntervalSince1970 ?? 0
            for w in Self.findWindows(bytes, fallbackTime: mtime) { best = Self.newest(best, w) }
        }
        blobs[path] = (st, best)
        return best
    }

    private static let windowsKey: [UInt8] = [0x22, 0x07] + Array("windows".utf8)
    private static let updatedKey: [UInt8] = [0x22, 0x0d] + Array("dataUpdatedAt".utf8)

    /// Ищет в V8-сериализованных данных объекты windows {"5h": {...}, "7d": {...}}.
    static func findWindows(_ b: [UInt8], fallbackTime: Double) -> [DesktopWindows] {
        var out: [DesktopWindows] = []
        var i = 0
        while let r = b.firstRange(of: windowsKey, from: i) {
            i = r.upperBound
            var p = r.upperBound
            guard let obj = (try? V8.read(b, &p)) as? [String: Any] else { continue }
            func record(_ key: String, observed: Double) -> DesktopRecord? {
                guard let w = obj[key] as? [String: Any], let reset = w["resets_at"] as? Double,
                      let util = w["utilization"] as? Double else { return nil }
                return DesktopRecord(resetsAt: reset > 1e11 ? reset / 1000 : reset, utilization: max(0, util),
                                     observedAt: observed, atWall: (w["status"] as? String) == "exceeded_limit")
            }
            var observed = fallbackTime
            if let u = b.firstRange(of: updatedKey, from: p), u.lowerBound - p < 4096, u.upperBound + 9 <= b.count,
               b[u.upperBound] == 0x4e {
                let ms = b[(u.upperBound + 1)..<(u.upperBound + 9)].enumerated()
                    .reduce(UInt64(0)) { $0 | UInt64($1.element) << (8 * UInt64($1.offset)) }
                let v = Double(bitPattern: ms)
                if v > 0 { observed = v > 1e11 ? v / 1000 : v }
            }
            let five = record("5h", observed: observed), week = record("7d", observed: observed)
            if five != nil || week != nil { out.append(DesktopWindows(observedAt: observed, five: five, week: week)) }
        }
        return out
    }

    static func newest(_ a: DesktopWindows?, _ b: DesktopWindows?) -> DesktopWindows? {
        guard let a else { return b }
        guard let b else { return a }
        return b.observedAt >= a.observedAt ? b : a
    }

    private func scanJournal(_ path: String) -> DesktopRecord? {
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.uint64Value
        guard let size else { return journals[path]?.best }
        var j = journals[path] ?? (0, "", nil)
        if size < j.offset { j = (0, "", nil); seenRecords[path] = [] }
        if size > j.offset, let h = FileHandle(forReadingAtPath: path) {
            defer { try? h.close() }
            h.seek(toFileOffset: j.offset)
            let data = h.readDataToEndOfFile()
            let text = j.tail + LevelDB.latin1(data)
            let found = Self.findRecords(text)
            j.best = Self.newest(j.best, found)
            seenRecords[path, default: []].append(contentsOf: found)
            seenRecords[path] = Array(seenRecords[path]!.suffix(500))
            j.offset += UInt64(data.count)
            j.tail = String(text.suffix(4096))
        }
        journals[path] = j
        return j.best
    }

    private func scanTable(_ path: String) -> DesktopRecord? {
        guard let st = fileStamp(path) else { return nil }
        if let c = tables[path], c.stamp == st { return c.best }
        let found = (try? LevelDB.tableText(path)).map(Self.findRecords) ?? []
        let best = Self.newest(nil, found)
        seenRecords[path] = Array(found.suffix(500))
        tables[path] = (st, best)
        return best
    }

    private static let recordRe = try! NSRegularExpression(pattern: #"\{[^{}]{0,2048}?"resetsAt"[^{}]{0,2048}?\}"#)

    private static func number(_ key: String, in s: String) -> Double? {
        guard let r = s.range(of: "\"\(key)\"\\s*:\\s*(-?\\d+(?:\\.\\d+)?(?:[eE][-+]?\\d+)?)", options: .regularExpression)
        else { return nil }
        let match = s[r]
        guard let colon = match.firstIndex(of: ":") else { return nil }
        return Double(match[match.index(after: colon)...].trimmingCharacters(in: .whitespaces))
    }

    static func findRecords(_ text: String) -> [DesktopRecord] {
        let ns = text as NSString
        return recordRe.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            let s = ns.substring(with: match.range)
            guard var reset = number("resetsAt", in: s), let util = number("utilization", in: s), reset >= 0 else { return nil }
            var observed = number("observedAt", in: s) ?? 0
            if reset > 1e11 { reset /= 1000 }
            if observed > 1e11 { observed /= 1000 }
            let atWall = s.range(of: #""atWall"\s*:\s*true"#, options: .regularExpression) != nil
            return DesktopRecord(resetsAt: reset, utilization: max(0, util), observedAt: observed, atWall: atWall)
        }
    }

    static func newest(_ current: DesktopRecord?, _ records: [DesktopRecord]) -> DesktopRecord? {
        records.reduce(current) { best, r in (best == nil || r.observedAt >= best!.observedAt) ? r : best }
    }
}

// MARK: - V8 (подмножество формата structured clone: объекты, строки, числа, null, bool)

enum V8 {
    static func read(_ b: [UInt8], _ p: inout Int, depth: Int = 0) throws -> Any {
        guard depth < 16 else { throw LevelDBError.invalid("too deep") }
        while p < b.count, b[p] == 0x00 { p += 1 }
        guard p < b.count else { throw LevelDBError.invalid("truncated v8") }
        let tag = b[p]; p += 1
        switch tag {
        case 0x6f:
            var obj: [String: Any] = [:]
            while true {
                while p < b.count, b[p] == 0x00 { p += 1 }
                guard p < b.count else { throw LevelDBError.invalid("truncated v8 object") }
                if b[p] == 0x7b { p += 1; _ = try LevelDB.varint(b, &p); return obj }
                let key = try read(b, &p, depth: depth + 1)
                let value = try read(b, &p, depth: depth + 1)
                obj["\(key)"] = value
            }
        case 0x22, 0x63:
            let n = try LevelDB.varint(b, &p)
            guard p + n <= b.count else { throw LevelDBError.invalid("truncated v8 string") }
            let data = Data(b[p..<p + n]); p += n
            return String(data: data, encoding: tag == 0x22 ? .isoLatin1 : .utf16LittleEndian) ?? ""
        case 0x4e:
            guard p + 8 <= b.count else { throw LevelDBError.invalid("truncated v8 double") }
            let bits = b[p..<p + 8].enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << (8 * UInt64($1.offset)) }
            p += 8
            return Double(bitPattern: bits)
        case 0x49:
            let z = try LevelDB.varint(b, &p)
            return Double((z >> 1) ^ -(z & 1))
        case 0x55: return Double(try LevelDB.varint(b, &p))
        case 0x30, 0x5f: return NSNull()
        case 0x54: return true
        case 0x46: return false
        default: throw LevelDBError.invalid("unsupported v8 tag \(tag)")
        }
    }
}

extension Array where Element == UInt8 {
    func firstRange(of needle: [UInt8], from start: Int) -> Range<Int>? {
        guard !needle.isEmpty, count >= needle.count, start <= count - needle.count else { return nil }
        var i = start
        while i <= count - needle.count {
            if self[i] == needle[0] && self[i..<i + needle.count].elementsEqual(needle) { return i..<i + needle.count }
            i += 1
        }
        return nil
    }
}

// MARK: - LevelDB / Snappy

enum LevelDBError: Error { case invalid(String) }

enum LevelDB {
    static let tableMagic: UInt64 = 0xdb4775248b80fb57

    static func latin1(_ data: Data) -> String { String(data: data, encoding: .isoLatin1) ?? "" }

    static func varint(_ b: [UInt8], _ p: inout Int) throws -> Int {
        var result = 0, shift = 0
        while shift < 64 {
            guard p < b.count else { throw LevelDBError.invalid("truncated varint") }
            let c = b[p]; p += 1
            result |= Int(c & 0x7f) << shift
            if c & 0x80 == 0 { return result }
            shift += 7
        }
        throw LevelDBError.invalid("bad varint")
    }

    static func snappy(_ src: [UInt8]) throws -> [UInt8] {
        var p = 0
        let size = try varint(src, &p)
        guard size >= 0, size <= 256 << 20 else { throw LevelDBError.invalid("bad snappy length") }
        var dst = [UInt8](); dst.reserveCapacity(size)
        func le(_ n: Int) throws -> Int {
            guard p + n <= src.count else { throw LevelDBError.invalid("truncated snappy") }
            var v = 0
            for i in 0..<n { v |= Int(src[p + i]) << (8 * i) }
            p += n
            return v
        }
        while p < src.count {
            let tag = Int(src[p]); p += 1
            var n: Int, off: Int
            switch tag & 3 {
            case 0:
                n = (tag >> 2) + 1
                if n > 60 { n = try le(n - 60) + 1 }
                guard p + n <= src.count else { throw LevelDBError.invalid("bad snappy literal") }
                dst.append(contentsOf: src[p..<p + n]); p += n
                continue
            case 1: n = ((tag >> 2) & 7) + 4; off = ((tag >> 5) << 8) | (try le(1))
            case 2: n = (tag >> 2) + 1; off = try le(2)
            default: n = (tag >> 2) + 1; off = try le(4)
            }
            guard off > 0, off <= dst.count, dst.count + n <= size else { throw LevelDBError.invalid("bad snappy copy") }
            for _ in 0..<n { dst.append(dst[dst.count - off]) }
        }
        guard dst.count == size else { throw LevelDBError.invalid("truncated snappy block") }
        return dst
    }

    private static func block(_ f: [UInt8], _ offset: Int, _ size: Int) throws -> [UInt8] {
        guard offset >= 0, size >= 0, offset + size + 5 <= f.count else { throw LevelDBError.invalid("bad block handle") }
        let raw = Array(f[offset..<offset + size])
        switch f[offset + size] {
        case 0: return raw
        case 1: return try snappy(raw)
        default: throw LevelDBError.invalid("unknown block compression")
        }
    }

    static func tableText(_ path: String) throws -> String {
        let f = [UInt8](try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe))
        guard f.count >= 48 else { throw LevelDBError.invalid("not a table") }
        let magic = f[(f.count - 8)...].enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << (8 * UInt64($1.offset)) }
        guard magic == tableMagic else { throw LevelDBError.invalid("not a table") }
        var p = f.count - 48
        _ = try varint(f, &p); _ = try varint(f, &p)
        let indexOffset = try varint(f, &p), indexSize = try varint(f, &p)
        let index = try block(f, indexOffset, indexSize)
        guard index.count >= 4 else { return "" }
        let restarts = index[(index.count - 4)...].enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) }
        let limit = index.count - 4 - restarts * 4
        var q = 0, parts: [String] = []
        while q < limit {
            _ = try varint(index, &q)
            let keyLen = try varint(index, &q), valueLen = try varint(index, &q)
            q += keyLen
            var v = q
            let off = try varint(index, &v), size = try varint(index, &v)
            parts.append(latin1(Data(try block(f, off, size))))
            q += valueLen
        }
        return parts.joined(separator: "\n")
    }
}
