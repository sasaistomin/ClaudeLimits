// ClaudeLimits — фоновый опрос источников (LimitMonitoringService).
// Каждый источник опрашивается на своей фоновой очереди: изменения файлов определяются по размеру и mtime
// (с debounce, чтобы не реагировать на каждую запись LevelDB), плюс полный разбор раз в interval.
// Новые снимки LimitMetrics доставляются подписчикам на главном потоке.

import Foundation

func pathSignature(_ path: String) -> [String] {
    guard !path.isEmpty else { return [] }
    let fm = FileManager.default
    var isDir: ObjCBool = false
    guard fm.fileExists(atPath: path, isDirectory: &isDir) else { return [] }
    let entries = isDir.boolValue ? ((try? fm.contentsOfDirectory(atPath: path)) ?? []).sorted() : [""]
    return entries.compactMap { name in
        let p = name.isEmpty ? path : (path as NSString).appendingPathComponent(name)
        guard let a = try? fm.attributesOfItem(atPath: p) else { return nil }
        let mtime = (a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(name)|\((a[.size] as? NSNumber)?.int64Value ?? -1)|\(mtime)"
    }
}

final class LimitMonitoringService {
    var interval: Double = 5
    var debounce: Double = 0.75
    private(set) var latest: [LimitSource: LimitMetrics] = [:]
    private var workers: [LimitSource: Worker] = [:]
    private var handlers: [LimitSource: [(LimitMetrics) -> Void]] = [:]

    var activeWorkers: Int { workers.count }

    func subscribe(_ source: LimitSource, _ handler: @escaping (LimitMetrics) -> Void) {
        handlers[source, default: []].append(handler)
    }

    func watch(_ source: LimitSource, path: String? = nil) {
        unwatch(source)
        let w = Worker(parser: newLimitParser(source, path: path), interval: interval, debounce: debounce)
        w.deliver = { [weak self, weak w] m in
            DispatchQueue.main.async {
                guard let self, let w, self.workers[source] === w else { return }
                self.latest[source] = m
                self.handlers[source]?.forEach { $0(m) }
            }
        }
        workers[source] = w
        w.start()
    }

    func unwatch(_ source: LimitSource) {
        workers.removeValue(forKey: source)?.stop()
        latest.removeValue(forKey: source)
    }

    /// Крутит главный runloop, пока у всех источников не появится первый снимок.
    @discardableResult
    func waitForAll(timeout: Double) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if workers.keys.allSatisfy({ latest[$0] != nil }) { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        return workers.keys.allSatisfy { latest[$0] != nil }
    }

    func close() {
        for s in Array(workers.keys) { unwatch(s) }
        handlers.removeAll()
    }

    deinit { workers.values.forEach { $0.stop() } }
}

private final class Worker {
    private let parser: LimitParser
    private let interval: Double
    private let debounce: Double
    private let queue: DispatchQueue
    private var timer: DispatchSourceTimer?
    private var last: LimitMetrics?
    private var signature: [String] = []
    private var dirty = false
    private var changedAt = 0.0
    private var firstChangeAt = 0.0
    private var parsedAt = 0.0
    var deliver: ((LimitMetrics) -> Void)?

    init(parser: LimitParser, interval: Double, debounce: Double) {
        self.parser = parser
        self.interval = interval
        self.debounce = debounce
        queue = DispatchQueue(label: "claude-limits.\(parser.source.rawValue)", qos: .utility)
    }

    func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: min(0.5, debounce))
        t.setEventHandler { [weak self] in self?.tick() }
        timer = t
        t.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
        deliver = nil
    }

    private func tick() {
        let now = Date().timeIntervalSince1970
        let sig = pathSignature(parser.getLogPath())
        if sig != signature {
            if !dirty { firstChangeAt = now }
            signature = sig
            dirty = true
            changedAt = now
        }
        let settled = dirty && (now - changedAt >= debounce || now - firstChangeAt >= 10 * debounce)
        guard parsedAt == 0 || settled || now - parsedAt >= interval else { return }
        dirty = false
        parsedAt = now
        let m = parser.parseLimits(now: now)
        if m != last {
            last = m
            deliver?(m)
        }
    }
}
