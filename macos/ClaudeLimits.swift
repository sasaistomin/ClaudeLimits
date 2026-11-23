// ClaudeLimits for macOS — показывает остаток лимитов Claude в меню-баре.
//
// Один бинарник, три режима:
//   ClaudeLimits                 — приложение в меню-баре
//   ClaudeLimits --statusline    — statusline-команда для Claude Code (stdin -> ~/.claude/limits.json)
//   ClaudeLimits --install       — прописать statusline в ~/.claude/settings.json
//   ClaudeLimits --uninstall     — убрать statusline из ~/.claude/settings.json

import SwiftUI
import Foundation
import ServiceManagement
import UserNotifications
import Charts

let home = ProcessInfo.processInfo.environment["HOME"].map { URL(fileURLWithPath: $0) }
    ?? FileManager.default.homeDirectoryForCurrentUser
let claudeDir = home.appendingPathComponent(".claude")
let limitsURL = claudeDir.appendingPathComponent("limits.json")
let settingsURL = claudeDir.appendingPathComponent("settings.json")

// MARK: - Entry point

@main
enum Main {
    static func main() {
        let args = CommandLine.arguments.dropFirst()
        if args.contains("--statusline") { StatusLine.run(); return }
        if args.contains("--install") { exit(Installer.install() ? 0 : 1) }
        if args.contains("--uninstall") { exit(Installer.uninstall() ? 0 : 1) }
        if let i = args.firstIndex(of: "--snapshot"), args.index(after: i) < args.endIndex {
            // Отладка/скриншоты: --snapshot out.png [week] [dark]
            let rest = Array(args[args.index(after: i)...])
            MainActor.assumeIsolated { Snapshot.render(to: rest[0], week: rest.contains("week"), dark: rest.contains("dark")) }
            return
        }
        ClaudeLimitsApp.main()
    }
}

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
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path
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

    static func install() -> Bool {
        guard var s = readSettings() else {
            print("Не удалось разобрать \(settingsURL.path) — исправьте JSON и повторите."); return false
        }
        if let old = s["statusLine"] as? [String: Any], let cmd = old["command"] as? String,
           !cmd.contains("--statusline") {
            print("Внимание: ваш прежний statusLine (\(cmd)) будет заменён. Копия: settings.json.bak")
        }
        backup()
        s["statusLine"] = ["type": "command", "command": command]
        guard writeSettings(s) else { return false }
        print("statusLine прописан в \(settingsURL.path)")
        return true
    }

    static func uninstall() -> Bool {
        guard var s = readSettings() else { return false }
        if let old = s["statusLine"] as? [String: Any], let cmd = old["command"] as? String,
           cmd.contains("ClaudeLimits") {
            backup()
            s.removeValue(forKey: "statusLine")
            guard writeSettings(s) else { return false }
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

struct ChartPoint: Identifiable {
    let id = UUID()
    let date: Date
    let used: Double
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

    func countdown(to date: Date) -> String {
        let s = Int(date.timeIntervalSinceNow)
        if s <= 0 { return ru ? "сброшен" : "done" }
        let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
        if d > 0 { return ru ? "через \(d) д \(h) ч" : "in \(d)d \(h)h" }
        if h > 0 { return ru ? "через \(h) ч \(m) мин" : "in \(h)h \(m)m" }
        return ru ? "через \(m) мин" : "in \(m)m"
    }
}

// MARK: - Notifications

final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    // Показывать баннер, даже когда приложение «активно»
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler handler: @escaping (UNNotificationPresentationOptions) -> Void) {
        handler([.banner, .sound])
    }
}

let notificationDelegate = NotificationDelegate()

enum Notifier {
    static let thresholds: [Double] = [95, 80]      // от большего к меньшему
    static let sameWindowTolerance: Double = 1800   // resets_at может немного «плавать»
    static let resetGrace: Double = 900             // сообщать о сбросе не позже 15 мин после него
    static let defaultsKey = "notified"

    static func send(_ title: String, _ body: String) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }

    static func requestAuthorization(then: (() -> Void)? = nil) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            if granted { then?() }
        }
    }

    /// Проверяет одно окно лимита и при необходимости шлёт уведомление (один раз на окно).
    static func check(kind: String, window w: Window, l: L10n) {
        var notified = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: Double] ?? [:]
        func already(_ key: String) -> Bool {
            if let r = notified[key] { return abs(r - w.resets_at) < sameWindowTolerance }
            return false
        }
        let now = Date().timeIntervalSince1970
        let five = kind == "five_hour"

        if now < w.resets_at {
            // Наибольший пройденный порог, о котором ещё не сообщали
            if let th = thresholds.first(where: { w.used_percentage >= $0 }), !already("\(kind):\(Int(th))") {
                for t in thresholds where t <= th { notified["\(kind):\(Int(t))"] = w.resets_at }
                let used = Int(w.used_percentage.rounded())
                send(l.lowTitle(max(0, 100 - used)),
                     l.lowBody(five: five, used: used,
                               countdown: l.countdown(to: Date(timeIntervalSince1970: w.resets_at))))
            }
        } else if now - w.resets_at < resetGrace, w.used_percentage >= 80, !already("\(kind):reset") {
            notified["\(kind):reset"] = w.resets_at
            send(l.resetTitle, l.resetBody(five: five))
        }
        UserDefaults.standard.set(notified, forKey: defaultsKey)
    }
}

// MARK: - Store

enum LoadError { case noFile, badFile }

@MainActor
final class LimitsStore: ObservableObject {
    @Published var fiveHour: WindowState?
    @Published var sevenDay: WindowState?
    @Published var updatedAt: Date?
    @Published var history: [Sample] = []
    @Published var chartKind: WindowKind = .fiveHour
    let hover = HoverModel()
    private var historyModDate: Date?
    @Published var error: LoadError?
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published var language: AppLanguage {
        didSet { UserDefaults.standard.set(language.rawValue, forKey: "language") }
    }

    @Published var notificationsOn: Bool {
        didSet {
            UserDefaults.standard.set(notificationsOn, forKey: "notifications")
            if notificationsOn {
                let l = l10n
                Notifier.requestAuthorization { Notifier.send(l.notifOnTitle, l.notifOnBody) }
            }
        }
    }

    var l10n: L10n { L10n(ru: language.resolvedIsRussian) }

    private var timer: Timer?

    init() {
        language = AppLanguage(rawValue: UserDefaults.standard.string(forKey: "language") ?? "") ?? .system
        notificationsOn = UserDefaults.standard.object(forKey: "notifications") as? Bool ?? true
        UNUserNotificationCenter.current().delegate = notificationDelegate
        if notificationsOn { Notifier.requestAuthorization() }
        reload()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
    }

    func reload() {
        // История перечитывается только когда файл изменился
        let mod = (try? FileManager.default.attributesOfItem(atPath: historyURL.path)[.modificationDate]) as? Date
        if mod != historyModDate { historyModDate = mod; history = History.load() }

        guard let data = try? Data(contentsOf: limitsURL) else { error = .noFile; return }
        do {
            let f = try JSONDecoder().decode(LimitsFile.self, from: data)
            error = nil
            updatedAt = Date(timeIntervalSince1970: f.updated_at)
            fiveHour = Self.state(f.rate_limits.five_hour)
            sevenDay = Self.state(f.rate_limits.seven_day)
            if notificationsOn {
                if let w = f.rate_limits.five_hour { Notifier.check(kind: "five_hour", window: w, l: l10n) }
                if let w = f.rate_limits.seven_day { Notifier.check(kind: "seven_day", window: w, l: l10n) }
            }
        } catch {
            self.error = .badFile
        }
    }

    /// Если окно уже сбросилось — считаем, что использовано 0%.
    private static func state(_ w: Window?) -> WindowState? {
        guard let w else { return nil }
        let reset = Date(timeIntervalSince1970: w.resets_at)
        return WindowState(used: reset < Date() ? 0 : w.used_percentage, resetsAt: reset)
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("ClaudeLimits: launch at login error: \(error)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    var menuTitle: String {
        guard let f = fiveHour else { return "—" }
        return "\(Int(f.remaining.rounded()))%"
    }

    var worstUsed: Double { max(fiveHour?.used ?? 0, sevenDay?.used ?? 0) }
}

// MARK: - Helpers

func color(for used: Double) -> Color {
    switch used {
    case ..<70: return .green
    case ..<90: return .yellow
    default: return .red
    }
}

// MARK: - Views

struct WindowRow: View {
    let title: String
    let state: WindowState?
    let l: L10n

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                if let s = state {
                    Text(l.left(Int(s.remaining.rounded())))
                        .monospacedDigit()
                        .foregroundStyle(color(for: s.used))
                } else {
                    Text(l.noData).foregroundStyle(.secondary)
                }
            }
            ProgressView(value: min(1, (state?.used ?? 0) / 100))
                .tint(color(for: state?.used ?? 0))
            if let s = state {
                Text(l.usedReset(Int(s.used.rounded()), l.countdown(to: s.resetsAt)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Состояние наведения на график (вместо @State — работает и без плагина макросов SwiftUI).
final class HoverModel: ObservableObject {
    @Published var point: ChartPoint?
}

struct UsageChart: View {
    let kind: WindowKind
    let state: WindowState?
    let history: [Sample]
    let l: L10n
    @ObservedObject var hoverModel: HoverModel

    var body: some View {
        if let s = state, s.resetsAt > Date() {
            let now = Date()
            let week = kind == .week
            let start = s.resetsAt.addingTimeInterval(-kind.duration)
            let pts = chartPoints(kind: kind, state: s, history: history, now: now)
            let runOut = forecastRunOut(kind: kind, state: s, now: now)
            let elapsed = now.timeIntervalSince(start)
            let rate = elapsed > 300 ? s.used / elapsed : 0
            let projEnd = runOut ?? s.resetsAt
            let projVal = runOut != nil ? 100 : min(100, s.used + rate * s.resetsAt.timeIntervalSince(now))

            VStack(alignment: .leading, spacing: 6) {
                Chart {
                    ForEach(pts) { p in
                        AreaMark(x: .value("t", p.date), y: .value("%", p.used))
                            .interpolationMethod(.stepEnd)
                            .foregroundStyle(Color.accentColor.opacity(0.15))
                        LineMark(x: .value("t", p.date), y: .value("%", p.used), series: .value("s", "used"))
                            .interpolationMethod(.stepEnd)
                            .foregroundStyle(Color.accentColor)
                            .lineStyle(StrokeStyle(lineWidth: 2))
                    }
                    if rate > 0 {
                        // Прогноз — пунктир от «сейчас»
                        LineMark(x: .value("t", now), y: .value("%", s.used), series: .value("s", "forecast"))
                            .foregroundStyle(Color.secondary)
                            .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                        LineMark(x: .value("t", projEnd), y: .value("%", projVal), series: .value("s", "forecast"))
                            .foregroundStyle(Color.secondary)
                            .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    }
                    RuleMark(y: .value("limit", 100))
                        .foregroundStyle(Color.red.opacity(0.35))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 2]))
                    if let h = hoverModel.point {
                        RuleMark(x: .value("t", h.date))
                            .foregroundStyle(Color.secondary.opacity(0.5))
                        PointMark(x: .value("t", h.date), y: .value("%", h.used))
                            .symbolSize(50)
                            .foregroundStyle(Color.accentColor)
                            .annotation(position: .top, alignment: .center, spacing: 4) {
                                Text(l.hoverLabel(h.used, h.date, week: week))
                                    .font(.caption2.monospacedDigit())
                                    .padding(.horizontal, 5).padding(.vertical, 2)
                                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
                            }
                    }
                }
                .chartXScale(domain: start...s.resetsAt)
                .chartYScale(domain: 0...100)
                .chartYAxis {
                    AxisMarks(position: .leading, values: [0, 50, 100]) { v in
                        AxisGridLine().foregroundStyle(Color.secondary.opacity(0.2))
                        AxisValueLabel { Text("\(v.as(Int.self) ?? 0)%").font(.caption2) }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: week ? .day : .hour)) { _ in
                        AxisGridLine().foregroundStyle(Color.secondary.opacity(0.15))
                        AxisValueLabel(format: week ? .dateTime.weekday(.abbreviated) : .dateTime.hour())
                            .font(.caption2)
                    }
                }
                .chartOverlay { proxy in
                    GeometryReader { geo in
                        Rectangle().fill(.clear).contentShape(Rectangle())
                            .onContinuousHover { phase in
                                switch phase {
                                case .active(let loc):
                                    let x = loc.x - geo[proxy.plotAreaFrame].origin.x
                                    if let d: Date = proxy.value(atX: x), d >= start, d <= now {
                                        // ступенчатый график: последнее значение не позже d
                                        let v = pts.last(where: { $0.date <= d })?.used ?? 0
                                        hoverModel.point = ChartPoint(date: d, used: v)
                                    } else {
                                        hoverModel.point = nil
                                    }
                                case .ended:
                                    hoverModel.point = nil
                                }
                            }
                    }
                }
                .frame(height: 130)

                if rate > 0 {
                    Text(runOut.map { l.forecastRunOut($0, week: week) } ?? l.forecastOK)
                        .font(.caption)
                        .foregroundStyle(runOut == nil ? Color.secondary : color(for: 95))
                }
            }
        } else {
            Text(l.chartNoData).font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 60, alignment: .center)
        }
    }
}

struct PopoverView: View {
    @ObservedObject var store: LimitsStore

    var body: some View {
        let l = store.l10n
        VStack(alignment: .leading, spacing: 14) {
            Text(l.title).font(.title3.bold())

            switch store.error {
            case .noFile?: Text(l.noFile).font(.callout).foregroundStyle(.secondary)
            case .badFile?: Text(l.badFile).font(.callout).foregroundStyle(.secondary)
            case nil:
                WindowRow(title: l.fiveHour, state: store.fiveHour, l: l)
                WindowRow(title: l.week, state: store.sevenDay, l: l)

                Picker("", selection: $store.chartKind) {
                    Text(l.tab5h).tag(WindowKind.fiveHour)
                    Text(l.tabWeek).tag(WindowKind.week)
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                UsageChart(kind: store.chartKind,
                           state: store.chartKind == .fiveHour ? store.fiveHour : store.sevenDay,
                           history: store.history, l: l, hoverModel: store.hover)
            }

            Divider()

            Toggle(l.launchAtLogin, isOn: Binding(
                get: { store.launchAtLogin },
                set: { store.setLaunchAtLogin($0) }
            ))
            .toggleStyle(.checkbox)

            Toggle(l.notifications, isOn: $store.notificationsOn)
                .toggleStyle(.checkbox)

            Picker(l.language, selection: $store.language) {
                ForEach(AppLanguage.allCases) { Text($0.label(l)).tag($0) }
            }
            .pickerStyle(.menu)
            .fixedSize()

            HStack {
                if let u = store.updatedAt {
                    Text(l.updated(u)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(l.quit) { NSApplication.shared.terminate(nil) }
                    .controlSize(.small)
            }
        }
        .padding(16)
        .frame(width: 340)
        .environment(\.locale, l.locale)
    }
}

struct ClaudeLimitsApp: App {
    @StateObject private var store = LimitsStore()

    var body: some Scene {
        MenuBarExtra {
            PopoverView(store: store)
        } label: {
            HStack(spacing: 3) {
                Image(systemName: store.worstUsed >= 90 ? "exclamationmark.circle.fill" : "gauge.with.dots.needle.33percent")
                Text(store.menuTitle).monospacedDigit()
            }
        }
        .menuBarExtraStyle(.window)
    }
}


// MARK: - Snapshot (PNG окна для README / отладки)

@MainActor
enum Snapshot {
    static func render(to path: String, week: Bool, dark: Bool) {
        let store = LimitsStore()
        store.chartKind = week ? .week : .fiveHour
        let view = PopoverView(store: store)
            .background(dark ? Color(white: 0.15) : Color(white: 0.97))
            .environment(\.colorScheme, dark ? .dark : .light)
        let r = ImageRenderer(content: view)
        r.scale = 2
        guard let img = r.nsImage, let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { print("render failed"); return }
        try? png.write(to: URL(fileURLWithPath: path))
        print("saved \(path)")
    }
}
