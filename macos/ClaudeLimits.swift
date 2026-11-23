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

    func countdown(to date: Date) -> String {
        let s = Int(date.timeIntervalSinceNow)
        if s <= 0 { return ru ? "сброшен" : "done" }
        let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
        if d > 0 { return ru ? "через \(d) д \(h) ч" : "in \(d)d \(h)h" }
        if h > 0 { return ru ? "через \(h) ч \(m) мин" : "in \(h)h \(m)m" }
        return ru ? "через \(m) мин" : "in \(m)m"
    }
}

// MARK: - Store

enum LoadError { case noFile, badFile }

@MainActor
final class LimitsStore: ObservableObject {
    @Published var fiveHour: WindowState?
    @Published var sevenDay: WindowState?
    @Published var updatedAt: Date?
    @Published var error: LoadError?
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published var language: AppLanguage {
        didSet { UserDefaults.standard.set(language.rawValue, forKey: "language") }
    }

    var l10n: L10n { L10n(ru: language.resolvedIsRussian) }

    private var timer: Timer?

    init() {
        language = AppLanguage(rawValue: UserDefaults.standard.string(forKey: "language") ?? "") ?? .system
        reload()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
    }

    func reload() {
        guard let data = try? Data(contentsOf: limitsURL) else { error = .noFile; return }
        do {
            let f = try JSONDecoder().decode(LimitsFile.self, from: data)
            error = nil
            updatedAt = Date(timeIntervalSince1970: f.updated_at)
            fiveHour = Self.state(f.rate_limits.five_hour)
            sevenDay = Self.state(f.rate_limits.seven_day)
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
            }

            Divider()

            Toggle(l.launchAtLogin, isOn: Binding(
                get: { store.launchAtLogin },
                set: { store.setLaunchAtLogin($0) }
            ))
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
        .frame(width: 300)
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
