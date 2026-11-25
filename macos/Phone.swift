// ClaudeLimits — виджет на телефоне (Scriptable): лимиты выгружаются в секретный GitHub Gist,
// виджет на iPhone читает его по ID. Настройки — ~/.claude/limits-phone.json {"token", "gist_id"} (права 600).
//   ClaudeLimits --phone-setup    — спросить токен GitHub (право gist), создать gist, сохранить настройки
//   ClaudeLimits --phone-disable  — удалить настройки (сам gist остаётся на GitHub)
//   ClaudeLimits --phone-status   — показать, настроено ли
// Приложение в меню-баре само выгружает данные (PhoneSync), не чаще раза в минуту и только когда цифры изменились.

import Foundation

let phoneConfigURL = claudeDir.appendingPathComponent("limits-phone.json")

struct PhoneConfig: Equatable {
    let token: String
    let gistID: String

    static func read(_ url: URL = phoneConfigURL) -> PhoneConfig? {
        guard let data = try? Data(contentsOf: url),
              let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let token = o["token"] as? String, !token.isEmpty,
              let gist = o["gist_id"] as? String, !gist.isEmpty else { return nil }
        return PhoneConfig(token: token, gistID: gist)
    }

    func save(_ url: URL = phoneConfigURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: ["token": token, "gist_id": gistID], options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

enum Phone {
    static let gistFile = "claude-limits.json"
    static let minInterval: Double = 60
    static let retryAfter: Double = 300

    static var apiBase: String {
        (ProcessInfo.processInfo.environment["CLAUDE_LIMITS_GITHUB_API"] ?? "https://api.github.com")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    /// Снимок для виджета: только источники с данными, проценты как есть (виджет сам обнуляет прошедшие окна).
    static func payload(_ metrics: [LimitSource: LimitMetrics], now: Double) -> [String: Any] {
        var sources: [String: Any] = [:]
        for source in LimitSource.allCases {
            guard let m = metrics[source], m.status == .ok, !m.windows.isEmpty else { continue }
            sources[source.rawValue] = [
                "updated": Int(m.updated),
                "windows": m.windows.map { ["id": $0.id, "used": $0.raw, "resets_at": Int($0.resetsAt), "rolling": $0.rolling] as [String: Any] },
            ] as [String: Any]
        }
        return ["v": 1, "sent_at": Int(now), "sources": sources]
    }

    static func key(_ payload: [String: Any]) -> String {
        let data = try? JSONSerialization.data(withJSONObject: payload["sources"] ?? [:], options: [.sortedKeys])
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    static func shouldSend(key: String, lastKey: String?, lastSent: Double, failedAt: Double, now: Double) -> Bool {
        guard key != lastKey, now - lastSent >= minInterval else { return false }
        return failedAt == 0 || now - failedAt >= retryAfter
    }

    static func gistBody(_ payload: [String: Any]) -> [String: Any] {
        let content = (try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return ["files": [gistFile: ["content": content]]]
    }

    static func request(_ method: String, _ path: String, token: String, body: [String: Any]) -> URLRequest {
        var r = URLRequest(url: URL(string: apiBase + path)!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        r.httpMethod = method
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        r.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        r.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        r.setValue("ClaudeLimits", forHTTPHeaderField: "User-Agent")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return r
    }

    static func updateRequest(_ cfg: PhoneConfig, _ payload: [String: Any]) -> URLRequest {
        request("PATCH", "/gists/\(cfg.gistID)", token: cfg.token, body: gistBody(payload))
    }

    static func createRequest(token: String, _ payload: [String: Any]) -> URLRequest {
        var body = gistBody(payload)
        body["description"] = "Claude Limits — widget data"
        body["public"] = false
        return request("POST", "/gists", token: token, body: body)
    }

    /// Синхронный запрос (для командной строки): код ответа и JSON (nil — нет связи).
    static func perform(_ req: URLRequest) -> (status: Int, json: [String: Any]?) {
        let sem = DispatchSemaphore(value: 0)
        var result: (Int, [String: Any]?) = (0, nil)
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            result = ((resp as? HTTPURLResponse)?.statusCode ?? 0,
                      data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })
            sem.signal()
        }.resume()
        sem.wait()
        return result
    }

    static func errorText(_ status: Int) -> String {
        switch status {
        case 0: return "Нет связи с GitHub."
        case 401: return "GitHub не принял токен (401). Проверьте, что он скопирован целиком и не просрочен."
        case 403, 404: return "У токена нет доступа к gist (\(status)). Нужен classic-токен с галочкой «gist»."
        default: return "GitHub ответил \(status)."
        }
    }

    // MARK: командная строка

    static func setup() -> Bool {
        print("Виджет Claude Limits для iPhone (Scriptable)")
        print("Нужен токен GitHub с правом «gist»: https://github.com/settings/tokens/new?scopes=gist&description=Claude%20Limits")
        var token = ProcessInfo.processInfo.environment["CLAUDE_LIMITS_GITHUB_TOKEN"] ?? ""
        if token.isEmpty {
            var buf = [CChar](repeating: 0, count: 1024)
            if let p = readpassphrase("Токен (ввод скрыт): ", &buf, buf.count, 0) { token = String(cString: p) }
        }
        token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { print("Токен не введён."); return false }

        let empty: [String: Any] = ["v": 1, "sent_at": Int(Date().timeIntervalSince1970), "sources": [String: Any]()]
        var gistID: String?
        if let old = PhoneConfig.read(), old.token == token {
            let r = perform(updateRequest(old, empty))
            if r.status == 200 { gistID = old.gistID } else if r.status != 404 { print(errorText(r.status)); return false }
        }
        if gistID == nil {
            let r = perform(createRequest(token: token, empty))
            guard r.status == 201, let id = r.json?["id"] as? String else { print(errorText(r.status)); return false }
            gistID = id
        }
        do { try PhoneConfig(token: token, gistID: gistID!).save() } catch {
            print("Не удалось сохранить \(phoneConfigURL.path): \(error)"); return false
        }
        print("")
        print("Готово. Настройки: \(phoneConfigURL.path)")
        print("ID для виджета:  \(gistID!)")
        print("Вставьте его в поле Parameter виджета Scriptable (или в GIST_ID в начале скрипта).")
        print("Приложение начнёт выгружать цифры в течение минуты после следующего ответа Claude.")
        return true
    }

    static func disable() -> Bool {
        if (try? FileManager.default.removeItem(at: phoneConfigURL)) != nil {
            print("Выгрузка для виджета выключена. Сам gist можно удалить на https://gist.github.com/")
        } else {
            print("Выгрузка для виджета и так не настроена.")
        }
        return true
    }

    static func status() -> Bool {
        if let c = PhoneConfig.read() { print("Настроено, ID для виджета: \(c.gistID)") }
        else { print("Не настроено. Запустите: ClaudeLimits --phone-setup") }
        return true
    }
}

/// Фоновая выгрузка для приложения: offer() на каждый новый снимок, tick() раз в несколько секунд (главный поток).
final class PhoneSync {
    private let url: URL
    private(set) var config: PhoneConfig?
    private var stamp: String?
    private var pending: [LimitSource: LimitMetrics]?
    private var lastKey: String?
    private var lastSent: Double = 0
    private var failedAt: Double = 0
    private(set) var busy = false
    private(set) var lastError: Int?
    var send: (URLRequest, @escaping (Int) -> Void) -> Void = { req, done in
        URLSession.shared.dataTask(with: req) { _, resp, _ in
            done((resp as? HTTPURLResponse)?.statusCode ?? 0)
        }.resume()
    }

    init(url: URL = phoneConfigURL) { self.url = url }

    var enabled: Bool { config != nil }

    func reload() {
        let a = try? FileManager.default.attributesOfItem(atPath: url.path)
        let s = a.map { "\(($0[.size] as? NSNumber)?.int64Value ?? -1)|\(($0[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)" }
        guard s != stamp else { return }
        stamp = s
        config = s == nil ? nil : PhoneConfig.read(url)
        lastKey = nil
        failedAt = 0
        lastError = nil
    }

    func offer(_ metrics: [LimitSource: LimitMetrics]) { pending = metrics }

    @discardableResult
    func tick(now: Double = Date().timeIntervalSince1970) -> Bool {
        reload()
        guard let cfg = config, let pending, !busy else { return false }
        let p = Phone.payload(pending, now: now)
        let key = Phone.key(p)
        guard !((p["sources"] as? [String: Any])?.isEmpty ?? true),
              Phone.shouldSend(key: key, lastKey: lastKey, lastSent: lastSent, failedAt: failedAt, now: now) else { return false }
        busy = true
        send(Phone.updateRequest(cfg, p)) { [weak self] status in
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = false
                let t = max(now, Date().timeIntervalSince1970)
                if status == 200 {
                    self.lastKey = key; self.lastSent = t; self.failedAt = 0; self.lastError = nil
                } else {
                    self.failedAt = t; self.lastError = status
                }
            }
        }
        return true
    }
}
