// ClaudeLimits — логика без интерфейса: statusline, установка, история, прогноз, правила уведомлений, тексты.
// Покрыта тестами: tests/macos/UnitTests.swift и tests/macos/integration.sh

import Foundation

let home = ProcessInfo.processInfo.environment["HOME"].map { URL(fileURLWithPath: $0) }
    ?? FileManager.default.homeDirectoryForCurrentUser
let claudeDir = home.appendingPathComponent(".claude")
let limitsURL = claudeDir.appendingPathComponent("limits.json")
let settingsURL = claudeDir.appendingPathComponent("settings.json")

// MARK: - Statusline mode

enum StatusLine {
    static func run() {
        let input = FileHandle.standardInput.readDataToEndOfFile()
        guard let json = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any] else {
            print("[Claude]"); return
        }
        let model = (json["model"] as? [String: Any])?["display_name"] as? String ?? "Claude"
        let rl = json["rate_limits"] as? [String: Any]

        if let rl {
            History.appendIfChanged(new: rl)
            let out: [String: Any] = [
                "updated_at": Int(Date().timeIntervalSince1970),
                "rate_limits": rl,
                "model": model,
            ]
            if let data = try? JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted]) {
                try? FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
                try? data.write(to: limitsURL, options: .atomic)
            }
        }

        func pct(_ key: String) -> Int? {
            ((rl?[key] as? [String: Any])?["used_percentage"] as? NSNumber).map { Int($0.doubleValue.rounded()) }
        }
        var parts: [String] = []
        if let f = pct("five_hour") { parts.append("5h: \(f)%") }
        if let w = pct("seven_day") { parts.append("7d: \(w)%") }
        print(parts.isEmpty ? "[\(model)]" : "[\(model)] " + parts.joined(separator: " "))
    }
}

// MARK: - Installer (settings.json)

enum Installer {
    static var command: String {
        let exe = Bundle.main.executableURL?.resolvingSymlinksInPath().path
            ?? URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path
        return "\"\(exe)\" --statusline"
    }

    static func readSettings() -> [String: Any]? {
        guard let data = try? Data(contentsOf: settingsURL) else { return [:] }
        if data.isEmpty { return [:] }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func writeSettings(_ s: [String: Any]) -> Bool {
        do {
            try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: s, options: [.prettyPrinted, .withoutEscapingSlashes])
            try data.write(to: settingsURL, options: .atomic)
            return true
        } catch {
            print("Ошибка записи \(settingsURL.path): \(error)"); return false
        }
    }

    static func backup() {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return }
        let bak = claudeDir.appendingPathComponent("settings.json.bak")
        try? FileManager.default.removeItem(at: bak)
        try? FileManager.default.copyItem(at: settingsURL, to: bak)
    }

    /// Чистая функция: настройки с нашим statusLine.
    static func withStatusLine(_ settings: [String: Any], command: String) -> [String: Any] {
        var s = settings
        s["statusLine"] = ["type": "command", "command": command]
        return s
    }

    /// Чистая функция: убирает statusLine, только если он наш. Возвращает nil, если менять нечего.
    static func withoutOurStatusLine(_ settings: [String: Any]) -> [String: Any]? {
        guard let old = settings["statusLine"] as? [String: Any], let cmd = old["command"] as? String,
              cmd.contains("ClaudeLimits") else { return nil }
        var s = settings
        s.removeValue(forKey: "statusLine")
        return s
    }

    static func install() -> Bool {
        guard let s = readSettings() else {
            print("Не удалось разобрать \(settingsURL.path) — исправьте JSON и повторите."); return false
        }
        if let old = s["statusLine"] as? [String: Any], let cmd = old["command"] as? String,
           !cmd.contains("--statusline") {
            print("Внимание: ваш прежний statusLine (\(cmd)) будет заменён. Копия: settings.json.bak")
        }
        backup()
        guard writeSettings(withStatusLine(s, command: command)) else { return false }
        print("statusLine прописан в \(settingsURL.path)")
        return true
    }

    static func uninstall() -> Bool {
        guard let s = readSettings() else { return false }
        if let updated = withoutOurStatusLine(s) {
            backup()
            guard writeSettings(updated) else { return false }
            print("statusLine удалён из \(settingsURL.path)")
        }
        return true
    }
}

// MARK: - Model

struct Window: Decodable {
    let used_percentage: Double
    let resets_at: TimeInterval
}

struct RateLimits: Decodable {
    let five_hour: Window?
    let seven_day: Window?
}

struct LimitsFile: Decodable {
    let updated_at: TimeInterval
    let rate_limits: RateLimits
    let model: String?
}

struct WindowState {
    let used: Double        // 0...100
    let resetsAt: Date
    var remaining: Double { max(0, 100 - used) }
}

// MARK: - History (~/.claude/limits-history.jsonl)
// Одна строка на изменение: {"t":<epoch>,"f":<5h %>,"fr":<5h reset>,"w":<7d %>,"wr":<7d reset>}

let historyURL = claudeDir.appendingPathComponent("limits-history.jsonl")

struct Sample: Decodable {
    let t: Double
    let f: Double?
    let fr: Double?
    let w: Double?
    let wr: Double?
}

enum WindowKind: String, CaseIterable, Identifiable {
    case fiveHour, week
    var id: String { rawValue }
    var duration: TimeInterval { self == .fiveHour ? 5 * 3600 : 7 * 86400 }
}

enum History {
    static let keepDays: Double = 8
    static let maxBytes = 512 * 1024

    private static func used(_ rl: [String: Any]?, _ k: String) -> Double? {
        ((rl?[k] as? [String: Any])?["used_percentage"] as? NSNumber)?.doubleValue
    }
    private static func reset(_ rl: [String: Any]?, _ k: String) -> Double? {
        ((rl?[k] as? [String: Any])?["resets_at"] as? NSNumber)?.doubleValue
    }

    /// Вызывается из --statusline до перезаписи limits.json: дописывает строку, только если проценты изменились.
    static func appendIfChanged(new rl: [String: Any]) {
        let old = (try? Data(contentsOf: limitsURL))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let oldRL = old?["rate_limits"] as? [String: Any]
        let hasHistory = FileManager.default.fileExists(atPath: historyURL.path)
        let changed = used(oldRL, "five_hour") != used(rl, "five_hour")
            || used(oldRL, "seven_day") != used(rl, "seven_day")
        guard changed || !hasHistory else { return }

        var s: [String: Any] = ["t": Int(Date().timeIntervalSince1970)]
        if let v = used(rl, "five_hour") { s["f"] = v }
        if let v = reset(rl, "five_hour") { s["fr"] = v }
        if let v = used(rl, "seven_day") { s["w"] = v }
        if let v = reset(rl, "seven_day") { s["wr"] = v }
        guard var line = try? JSONSerialization.data(withJSONObject: s) else { return }
        line.append(0x0A)

        if let h = try? FileHandle(forWritingTo: historyURL) {
            h.seekToEndOfFile(); h.write(line); try? h.close()
        } else {
            try? line.write(to: historyURL)
        }
        pruneIfLarge()
    }

    private static func pruneIfLarge() {
        let size = (try? FileManager.default.attributesOfItem(atPath: historyURL.path)[.size] as? Int) ?? 0
        guard size > maxBytes, let text = try? String(contentsOf: historyURL, encoding: .utf8) else { return }
        let cutoff = Date().timeIntervalSince1970 - keepDays * 86400
        let kept = text.split(separator: "\n").filter { line in
            guard let d = line.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let t = (o["t"] as? NSNumber)?.doubleValue else { return false }
            return t >= cutoff
        }
        try? (kept.joined(separator: "\n") + "\n").write(to: historyURL, atomically: true, encoding: .utf8)
    }

    static func load() -> [Sample] {
        guard let text = try? String(contentsOf: historyURL, encoding: .utf8) else { return [] }
        let dec = JSONDecoder()
        return text.split(separator: "\n").compactMap { try? dec.decode(Sample.self, from: Data($0.utf8)) }
    }
}

struct ChartPoint: Identifiable, Equatable {
    let id = UUID()
    let date: Date
    let used: Double
    static func == (a: ChartPoint, b: ChartPoint) -> Bool { a.date == b.date && a.used == b.used }
}

/// Точки графика для текущего окна: от начала окна (0%) через историю к «сейчас».
func chartPoints(kind: WindowKind, state: WindowState, history: [Sample], now: Date = Date()) -> [ChartPoint] {
    let start = state.resetsAt.addingTimeInterval(-kind.duration)
    var pts = [ChartPoint(date: start, used: 0)]
    for s in history {
        let t = Date(timeIntervalSince1970: s.t)
        guard t >= start, t <= now, let v = (kind == .fiveHour ? s.f : s.w) else { continue }
        pts.append(ChartPoint(date: t, used: v))
    }
    pts.append(ChartPoint(date: now, used: state.used))
    return pts
}

/// Прогноз по среднему темпу с начала окна: когда расход дойдёт до 100% (nil — хватит до сброса).
func forecastRunOut(kind: WindowKind, state: WindowState, now: Date = Date()) -> Date? {
    let start = state.resetsAt.addingTimeInterval(-kind.duration)
    let elapsed = now.timeIntervalSince(start)
    guard elapsed > 300, state.used > 0 else { return nil }
    let rate = state.used / elapsed                  // % в секунду
    let t100 = now.addingTimeInterval((100 - state.used) / rate)
    return t100 < state.resetsAt ? t100 : nil
}

// MARK: - Localization

enum AppLanguage: String, CaseIterable, Identifiable {
    case system, ru, en
    var id: String { rawValue }

    /// Название пункта в выборе языка — всегда на своём языке.
    func label(_ l: L10n) -> String {
        switch self {
        case .system: return l.systemLanguage
        case .ru: return "Русский"
        case .en: return "English"
        }
    }

    var resolvedIsRussian: Bool {
        switch self {
        case .ru: return true
        case .en: return false
        case .system: return (Locale.preferredLanguages.first ?? "en").hasPrefix("ru")
        }
    }
}

struct L10n {
    let ru: Bool

    var locale: Locale { Locale(identifier: ru ? "ru_RU" : "en_US") }

    var title: String          { ru ? "Лимиты Claude" : "Claude Limits" }
    var fiveHour: String       { ru ? "5-часовое окно" : "5-hour window" }
    var week: String           { ru ? "Неделя" : "Weekly" }
    var noData: String         { ru ? "нет данных" : "no data" }
    var noFile: String         { ru ? "Пока нет данных. Отправьте любое сообщение в Claude Code."
                                    : "No data yet. Send any message in Claude Code." }
    var badFile: String        { ru ? "Не удалось прочитать ~/.claude/limits.json"
                                    : "Couldn't read ~/.claude/limits.json" }
    var launchAtLogin: String  { ru ? "Запускать при входе в систему" : "Launch at login" }
    var language: String       { ru ? "Язык" : "Language" }
    var systemLanguage: String { ru ? "Системный" : "System" }
    var quit: String           { ru ? "Выйти" : "Quit" }

    func left(_ p: Int) -> String { ru ? "осталось \(p)%" : "\(p)% left" }

    func usedReset(_ p: Int, _ reset: String) -> String {
        ru ? "Использовано \(p)% · сброс \(reset)" : "Used \(p)% · resets \(reset)"
    }

    func updated(_ date: Date) -> String {
        let rel = date.formatted(.relative(presentation: .named).locale(locale))
        return ru ? "Обновлено \(rel)" : "Updated \(rel)"
    }

    // График
    var tab5h: String   { ru ? "5 часов" : "5 hours" }
    var tabWeek: String { ru ? "Неделя" : "Week" }
    var chartNoData: String { ru ? "Окно сбросилось. График появится после следующего ответа Claude Code."
                                 : "The window has reset. The chart will appear after Claude Code's next reply." }
    func forecastRunOut(_ d: Date, week: Bool) -> String {
        let f: Date.FormatStyle = week ? .dateTime.weekday(.abbreviated).hour().minute() : .dateTime.hour().minute()
        let s = d.formatted(f.locale(locale))
        return ru ? "Прогноз: при таком темпе лимит закончится \(week ? "" : "в ")\(s)"
                  : "Forecast: at this pace you'll hit the limit at \(s)"
    }
    var forecastOK: String { ru ? "Прогноз: при таком темпе лимита хватит до сброса"
                                : "Forecast: at this pace the limit will last until reset" }
    func hoverLabel(_ used: Double, _ d: Date, week: Bool) -> String {
        let f: Date.FormatStyle = week ? .dateTime.weekday(.abbreviated).hour().minute() : .dateTime.hour().minute()
        return "\(Int(used.rounded()))% · \(d.formatted(f.locale(locale)))"
    }

    // Уведомления
    var notifications: String  { ru ? "Уведомления" : "Notifications" }
    var notifOnTitle: String   { ru ? "Уведомления включены" : "Notifications are on" }
    var notifOnBody: String    { ru ? "Сообщу, когда лимит будет заканчиваться и когда он сбросится."
                                    : "I'll let you know when a limit is running low and when it resets." }
    func lowTitle(_ left: Int) -> String { ru ? "Claude: осталось \(left)%" : "Claude: \(left)% left" }
    func lowBody(five: Bool, used: Int, countdown: String) -> String {
        if ru {
            return five ? "5-часовое окно израсходовано на \(used)%. Сброс \(countdown)."
                        : "Недельный лимит израсходован на \(used)%. Сброс \(countdown)."
        }
        return five ? "5-hour window is \(used)% used. Resets \(countdown)."
                    : "Weekly limit is \(used)% used. Resets \(countdown)."
    }
    var resetTitle: String { ru ? "Лимит Claude сброшен" : "Claude limit has reset" }
    func resetBody(five: Bool) -> String {
        if ru { return five ? "5-часовое окно обновилось — можно работать." : "Недельный лимит обновился — можно работать." }
        return five ? "The 5-hour window has reset — you're good to go." : "The weekly limit has reset — you're good to go."
    }

    func countdown(to date: Date, now: Date = Date()) -> String {
        let s = Int(date.timeIntervalSince(now))
        if s <= 0 { return ru ? "сброшен" : "done" }
        let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
        if d > 0 { return ru ? "через \(d) д \(h) ч" : "in \(d)d \(h)h" }
        if h > 0 { return ru ? "через \(h) ч \(m) мин" : "in \(h)h \(m)m" }
        return ru ? "через \(m) мин" : "in \(m)m"
    }
}

// MARK: - Notification rules (чистая логика, без отправки)

enum NotifyEvent: Equatable {
    case low(threshold: Int, used: Int)   // израсходовано >= threshold%
    case reset                            // окно сбросилось после сильного расхода
}

enum NotifyRules {
    static let thresholds: [Double] = [95, 80]      // от большего к меньшему
    static let sameWindowTolerance: Double = 1800   // resets_at может немного «плавать»
    static let resetGrace: Double = 900             // сообщать о сбросе не позже 15 мин после него

    /// Решает, нужно ли уведомление для окна `kind`. `notified` — что уже отправляли (ключ -> resets_at окна).
    static func decide(kind: String, window w: Window, notified: inout [String: Double], now: Double) -> NotifyEvent? {
        func already(_ key: String) -> Bool {
            if let r = notified[key] { return abs(r - w.resets_at) < sameWindowTolerance }
            return false
        }
        if now < w.resets_at {
            // Наибольший пройденный порог, о котором ещё не сообщали
            guard let th = thresholds.first(where: { w.used_percentage >= $0 }),
                  !already("\(kind):\(Int(th))") else { return nil }
            for t in thresholds where t <= th { notified["\(kind):\(Int(t))"] = w.resets_at }
            return .low(threshold: Int(th), used: Int(w.used_percentage.rounded()))
        }
        if now - w.resets_at < resetGrace, w.used_percentage >= 80, !already("\(kind):reset") {
            notified["\(kind):reset"] = w.resets_at
            return .reset
        }
        return nil
    }
}

