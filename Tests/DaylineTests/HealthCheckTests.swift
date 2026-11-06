import Foundation
import Testing
@testable import Dayline

/// Answers every request with a canned response and records what it was sent.
final class StubProtocol: URLProtocol {
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var body = "OK"
    nonisolated(unsafe) static var seen: URLRequest?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        Self.seen = request
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status,
                                       httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

/// Serialized because `post` shares StubProtocol's static state.
@Suite(.serialized) struct HealthCheckTests {
    let file: URL
    let start = Date(timeIntervalSince1970: 1_793_000_000)
    let ping = "https://hc-ping.com/abc"

    /// Each ping in the order sent, with the closure that completes it.
    final class Sent {
        var urls: [URL] = []
        var finishers: [(String?) -> Void] = []
    }
    let sent = Sent()

    init() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        file = dir.appendingPathComponent("settings.json")
    }

    private func make() -> HealthCheck {
        let sent = sent
        return HealthCheck(settingsFile: file) { url, done in
            sent.urls.append(url)
            sent.finishers.append(done)
        }
    }

    private func configured() throws -> HealthCheck {
        let check = make()
        try check.setURL(ping)
        return check
    }

    private func post() async -> String? {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return await withCheckedContinuation { finished in
            HealthCheck.post(to: URL(string: ping)!, session: URLSession(configuration: config)) {
                finished.resume(returning: $0)
            }
        }
    }

    @Test func staysSilentWithoutAURL() {
        make().tick(now: start)
        #expect(sent.urls.isEmpty)
    }

    @Test func pingsOnTheFirstTickThenHourly() throws {
        let check = try configured()
        check.tick(now: start)
        #expect(sent.urls == [URL(string: ping)!])
        sent.finishers[0](nil)

        check.tick(now: start + HealthCheck.interval - 1)
        #expect(sent.urls.count == 1)
        check.tick(now: start + HealthCheck.interval)
        #expect(sent.urls.count == 2)
    }

    @Test func retriesSoonerAfterAFailureAndReportsIt() throws {
        let check = try configured()
        check.tick(now: start)
        sent.finishers[0]("offline")
        #expect(check.last?.error == "offline")

        check.tick(now: start + HealthCheck.retryInterval - 1)
        #expect(sent.urls.count == 1)
        check.tick(now: start + HealthCheck.retryInterval)
        #expect(sent.urls.count == 2)
    }

    @Test func neverOverlapsAPingInFlight() throws {
        let check = try configured()
        check.tick(now: start)
        check.tick(now: start + HealthCheck.interval * 2)
        #expect(sent.urls.count == 1)
    }

    @Test func aSavedURLSurvivesARestart() throws {
        _ = try configured()
        #expect(make().url == URL(string: ping)!)
    }

    @Test func savingANewURLPingsItRightAway() throws {
        let check = try configured()
        check.tick(now: start)
        sent.finishers[0](nil)

        try check.setURL("https://hc-ping.com/new")
        check.tick(now: start + 1)
        #expect(sent.urls.last == URL(string: "https://hc-ping.com/new")!)
    }

    @Test func aLateReplyForAReplacedURLIsIgnored() throws {
        let check = try configured()
        check.tick(now: start)
        try check.setURL("https://hc-ping.com/new")
        sent.finishers[0]("offline")
        #expect(check.last == nil)
    }

    @Test func blankTurnsItOff() throws {
        let check = try configured()
        try check.setURL("  ")
        check.tick(now: start)
        #expect(sent.urls.isEmpty)
        #expect(make().url == nil)
    }

    @Test(arguments: ["http://hc-ping.com/abc", "hc-ping.com/abc", "https://"])
    func refusesAnythingButHTTPS(text: String) throws {
        let check = try configured()
        #expect(throws: HealthCheckError.self) { try check.setURL(text) }
        #expect(check.url == URL(string: ping)!)
        #expect(make().url == URL(string: ping)!)
    }

    @Test func aCorruptSettingsFileIsReportedNotPinged() throws {
        try Data("{oops".utf8).write(to: file)
        let check = make()
        check.tick(now: start)
        #expect(sent.urls.isEmpty)
        #expect(check.last?.error?.contains("settings.json") == true)
    }

    @Test func postsAnEmptyBody() async {
        StubProtocol.status = 200
        StubProtocol.body = "OK"
        #expect(await post() == nil)
        #expect(StubProtocol.seen?.httpMethod == "POST")
        #expect(StubProtocol.seen?.httpBody == nil)
        #expect(StubProtocol.seen?.httpBodyStream == nil)
    }

    @Test func aServerErrorIsAFailure() async {
        StubProtocol.status = 500
        StubProtocol.body = "boom"
        #expect(await post() == "HTTP 500")
    }

    @Test func anUnknownCheckIsAFailureDespiteTheOKStatus() async {
        StubProtocol.status = 200
        StubProtocol.body = "OK (not found)"
        #expect(await post() == "The monitor does not recognize this URL")
    }
}
