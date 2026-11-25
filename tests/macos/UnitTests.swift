// Юнит-тесты логики macOS-версии (macos/Core.swift).
// Запуск: bash tests/macos/run.sh   (или вместе со всем: bash tests/run-all.sh)
//
// Command Line Tools не содержат XCTest, поэтому здесь свой маленький раннер.

import Foundation

var passed = 0
var failed: [String] = []
var current = ""

func check(_ cond: @autoclosure () -> Bool, _ msg: String, line: Int = #line) {
    if cond() { passed += 1 } else { failed.append("\(current): \(msg) (строка \(line))") }
}

func eq<T: Equatable>(_ a: T, _ b: T, _ msg: String = "", line: Int = #line) {
    check(a == b, "\(msg) ожидалось «\(b)», получено «\(a)»", line: line)
}

func test(_ name: String, _ body: () -> Void) {
    current = name
    body()
}

let now: Double = 1_800_000_000
let nowDate = Date(timeIntervalSince1970: now)

// MARK: - Поддельные данные Claude Desktop (LevelDB)

func desktopRecord(_ util: Double, _ reset: Double, _ observed: Double, atWall: Bool = false) -> String {
    "{\"resetsAt\":\(Int(reset)),\"utilization\":\(util),\"prevUtilization\":0.1,\"observedAt\":\(observed),\"atWall\":\(atWall),\"fired\":[],\"shown\":false}"
}

func journalEntry(_ json: String) -> Data {
    Data([0x9a, 0x01, 0x00, 0x00, 0x01]) + Data("_https://claude.ai".utf8) + Data([0x00, 0x01]) + Data("ochre.test".utf8)
        + Data([0x8f, 0x01]) + json.data(using: .isoLatin1)! + Data([0x00, 0x7b, 0xff])
}

func varintBytes(_ v: Int) -> [UInt8] {
    var v = v, out: [UInt8] = []
    repeat { var b = UInt8(v & 0x7f); v >>= 7; if v > 0 { b |= 0x80 }; out.append(b) } while v > 0
    return out
}

func blockBytes(_ key: [UInt8], _ value: [UInt8]) -> [UInt8] {
    varintBytes(0) + varintBytes(key.count) + varintBytes(value.count) + key + value + [0, 0, 0, 0, 1, 0, 0, 0]
}

func writeTable(_ path: String, _ json: String, compress: Bool) {
    let data = blockBytes(Array("_https://claude.ai.ochre.test".utf8), [0x01] + Array(json.utf8))
    var body = data
    if compress {
        body = varintBytes(data.count)
        var i = 0
        while i < data.count {
            let n = min(60, data.count - i)
            body.append(UInt8((n - 1) << 2)); body += data[i..<i + n]; i += n
        }
    }
    var f = body + [compress ? 1 : 0, 0, 0, 0, 0]
    let indexOffset = f.count
    let index = blockBytes(Array("z".utf8), varintBytes(0) + varintBytes(body.count))
    f += index + [0, 0, 0, 0, 0]
    var footer = varintBytes(indexOffset) + varintBytes(0) + varintBytes(indexOffset) + varintBytes(index.count)
    footer += [UInt8](repeating: 0, count: 40 - footer.count)
    f += footer + (0..<8).map { UInt8((LevelDB.tableMagic >> (8 * UInt64($0))) & 0xff) }
    try! Data(f).write(to: URL(fileURLWithPath: path))
}

func append(_ path: String, _ data: Data) {
    if let h = FileHandle(forWritingAtPath: path) { h.seekToEndOfFile(); h.write(data); try? h.close() }
    else { try! data.write(to: URL(fileURLWithPath: path)) }
}

func fakeDesktop() -> (root: String, db: String) {
    let root = NSTemporaryDirectory() + "cl-desktop-" + UUID().uuidString + "/Claude"
    let db = root + "/Local Storage/leveldb"
    try! FileManager.default.createDirectory(atPath: db, withIntermediateDirectories: true)
    try! "MANIFEST-000001\n".write(toFile: db + "/CURRENT", atomically: true, encoding: .utf8)
    return (root, db)
}

func v8str(_ s: String) -> [UInt8] { [0x22, UInt8(s.utf8.count)] + Array(s.utf8) }
func v8num(_ d: Double) -> [UInt8] { [0x4e] + (0..<8).map { UInt8((d.bitPattern >> (8 * UInt64($0))) & 0xff) } }
func v8window(_ util: Double, _ reset: Double, status: String = "within_limit") -> [UInt8] {
    [0x6f] + v8str("status") + v8str(status) + v8str("resets_at") + v8num(reset)
        + v8str("utilization") + v8num(util) + v8str("surpassed_threshold") + [0x30, 0x7b, 0x04]
}
/// Кэш ответа claude.ai в IndexedDB: обёртка Chromium (ff 11 02) + Snappy + V8.
func idbBlob(five: (Double, Double)?, week: (Double, Double)?, updatedMs: Double) -> Data {
    var windows: [UInt8] = [0x6f]
    if let f = five { windows += v8str("5h") + v8window(f.0, f.1) }
    if let w = week { windows += v8str("7d") + v8window(w.0, w.1) }
    windows += [0x7b, 0x02]
    let v8: [UInt8] = [0xff, 0x15, 0x6f] + v8str("messageLimits") + [0x6f] + v8str("type") + v8str("within_limit")
        + v8str("windows") + windows + [0x7b, 0x02, 0x7b, 0x01] + [0x22, 0x0d] + Array("dataUpdatedAt".utf8) + v8num(updatedMs)
    var out: [UInt8] = [0xff, 0x11, 0x02] + varintBytes(v8.count)
    var i = 0
    while i < v8.count { let n = min(60, v8.count - i); out.append(UInt8((n - 1) << 2)); out += v8[i..<i + n]; i += n }
    return Data(out)
}

func near(_ a: Double?, _ b: Double) -> Bool { a.map { abs($0 - b) < 1e-9 } ?? false }

@main
enum UnitTests {
    static func main() {

        // MARK: L10n.countdown
        test("countdown: минуты/часы/дни, ru и en") {
            let ru = L10n(ru: true), en = L10n(ru: false)
            eq(ru.countdown(to: nowDate.addingTimeInterval(5 * 60), now: nowDate), "через 5 мин")
            eq(ru.countdown(to: nowDate.addingTimeInterval(2 * 3600 + 15 * 60), now: nowDate), "через 2 ч 15 мин")
            eq(ru.countdown(to: nowDate.addingTimeInterval(3 * 86400 + 4 * 3600), now: nowDate), "через 3 д 4 ч")
            eq(ru.countdown(to: nowDate.addingTimeInterval(-10), now: nowDate), "сброшен")
            eq(ru.countdown(to: nowDate, now: nowDate), "сброшен")
            eq(en.countdown(to: nowDate.addingTimeInterval(5 * 60), now: nowDate), "in 5m")
            eq(en.countdown(to: nowDate.addingTimeInterval(2 * 3600 + 15 * 60), now: nowDate), "in 2h 15m")
            eq(en.countdown(to: nowDate.addingTimeInterval(3 * 86400 + 4 * 3600), now: nowDate), "in 3d 4h")
            eq(en.countdown(to: nowDate.addingTimeInterval(-1), now: nowDate), "done")
        }

        test("L10n: тексты на обоих языках") {
            let ru = L10n(ru: true), en = L10n(ru: false)
            eq(ru.left(42), "осталось 42%"); eq(en.left(42), "42% left")
            eq(ru.lowTitle(.code, 20), "[Claude Code] Осталось 20%"); eq(en.lowTitle(.desktop, 20), "[Claude Desktop] 20% left")
            eq(ru.resetTitle(.desktop), "[Claude Desktop] Лимит сброшен")
            check(ru.lowBody(five: true, used: 80, countdown: "через 1 ч 0 мин").contains("5-часовое окно израсходовано на 80%"), "lowBody ru five")
            check(en.lowBody(five: false, used: 95, countdown: "in 2d 1h").contains("Weekly limit is 95% used"), "lowBody en week")
            check(ru.resetBody(five: false).contains("Недельный"), "resetBody ru week")
            check(!ru.title.isEmpty && !en.title.isEmpty, "title")
        }

        test("AppLanguage: явный выбор языка") {
            check(AppLanguage.ru.resolvedIsRussian, "ru -> русский")
            check(!AppLanguage.en.resolvedIsRussian, "en -> английский")
            eq(AppLanguage(rawValue: "ru"), .ru)
            eq(AppLanguage(rawValue: "мусор"), nil)
        }

        // MARK: Chart
        test("chartPoints: начало окна 0%, фильтр по окну, последняя точка = сейчас") {
            let state = WindowState(used: 40, resetsAt: nowDate.addingTimeInterval(3600))   // окно 5 ч: старт = now-4h
            let start = now - 4 * 3600
            let history = [
                Sample(t: start - 100, f: 99, fr: nil, w: nil, wr: nil),      // до начала окна — не берём
                Sample(t: start + 600, f: 10, fr: nil, w: 5, wr: nil),
                Sample(t: start + 7200, f: 25, fr: nil, w: nil, wr: nil),
                Sample(t: start + 8000, f: nil, fr: nil, w: 7, wr: nil),      // нет f — не берём для 5ч
                Sample(t: now + 100, f: 77, fr: nil, w: nil, wr: nil),        // из будущего — не берём
            ]
            let pts = chartPoints(kind: .fiveHour, state: state, history: history, now: nowDate)
            eq(pts.map(\.used), [0, 10, 25, 40])
            eq(pts.first?.date, Date(timeIntervalSince1970: start))
            eq(pts.last?.date, nowDate)
            let w = chartPoints(kind: .week, state: WindowState(used: 9, resetsAt: nowDate.addingTimeInterval(86400)),
                                history: history, now: nowDate)
            eq(w.map(\.used), [0, 5, 7, 9], "неделя: берём только точки с w")
        }

        test("forecastRunOut: закончится раньше сброса / хватит / мало данных") {
            // 5ч окно, прошло 2ч, израсходовано 60% -> 30%/ч -> 100% через 1ч20м, сброс через 3ч
            let s1 = WindowState(used: 60, resetsAt: nowDate.addingTimeInterval(3 * 3600))
            let r1 = forecastRunOut(kind: .fiveHour, state: s1, now: nowDate)
            check(r1 != nil, "должен быть прогноз")
            if let r1 { check(abs(r1.timeIntervalSince(nowDate) - 4800) < 1, "через 80 минут, а не \(r1.timeIntervalSince(nowDate))") }
            // прошло 4ч, израсходовано 20% -> 5%/ч, до сброса 1ч -> хватит
            let s2 = WindowState(used: 20, resetsAt: nowDate.addingTimeInterval(3600))
            eq(forecastRunOut(kind: .fiveHour, state: s2, now: nowDate), nil)
            // окно только началось (<5 мин) -> прогноза нет
            let s3 = WindowState(used: 10, resetsAt: nowDate.addingTimeInterval(5 * 3600 - 60))
            eq(forecastRunOut(kind: .fiveHour, state: s3, now: nowDate), nil)
            // 0% -> прогноза нет
            let s4 = WindowState(used: 0, resetsAt: nowDate.addingTimeInterval(3600))
            eq(forecastRunOut(kind: .fiveHour, state: s4, now: nowDate), nil)
        }

        // MARK: Notifications
        test("NotifyRules: пороги 80/95, один раз за окно") {
            var n: [String: Double] = [:]
            let reset = now + 3600
            eq(NotifyRules.decide(kind: "five_hour", window: Window(used_percentage: 50, resets_at: reset), notified: &n, now: now), nil, "50% — тихо")
            eq(NotifyRules.decide(kind: "five_hour", window: Window(used_percentage: 81, resets_at: reset), notified: &n, now: now),
               .low(threshold: 80, used: 81), "81% — первое уведомление")
            eq(NotifyRules.decide(kind: "five_hour", window: Window(used_percentage: 85, resets_at: reset), notified: &n, now: now), nil, "повтор 80% не нужен")
            eq(NotifyRules.decide(kind: "five_hour", window: Window(used_percentage: 96, resets_at: reset), notified: &n, now: now),
               .low(threshold: 95, used: 96), "96% — второе уведомление")
            eq(NotifyRules.decide(kind: "five_hour", window: Window(used_percentage: 99, resets_at: reset), notified: &n, now: now), nil, "повтор 95% не нужен")
            eq(NotifyRules.decide(kind: "five_hour", window: Window(used_percentage: 99, resets_at: reset + 600), notified: &n, now: now), nil,
               "resets_at «плавает» на 10 мин — то же окно")
        }

        test("NotifyRules: сразу 96% — одно уведомление, 80% помечается тоже") {
            var n: [String: Double] = [:]
            let reset = now + 3600
            eq(NotifyRules.decide(kind: "seven_day", window: Window(used_percentage: 96, resets_at: reset), notified: &n, now: now),
               .low(threshold: 95, used: 96))
            eq(n["seven_day:80"], reset, "80% помечен")
            eq(NotifyRules.decide(kind: "seven_day", window: Window(used_percentage: 97, resets_at: reset), notified: &n, now: now), nil)
        }

        test("NotifyRules: новое окно — уведомления снова приходят; окна независимы") {
            var n: [String: Double] = [:]
            _ = NotifyRules.decide(kind: "five_hour", window: Window(used_percentage: 85, resets_at: now + 3600), notified: &n, now: now)
            eq(NotifyRules.decide(kind: "five_hour", window: Window(used_percentage: 85, resets_at: now + 5 * 3600 + 3600), notified: &n, now: now),
               .low(threshold: 80, used: 85), "следующее 5ч окно")
            eq(NotifyRules.decide(kind: "seven_day", window: Window(used_percentage: 85, resets_at: now + 3600), notified: &n, now: now),
               .low(threshold: 80, used: 85), "неделя не зависит от 5ч")
        }

        test("NotifyRules: сброс окна") {
            var n: [String: Double] = [:]
            let reset = now - 60   // сбросилось минуту назад
            eq(NotifyRules.decide(kind: "five_hour", window: Window(used_percentage: 90, resets_at: reset), notified: &n, now: now), .reset)
            eq(NotifyRules.decide(kind: "five_hour", window: Window(used_percentage: 90, resets_at: reset), notified: &n, now: now), nil, "один раз")
            var n2: [String: Double] = [:]
            eq(NotifyRules.decide(kind: "five_hour", window: Window(used_percentage: 50, resets_at: reset), notified: &n2, now: now), nil,
               "был слабый расход — не беспокоим")
            eq(NotifyRules.decide(kind: "five_hour", window: Window(used_percentage: 90, resets_at: now - 3600), notified: &n2, now: now), nil,
               "сброс был час назад — устарело")
        }

        // MARK: Installer (чистые функции)
        test("Installer: добавление statusLine сохраняет остальные ключи") {
            let s: [String: Any] = ["model": "opus", "theme": "dark", "statusLine": ["type": "command", "command": "my.sh"]]
            let r = Installer.withStatusLine(s, command: "\"/x/ClaudeLimits\" --statusline")
            eq(r["model"] as? String, "opus"); eq(r["theme"] as? String, "dark")
            let sl = r["statusLine"] as? [String: Any]
            eq(sl?["type"] as? String, "command")
            eq(sl?["command"] as? String, "\"/x/ClaudeLimits\" --statusline")
        }

        test("Installer: удаляем только свой statusLine") {
            let ours: [String: Any] = ["a": 1, "statusLine": ["type": "command", "command": "\"/Apps/ClaudeLimits.app/Contents/MacOS/ClaudeLimits\" --statusline"]]
            let r = Installer.withoutOurStatusLine(ours)
            check(r != nil && r?["statusLine"] == nil && (r?["a"] as? Int) == 1, "наш statusLine удалён, остальное на месте")
            let foreign: [String: Any] = ["statusLine": ["type": "command", "command": "~/my-statusline.sh"]]
            check(Installer.withoutOurStatusLine(foreign) == nil, "чужой statusLine не трогаем")
            check(Installer.withoutOurStatusLine([:]) == nil, "пустые настройки")
        }

        // MARK: Модель limits.json
        test("LimitsFile: разбор файла, отсутствующие окна, дробные проценты") {
            let json = #"{"updated_at":1800000000,"model":"Opus","rate_limits":{"five_hour":{"used_percentage":23.5,"resets_at":1800003600}}}"#
            let f = try? JSONDecoder().decode(LimitsFile.self, from: Data(json.utf8))
            eq(f?.rate_limits.five_hour?.used_percentage, 23.5)
            check(f?.rate_limits.seven_day == nil, "недельного окна нет — это нормально")
            check((try? JSONDecoder().decode(LimitsFile.self, from: Data("{}".utf8))) == nil, "битый файл не разбирается")
        }

        test("Updater: сравнение версий") {
            check(Updater.isNewer("2.1.0", than: "2.0.0"), "2.1.0 > 2.0.0")
            check(Updater.isNewer("2.0.10", than: "2.0.9"), "числа, а не строки")
            check(Updater.isNewer("v3", than: "2.9.9"), "префикс v и короткая версия")
            check(Updater.isNewer("2.0.0\n", than: "1.0"), "перевод строки в файле")
            check(!Updater.isNewer("2.0.0", than: "2.0.0"), "та же версия — не обновление")
            check(!Updater.isNewer("1.9.0", than: "2.0.0"), "старая версия на сервере — не откатываемся")
            check(!Updater.isNewer("", than: "2.0.0"), "пустой файл")
            check(!Updater.isNewer("<html>404</html>", than: "0.0.0"), "страница ошибки вместо версии")
            check(Updater.isNewer("2.0.0", than: "0.0.0"), "версия не была известна")
            eq(Updater.components("2.10.1-beta"), [2, 10, 1])
        }

        // MARK: Парсеры (Strategy) и Claude Desktop
        test("Snappy: литералы и копирование с перекрытием, битый поток") {
            eq(try? LevelDB.snappy([0x0C, 0x0C, 0x61, 0x62, 0x63, 0x64, 0x11, 0x04]), Array("abcdabcdabcd".utf8))
            eq(try? LevelDB.snappy([6, 0x00, 0x78, 0x12, 0x01, 0x00]), Array("xxxxxx".utf8))
            check((try? LevelDB.snappy([0x0C, 0x11, 0x04])) == nil, "битый поток -> ошибка")
        }

        test("ClaudeDesktopParser: не установлен / пустая база / пути") {
            let p = ClaudeDesktopParser(customPath: NSTemporaryDirectory() + "cl-none-" + UUID().uuidString)
            eq(p.getLogPath(), ""); check(!p.isInstalled(), "не установлен")
            eq(p.parseLimits(now: now).status, .notFound); check(p.getResetTime() == nil, "нет времени сброса")
            let f = fakeDesktop()
            let q = ClaudeDesktopParser(customPath: f.root)
            check(q.isInstalled(), "установлен"); eq(q.getLogPath(), f.db)
            eq(ClaudeDesktopParser(customPath: f.db).getLogPath(), f.db, "путь прямо на leveldb:")
            eq(q.parseLimits(now: now).status, .noData)
        }

        test("ClaudeDesktopParser: журнал — свежая запись, проценты, время сброса") {
            let f = fakeDesktop(), log = f.db + "/000003.log"
            append(log, journalEntry(desktopRecord(0.35, now + 600, now - 7200)))
            append(log, journalEntry(desktopRecord(0.18, now + 3 * 3600, now - 60)))
            append(log, journalEntry(desktopRecord(0.9, now + 3 * 3600, now - 3600)))
            let p = ClaudeDesktopParser(customPath: f.root)
            let m = p.parseLimits(now: now)
            eq(m.status, .ok); eq(m.source, .desktop); eq(m.logPath, f.db); eq(m.windows.count, 1)
            let w = m.windows[0]
            check(w.rolling && w.id == "five_hour", "скользящее 5-часовое окно")
            check(near(w.used, 18) && near(w.left, 82), "самая свежая по observedAt: \(w.used)")
            eq(w.resetsAt, now + 3 * 3600); eq(m.updated, now - 60)
            eq(p.parseLimits(now: now + 3 * 3600 + 1).windows[0].used, 0, "после сброса — 0%:")
        }

        test("ClaudeDesktopParser: offset, обрыв записи, atWall, мусор, пересоздание журнала") {
            let f = fakeDesktop(), log = f.db + "/000005.log"
            append(log, journalEntry(desktopRecord(0.2, now + 3600, now - 300)))
            let p = ClaudeDesktopParser(customPath: f.root)
            check(near(p.parseLimits(now: now).windows.first?.used, 20), "первое чтение")
            let offset = p.journals[log]?.offset ?? 0
            eq(offset, (try! FileManager.default.attributesOfItem(atPath: log)[.size] as! NSNumber).uint64Value, "offset = размер:")
            let rec = Data(desktopRecord(0.55, now + 3600, now - 100).utf8)
            append(log, rec.prefix(40))
            check(near(p.parseLimits(now: now).windows.first?.used, 20), "недописанная запись не ломает результат")
            append(log, rec.dropFirst(40))
            check(near(p.parseLimits(now: now).windows.first?.used, 55), "запись собрана из хвоста")
            check((p.journals[log]?.offset ?? 0) > offset, "offset сдвинулся")
            append(log, Data(#"{"resetsAt":"x","utilization":}{"resetsAt":1,"observedAt":2}{{{"#.utf8) + Data([0xff]))
            append(log, journalEntry(desktopRecord(0.97, now + 1800, now - 10, atWall: true)))
            let w = p.parseLimits(now: now).windows.first
            check(w?.used == 100 && w?.left == 0 && w?.resetsAt == now + 1800, "atWall = исчерпано")
            try! Data([1, 2, 3]).write(to: URL(fileURLWithPath: log))
            eq(p.parseLimits(now: now).status, .noData, "журнал пересоздан:")
        }

        test("ClaudeDesktopParser: таблицы .ldb (Snappy и без сжатия), кэш, компакция") {
            let f = fakeDesktop()
            writeTable(f.db + "/000010.ldb", desktopRecord(0.31, now + 7200, now - 900), compress: true)
            check((try? LevelDB.tableText(f.db + "/000010.ldb"))?.contains("\"utilization\":0.31") == true, "Snappy-блок распакован")
            let p = ClaudeDesktopParser(customPath: f.root)
            check(near(p.parseLimits(now: now).windows.first?.used, 31), "запись из сжатой таблицы")
            check(p.tables[f.db + "/000010.ldb"] != nil, "таблица закэширована")
            writeTable(f.db + "/000011.ldb", desktopRecord(0.6, now + 7200, now - 100), compress: false)
            try! Data((0..<200).map { UInt8($0) }).write(to: URL(fileURLWithPath: f.db + "/000012.ldb"))
            append(f.db + "/000013.log", journalEntry(desktopRecord(0.05, now + 7200, now - 5000)))
            check(near(p.parseLimits(now: now).windows.first?.used, 60), "свежая запись из несжатой таблицы, битая пропущена")
            try! FileManager.default.removeItem(atPath: f.db + "/000011.ldb")
            _ = p.parseLimits(now: now)
            check(p.tables[f.db + "/000011.ldb"] == nil, "удалённая таблица убрана из кэша")
        }

        test("ClaudeDesktopParser: IndexedDB — недельный лимит и свежее 5-часовое окно") {
            let f = fakeDesktop()
            let blobDir = (f.root as NSString).appendingPathComponent("IndexedDB/https_claude.ai_0.indexeddb.blob/1/00")
            try! FileManager.default.createDirectory(atPath: blobDir, withIntermediateDirectories: true)
            try! idbBlob(five: (0.42, now + 3 * 3600), week: (0.08, now + 5 * 86400), updatedMs: (now - 30) * 1000)
                .write(to: URL(fileURLWithPath: blobDir + "/1d"))
            append(f.db + "/000003.log", journalEntry(desktopRecord(0.3, now + 3 * 3600, now - 600)))
            let p = ClaudeDesktopParser(customPath: f.root)
            var m = p.parseLimits(now: now)
            eq(m.status, .ok); eq(m.windows.map(\.id), ["five_hour", "seven_day"])
            check(near(m.window("five_hour")?.used, 42), "5ч из IndexedDB, он свежее Local Storage")
            check(near(m.window("seven_day")?.used, 8) && near(m.window("seven_day")?.left, 92), "неделя: осталось 92%")
            eq(m.window("seven_day")?.rolling, false); eq(m.window("seven_day")?.resetsAt, now + 5 * 86400)
            eq(m.updated, now - 30)
            append(f.db + "/000003.log", journalEntry(desktopRecord(0.5, now + 3 * 3600, now - 5)))
            m = p.parseLimits(now: now)
            check(near(m.window("five_hour")?.used, 50), "свежая запись Local Storage перекрывает кэш")
            check(near(m.window("seven_day")?.used, 8), "неделя остаётся из кэша")
            eq(m.samples.map { $0.f ?? -1 }.map { $0.rounded() }, [30, 50], "прошлые замеры окна для графика:")
            let url = URL(fileURLWithPath: NSTemporaryDirectory() + "cl-seed-" + UUID().uuidString + ".jsonl")
            History.append(m, to: url)
            eq(History.load(url).map { ($0.f ?? -1).rounded() }, [30, 50, 50], "история засеяна замерами + текущий снимок с неделей:")
            eq(History.load(url).last?.w, 8, "последняя строка несёт недельное значение:")
            History.append(m, to: url)
            eq(History.load(url).count, 3, "повторный снимок не дублирует историю:")
            try! Data([0xff, 0x11, 0x02, 0x05, 0x01]).write(to: URL(fileURLWithPath: blobDir + "/20"))
            eq(p.parseLimits(now: now).windows.count, 2, "битый blob пропущен:")
            let only = ClaudeDesktopParser.findWindows(Array(idbBlob(five: nil, week: (1.0, now + 100), updatedMs: 0).dropFirst(0)), fallbackTime: 7)
            check(only.isEmpty, "сжатые данные без распаковки не разбираются")
        }

        test("History: история Claude Desktop пишется только при изменении процентов") {
            let url = URL(fileURLWithPath: NSTemporaryDirectory() + "cl-hist-" + UUID().uuidString + ".jsonl")
            var m = LimitMetrics(source: .desktop, status: .ok, updated: now)
            m.windows = [LimitWindow(id: "five_hour", raw: 42, resetsAt: now + 3600, rolling: true, now: now),
                         LimitWindow(id: "seven_day", raw: 8, resetsAt: now + 86400, rolling: false, now: now)]
            History.append(m, to: url); History.append(m, to: url)
            eq(History.load(url).count, 1, "без изменений — одна строка:")
            m.windows[0] = LimitWindow(id: "five_hour", raw: 45, resetsAt: now + 3600, rolling: true, now: now)
            m.updated = now + 60
            History.append(m, to: url)
            let h = History.load(url)
            eq(h.count, 2); eq(h.last?.f, 45); eq(h.last?.w, 8); eq(h.last?.t, now + 60)
            History.append(LimitMetrics(source: .desktop, status: .notFound), to: url)
            eq(History.load(url).count, 2, "без данных не пишем:")
            let pts = chartPoints(kind: .week, state: m.windows[1].state, history: h, now: nowDate)
            eq(pts.first?.used, 0, "график недели начинается с 0%:")
            let dup = [Sample(t: now - 60, f: 42, fr: nil, w: nil, wr: nil), Sample(t: now - 60, f: 42, fr: nil, w: 8, wr: nil)]
            eq(chartPoints(kind: .fiveHour, state: m.windows[0].state, history: dup, now: nowDate).count, 3,
               "точки с одинаковым временем не дублируются (иначе заливка складывается):")
        }

        test("ClaudeCodeParser: обёртка над limits.json") {
            let dir = NSTemporaryDirectory() + "cl-code-" + UUID().uuidString
            try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let path = dir + "/limits.json"
            let p = ClaudeCodeParser(path: path)
            eq(p.parseLimits(now: now).status, .noData)
            eq(ClaudeCodeParser(path: dir + "/no/limits.json").parseLimits(now: now).status, .notFound)
            try! #"{"updated_at":1800000000,"rate_limits":{"five_hour":{"used_percentage":23.5,"resets_at":1800003600},"seven_day":{"used_percentage":90,"resets_at":1799999990}}}"#
                .write(toFile: path, atomically: true, encoding: .utf8)
            let m = p.parseLimits(now: now)
            eq(m.status, .ok); eq(m.updated, now)
            eq(m.window("five_hour")?.left, 76.5); eq(m.window("five_hour")?.rolling, false)
            eq(m.window("seven_day")?.used, 0, "сброшенное окно:"); eq(m.window("seven_day")?.raw, 90)
            try! "{broken".write(toFile: path, atomically: true, encoding: .utf8)
            eq(p.parseLimits(now: now).status, .invalid, "битый файл:")
            for s in LimitSource.allCases { eq(newLimitParser(s).source, s, "единый контракт:") }
        }

        test("Уведомления: источник в заголовке, Desktop — порог 100% и свой ключ") {
            let ru = L10n(ru: true), en = L10n(ru: false)
            let code = LimitWindow(id: "five_hour", raw: 81, resetsAt: now + 3600, rolling: false, now: now)
            let t = notificationText(.low(threshold: 80, used: 81), source: .code, window: code, l: ru, now: nowDate)
            eq(t.title, "[Claude Code] Осталось 19%"); eq(t.body, "5-часовое окно израсходовано на 81%. Сброс через 1 ч 0 мин.")
            eq(notifyKey(.code, code), "five_hour", "ключ Code не изменился:")
            let desk = LimitWindow(id: "five_hour", raw: 100, resetsAt: now + 5400, rolling: true, now: now)
            eq(notifyKey(.desktop, desk), "desktop:five_hour")
            var n: [String: Double] = [:]
            let ev = NotifyRules.decide(kind: notifyKey(.desktop, desk), window: Window(used_percentage: 100, resets_at: desk.resetsAt),
                                        notified: &n, now: now, thresholds: notifyThresholds(desk))
            eq(ev, .low(threshold: 100, used: 100))
            eq(Set(n.keys), ["desktop:five_hour:100", "desktop:five_hour:95", "desktop:five_hour:80"])
            let at = ru.clock(Date(timeIntervalSince1970: now + 5400))
            let d = notificationText(ev!, source: .desktop, window: desk, l: ru, now: nowDate)
            eq(d.title, "[Claude Desktop] Осталось 0%"); eq(d.body, "5-часовое окно сообщений исчерпано. Сброс в \(at).")
            eq(notificationText(.low(threshold: 80, used: 84), source: .desktop, window: desk, l: en).body,
               "5-hour message window is 84% used. Resets at \(at).")
            eq(ru.usedResetAt(18, Date(timeIntervalSince1970: now + 7800), now: nowDate),
               "Использовано 18% · сброс в \(ru.clock(Date(timeIntervalSince1970: now + 7800))) (через 2 ч 10 мин)")
        }

        test("LimitMonitoringService: фоновые очереди, подписка, debounce, смена папки") {
            let dir = NSTemporaryDirectory() + "cl-mon-" + UUID().uuidString
            try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let code = dir + "/limits.json"
            func write(_ u: Double) {
                let t = Date().timeIntervalSince1970
                try! "{\"updated_at\":\(t),\"rate_limits\":{\"five_hour\":{\"used_percentage\":\(u),\"resets_at\":\(t + 3600)}}}"
                    .write(toFile: code, atomically: true, encoding: .utf8)
            }
            write(10)
            let f = fakeDesktop()
            let t = Date().timeIntervalSince1970
            append(f.db + "/000003.log", journalEntry(desktopRecord(0.25, t + 3600, t)))
            let svc = LimitMonitoringService()
            svc.interval = 1.5; svc.debounce = 0.2
            var got = 0
            svc.subscribe(.code) { _ in got += 1 }
            svc.watch(.code, path: code)
            svc.watch(.desktop, path: f.root)
            check(svc.waitForAll(timeout: 10), "первые снимки получены")
            eq(svc.latest[.code]?.window("five_hour")?.used, 10)
            check(near(svc.latest[.desktop]?.window("five_hour")?.used, 25), "Desktop 25%")
            eq(got, 1, "подписчик вызван один раз:")
            for u in [30.0, 40, 64] { write(u); Thread.sleep(forTimeInterval: 0.05) }
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline, svc.latest[.code]?.window("five_hour")?.used != 64 { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            eq(svc.latest[.code]?.window("five_hour")?.used, 64, "изменение доставлено:")
            check(got <= 3, "debounce: серия записей не даёт событие на каждую (\(got))")
            svc.watch(.desktop, path: dir + "/missing")
            check(svc.waitForAll(timeout: 10), "смена папки")
            eq(svc.latest[.desktop]?.status, .notFound)
            svc.close()
            eq(svc.activeWorkers, 0, "все очереди остановлены:")
        }

        // MARK: Итог
        print("")
        if failed.isEmpty {
            print("✅ macOS unit: все \(passed) проверок прошли")
            exit(0)
        } else {
            for f in failed { print("❌ \(f)") }
            print("macOS unit: \(failed.count) провалено, \(passed) прошло")
            exit(1)
        }
    }
}
