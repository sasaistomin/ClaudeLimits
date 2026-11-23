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

@MainActor
final class LimitsStore: ObservableObject {
    @Published var fiveHour: WindowState?
    @Published var sevenDay: WindowState?
    @Published var updatedAt: Date?
    @Published var error: String?
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled

    private var timer: Timer?

    init() {
        reload()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
    }

    func reload() {
        guard let data = try? Data(contentsOf: limitsURL) else {
            error = "Пока нет данных. Отправьте любое сообщение в Claude Code."
            return
        }
        do {
            let f = try JSONDecoder().decode(LimitsFile.self, from: data)
            error = nil
            updatedAt = Date(timeIntervalSince1970: f.updated_at)
            fiveHour = Self.state(f.rate_limits.five_hour)
            sevenDay = Self.state(f.rate_limits.seven_day)
        } catch {
            self.error = "Не удалось прочитать ~/.claude/limits.json"
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

func countdown(to date: Date) -> String {
    let s = Int(date.timeIntervalSinceNow)
    if s <= 0 { return "сброшен" }
    let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
    if d > 0 { return "через \(d) д \(h) ч" }
    if h > 0 { return "через \(h) ч \(m) мин" }
    return "через \(m) мин"
}

// MARK: - Views

struct WindowRow: View {
    let title: String
    let state: WindowState?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                if let s = state {
                    Text("осталось \(Int(s.remaining.rounded()))%")
                        .monospacedDigit()
                        .foregroundStyle(color(for: s.used))
                } else {
                    Text("нет данных").foregroundStyle(.secondary)
                }
            }
            ProgressView(value: min(1, (state?.used ?? 0) / 100))
                .tint(color(for: state?.used ?? 0))
            if let s = state {
                Text("Использовано \(Int(s.used.rounded()))% · сброс \(countdown(to: s.resetsAt))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct PopoverView: View {
    @ObservedObject var store: LimitsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Лимиты Claude").font(.title3.bold())

            if let e = store.error {
                Text(e).font(.callout).foregroundStyle(.secondary)
            } else {
                WindowRow(title: "5-часовое окно", state: store.fiveHour)
                WindowRow(title: "Неделя", state: store.sevenDay)
            }

            Divider()

            Toggle("Запускать при входе в систему", isOn: Binding(
                get: { store.launchAtLogin },
                set: { store.setLaunchAtLogin($0) }
            ))
            .toggleStyle(.checkbox)

            HStack {
                if let u = store.updatedAt {
                    Text("Обновлено \(u.formatted(.relative(presentation: .named)))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Выйти") { NSApplication.shared.terminate(nil) }
                    .controlSize(.small)
            }
        }
        .padding(16)
        .frame(width: 300)
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
