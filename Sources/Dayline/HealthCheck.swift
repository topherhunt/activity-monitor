import Foundation

enum HealthCheckError: Error, CustomStringConvertible {
    case invalidURL

    var description: String {
        "Enter an https:// URL, or leave this blank to turn health checks off."
    }
}

/// Pings a user-configured monitor while samples are being recorded, so the
/// monitor can raise the alarm when the pings stop. Pings carry no data.
final class HealthCheck {
    typealias Send = (URL, @escaping (_ error: String?) -> Void) -> Void

    struct Outcome {
        var at: Date
        var error: String?
    }

    private struct Settings: Codable {
        var healthCheckURL: String
    }

    static let interval: TimeInterval = 3600
    /// Shorter than `interval` because a wake from sleep often pings before the
    /// network is back.
    static let retryInterval: TimeInterval = 300

    private static let session = URLSession(
        configuration: .ephemeral, delegate: nil, delegateQueue: .main)

    private let settingsFile: URL
    private let send: Send
    private var nextPing = Date.distantPast
    private var inFlight = false

    private(set) var url: URL?
    private(set) var last: Outcome?

    init(settingsFile: URL,
         send: @escaping Send = { HealthCheck.post(to: $0, session: HealthCheck.session, done: $1) }) {
        self.settingsFile = settingsFile
        self.send = send
        guard FileManager.default.fileExists(atPath: settingsFile.path) else { return }
        do {
            let saved = try JSONDecoder().decode(Settings.self, from: Data(contentsOf: settingsFile))
            url = try Self.parse(saved.healthCheckURL)
        } catch {
            NSLog("Health check is off, could not read %@: %@", settingsFile.path, "\(error)")
            last = Outcome(at: Date(), error: "Could not read settings.json: \(error)")
        }
    }

    /// Blank means off. App Transport Security blocks plain http, so it is
    /// refused here rather than failing on every ping.
    static func parse(_ text: String) throws -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        guard let url = URL(string: trimmed), url.scheme == "https", url.host != nil else {
            throw HealthCheckError.invalidURL
        }
        return url
    }

    /// Saves the URL. The next tick pings it, which doubles as a test of a new URL.
    func setURL(_ text: String) throws {
        let parsed = try Self.parse(text)
        let saved = Settings(healthCheckURL: parsed?.absoluteString ?? "")
        try JSONEncoder().encode(saved).write(to: settingsFile, options: .atomic)
        url = parsed
        last = nil
        nextPing = .distantPast
        inFlight = false
    }

    /// Called after each recorded sample. Sampling is what stops when the app
    /// dies or the Mac sleeps, so there is no separate timer to outlive it.
    func tick(now: Date = Date()) {
        guard let url, !inFlight, now >= nextPing else { return }
        inFlight = true
        send(url) { [weak self] error in
            // A slow reply to a URL that has since been replaced says nothing.
            guard let self, self.url == url else { return }
            if let error { NSLog("Health check ping failed: %@", error) }
            self.inFlight = false
            self.last = Outcome(at: now, error: error)
            self.nextPing = now + (error == nil ? Self.interval : Self.retryInterval)
        }
    }

    static func post(to url: URL, session: URLSession, done: @escaping (_ error: String?) -> Void) {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        session.dataTask(with: request) { data, response, error in
            done(failure(data: data, response: response, error: error))
        }.resume()
    }

    /// healthchecks.io answers 200 "OK (not found)" for an unknown check, so a
    /// mistyped URL looks like success unless the body is read.
    private static func failure(data: Data?, response: URLResponse?, error: Error?) -> String? {
        if let error { return error.localizedDescription }
        guard let http = response as? HTTPURLResponse else { return "Not an HTTP response" }
        guard (200..<300).contains(http.statusCode) else { return "HTTP \(http.statusCode)" }
        let body = String(decoding: data ?? Data(), as: UTF8.self)
        if body.localizedCaseInsensitiveContains("not found") {
            return "The monitor does not recognize this URL"
        }
        return nil
    }
}
