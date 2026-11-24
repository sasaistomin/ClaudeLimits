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
            eq(ru.lowTitle(20), "Claude: осталось 20%"); eq(en.lowTitle(20), "Claude: 20% left")
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
