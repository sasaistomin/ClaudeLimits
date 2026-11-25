// ClaudeLimits for macOS — показывает остаток лимитов Claude в меню-баре.
//
// Один бинарник, несколько режимов:
//   ClaudeLimits                         — приложение в меню-баре
//   ClaudeLimits --statusline            — statusline-команда для Claude Code (stdin -> ~/.claude/limits.json)
//   ClaudeLimits --install               — прописать statusline в ~/.claude/settings.json
//   ClaudeLimits --uninstall             — убрать statusline из ~/.claude/settings.json
//   ClaudeLimits --check-update          — сравнить версию с VERSION на GitHub (код выхода 10 — есть обновление)
//   ClaudeLimits --snapshot out.png [week] [dark] [desktop] — сохранить окно в PNG (отладка)
//
// Логика — в Core.swift, источники — в Parsers.swift, фоновый опрос — в Monitoring.swift; здесь только интерфейс.
// Вкладки «Claude Code» / «Claude Desktop»; выбранная вкладка и папка Desktop хранятся в UserDefaults.

import SwiftUI
import Foundation
import ServiceManagement
import UserNotifications
import Charts
import AppKit

// MARK: - Entry point

@main
enum Main {
    static func main() {
        let args = CommandLine.arguments.dropFirst()
        if args.contains("--statusline") { StatusLine.run(); return }
        if args.contains("--install") { exit(Installer.install() ? 0 : 1) }
        if args.contains("--uninstall") { exit(Installer.uninstall() ? 0 : 1) }
        if args.contains("--check-update") {
            guard let data = try? Data(contentsOf: Updater.versionURL),
                  let remote = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) else {
                print("installed \(Updater.installedVersion), remote unavailable"); exit(1)
            }
            let newer = Updater.isNewer(remote, than: Updater.installedVersion)
            print("installed \(Updater.installedVersion), remote \(remote), update: \(newer ? "yes" : "no")")
            exit(newer ? 10 : 0)
        }
        if let i = args.firstIndex(of: "--snapshot"), args.index(after: i) < args.endIndex {
            // Отладка/скриншоты: --snapshot out.png [week] [dark]
            let rest = Array(args[args.index(after: i)...])
            MainActor.assumeIsolated {
                Snapshot.render(to: rest[0], week: rest.contains("week"), dark: rest.contains("dark"), desktop: rest.contains("desktop"))
            }
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

    /// Проверяет окна источника и при необходимости шлёт уведомление (один раз на окно и источник).
    static func check(_ m: LimitMetrics, l: L10n) {
        guard m.status == .ok else { return }
        var notified = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: Double] ?? [:]
        var changed = false
        for w in m.windows {
            let raw = Window(used_percentage: w.raw, resets_at: w.resetsAt)
            guard let ev = NotifyRules.decide(kind: notifyKey(m.source, w), window: raw, notified: &notified,
                                              now: Date().timeIntervalSince1970, thresholds: notifyThresholds(w)) else { continue }
            let text = notificationText(ev, source: m.source, window: w, l: l)
            send(text.title, text.body)
            changed = true
        }
        if changed { UserDefaults.standard.set(notified, forKey: defaultsKey) }
    }
}

// MARK: - Store

@MainActor
final class LimitsStore: ObservableObject {
    @Published var metrics: [LimitSource: LimitMetrics] = [:]
    @Published var history: [Sample] = []
    @Published var desktopHistory: [Sample] = []
    @Published var chartKind: WindowKind = .fiveHour
    let hover = HoverModel()
    let updates = UpdateModel()
    let monitor = LimitMonitoringService()
    private var historyModDates: [URL: Date] = [:]
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published var language: AppLanguage {
        didSet { UserDefaults.standard.set(language.rawValue, forKey: "language") }
    }
    @Published var activeSource: LimitSource {
        didSet { UserDefaults.standard.set(LimitSource.allCases.firstIndex(of: activeSource) ?? 0, forKey: "activeTab") }
    }
    @Published var desktopPath: String {
        didSet {
            UserDefaults.standard.set(desktopPath, forKey: "desktopPath")
            monitor.watch(.desktop, path: desktopPath)
        }
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
        let d = UserDefaults.standard
        language = AppLanguage(rawValue: d.string(forKey: "language") ?? "") ?? .system
        notificationsOn = d.object(forKey: "notifications") as? Bool ?? true
        let tab = d.integer(forKey: "activeTab")
        activeSource = LimitSource.allCases.indices.contains(tab) ? LimitSource.allCases[tab] : .code
        desktopPath = d.string(forKey: "desktopPath") ?? ""
        UNUserNotificationCenter.current().delegate = notificationDelegate
        if notificationsOn { Notifier.requestAuthorization() }
        for source in LimitSource.allCases {
            monitor.subscribe(source) { [weak self] m in
                guard let self else { return }
                self.metrics[m.source] = m
                if m.source == .desktop {
                    History.append(m, to: desktopHistoryURL)
                    self.reloadHistory()
                }
                if self.notificationsOn { Notifier.check(m, l: self.l10n) }
            }
        }
        monitor.watch(.code)
        monitor.watch(.desktop, path: desktopPath)
        reloadHistory()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    /// Раз в 5 секунд: история для графика, обратный отсчёт и уведомления о сбросе окна.
    func refresh() {
        reloadHistory()
        objectWillChange.send()
        if notificationsOn { metrics.values.forEach { Notifier.check($0, l: l10n) } }
    }

    private func reloadHistory() {
        for url in [historyURL, desktopHistoryURL] {
            let mod = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
            guard mod != historyModDates[url] else { continue }
            historyModDates[url] = mod
            if url == historyURL { history = History.load(url) } else { desktopHistory = History.load(url) }
        }
    }

    var code: LimitMetrics? { metrics[.code] }
    var active: LimitMetrics? { metrics[activeSource] }
    var fiveHour: WindowState? { code?.window("five_hour")?.state }
    var sevenDay: WindowState? { code?.window("seven_day")?.state }

    func chooseDesktopFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.message = l10n.folderPanelTitle
        panel.directoryURL = desktopPath.isEmpty ? home.appendingPathComponent("Library/Application Support")
                                                 : URL(fileURLWithPath: desktopPath)
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url { desktopPath = url.path }
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
        guard let w = active?.windows.first, active?.status == .ok else { return "—" }
        return "\(Int(w.left.rounded()))%"
    }

    var worstUsed: Double { active?.windows.map(\.used).max() ?? 0 }
}

// MARK: - Updates

enum UpdateState: Equatable {
    case idle, checking, upToDate, available(String), installing, failed
}

@MainActor
final class UpdateModel: ObservableObject {
    @Published var state: UpdateState = .idle

    func check() {
        state = .checking
        var req = URLRequest(url: Updater.versionURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        req.setValue("ClaudeLimits", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            let ok = (resp as? HTTPURLResponse)?.statusCode == 200
            let remote = ok ? data.flatMap { String(data: $0, encoding: .utf8) } : nil
            Task { @MainActor in
                guard let remote else { self.state = .failed; return }
                let v = remote.trimmingCharacters(in: .whitespacesAndNewlines)
                self.state = Updater.isNewer(v, than: Updater.installedVersion) ? .available(v) : .upToDate
            }
        }.resume()
    }

    /// Скачивает install.sh и запускает его отдельным процессом: он соберёт новую версию,
    /// остановит это приложение и откроет обновлённое.
    func install() {
        state = .installing
        URLSession.shared.downloadTask(with: Updater.installerURL) { tmp, resp, _ in
            guard (resp as? HTTPURLResponse)?.statusCode == 200, let tmp else {
                Task { @MainActor in self.state = .failed }
                return
            }
            let script = FileManager.default.temporaryDirectory.appendingPathComponent("claude-limits-update.sh")
            try? FileManager.default.removeItem(at: script)
            do { try FileManager.default.moveItem(at: tmp, to: script) } catch {
                Task { @MainActor in self.state = .failed }
                return
            }
            let log = home.appendingPathComponent("Library/Logs/ClaudeLimits-update.log")
            try? FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: log.path, contents: nil)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = [script.path]
            p.currentDirectoryURL = FileManager.default.temporaryDirectory
            if let h = try? FileHandle(forWritingTo: log) { p.standardOutput = h; p.standardError = h }
            do { try p.run() } catch { Task { @MainActor in self.state = .failed } }
        }.resume()
    }
}

struct UpdateButton: View {
    @ObservedObject var model: UpdateModel
    let l: L10n

    var body: some View {
        switch model.state {
        case .idle, .failed, .upToDate:
            HStack(spacing: 6) {
                Button(l.checkUpdates) { model.check() }.controlSize(.small)
                if model.state == .upToDate {
                    Text(l.upToDate(Updater.installedVersion)).font(.caption).foregroundStyle(.secondary)
                } else if model.state == .failed {
                    Text(l.updateFailed).font(.caption).foregroundStyle(.red)
                }
            }
        case .checking:
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text(l.checkingUpdates).font(.caption) }
        case .available(let v):
            Button(l.updateTo(v)) { model.install() }.controlSize(.small).buttonStyle(.borderedProminent)
        case .installing:
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text(l.installingUpdate).font(.caption) }
        }
    }
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
    var rolling = false

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
                Text(rolling && s.resetsAt > Date() ? l.usedResetAt(Int(s.used.rounded()), s.resetsAt)
                                                    : l.usedReset(Int(s.used.rounded()), l.countdown(to: s.resetsAt)))
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

            Picker("", selection: $store.activeSource) {
                ForEach(LimitSource.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch store.activeSource {
            case .code: CodeTab(store: store, l: l)
            case .desktop: DesktopTab(store: store, l: l)
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

            UpdateButton(model: store.updates, l: l)

            HStack {
                if let m = store.active, m.status == .ok {
                    Text(l.updated(Date(timeIntervalSince1970: m.updated))).font(.caption).foregroundStyle(.secondary)
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

struct CodeTab: View {
    @ObservedObject var store: LimitsStore
    let l: L10n

    var body: some View {
        switch store.code?.status {
        case nil: Text(l.loading).font(.callout).foregroundStyle(.secondary)
        case .invalid?: Text(l.badFile).font(.callout).foregroundStyle(.secondary)
        case .noData?, .notFound?: Text(l.noFile).font(.callout).foregroundStyle(.secondary)
        case .ok?:
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
    }
}

struct DesktopTab: View {
    @ObservedObject var store: LimitsStore
    let l: L10n

    var body: some View {
        let m = store.metrics[.desktop]
        VStack(alignment: .leading, spacing: 10) {
            switch m?.status {
            case nil: Text(l.loading).font(.callout).foregroundStyle(.secondary)
            case .notFound?:
                Text(l.desktopNotFound).font(.headline)
                Text(l.desktopNotFoundHint).font(.callout).foregroundStyle(.secondary)
            case .noData?, .invalid?: Text(l.desktopNoData).font(.callout).foregroundStyle(.secondary)
            case .ok?:
                ForEach(m?.windows ?? [], id: \.id) { w in
                    WindowRow(title: w.rolling ? l.rolling : (w.id == "five_hour" ? l.fiveHour : l.week),
                              state: w.state, l: l, rolling: w.rolling)
                }

                Picker("", selection: $store.chartKind) {
                    Text(l.tab5h).tag(WindowKind.fiveHour)
                    Text(l.tabWeek).tag(WindowKind.week)
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                UsageChart(kind: store.chartKind,
                           state: m?.window(store.chartKind == .fiveHour ? "five_hour" : "seven_day")?.state,
                           history: store.desktopHistory, l: l, hoverModel: store.hover)
            }
            HStack(spacing: 6) {
                Text(m?.logPath.isEmpty == false ? m!.logPath : l.desktopNotFound)
                    .font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                if !store.desktopPath.isEmpty {
                    Button(l.autoFolder) { store.desktopPath = "" }.controlSize(.small)
                }
                Button(l.chooseFolder) { store.chooseDesktopFolder() }.controlSize(.small)
            }
        }
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
    static func render(to path: String, week: Bool, dark: Bool, desktop: Bool) {
        let store = LimitsStore()
        store.monitor.waitForAll(timeout: 10)
        store.chartKind = week ? .week : .fiveHour
        let previous = store.activeSource
        store.activeSource = desktop ? .desktop : .code
        defer { store.activeSource = previous }
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
