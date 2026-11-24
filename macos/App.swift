// ClaudeLimits for macOS — показывает остаток лимитов Claude в меню-баре.
//
// Один бинарник, несколько режимов:
//   ClaudeLimits                         — приложение в меню-баре
//   ClaudeLimits --statusline            — statusline-команда для Claude Code (stdin -> ~/.claude/limits.json)
//   ClaudeLimits --install               — прописать statusline в ~/.claude/settings.json
//   ClaudeLimits --uninstall             — убрать statusline из ~/.claude/settings.json
//   ClaudeLimits --snapshot out.png [week] [dark] — сохранить окно в PNG (отладка)
//
// Логика — в Core.swift, здесь только интерфейс.

import SwiftUI
import Foundation
import ServiceManagement
import UserNotifications
import Charts

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
        let five = kind == "five_hour"
        switch NotifyRules.decide(kind: kind, window: w, notified: &notified, now: Date().timeIntervalSince1970) {
        case .low(_, let used)?:
            send(l.lowTitle(max(0, 100 - used)),
                 l.lowBody(five: five, used: used,
                           countdown: l.countdown(to: Date(timeIntervalSince1970: w.resets_at))))
        case .reset?:
            send(l.resetTitle, l.resetBody(five: five))
        case nil:
            return
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
