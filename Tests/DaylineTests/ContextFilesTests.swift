import Foundation
import Testing
@testable import Dayline

/// Each test gets its own directory of real files; the mtime logic is the point.
struct ContextFilesTests {
    let bundleID = "dev.herdr.app"
    let dir: URL
    let files: ContextFiles

    init() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        files = ContextFiles(dir: dir)
    }

    private func write(_ body: String, mtime: Date = Date()) throws {
        let file = dir.appendingPathComponent("\(bundleID).json")
        try Data(body.utf8).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: file.path)
    }

    @Test func freshFileSuppliesTitleAndURL() throws {
        try write(#"{"title": "my-repo / fix login", "url": "https://example.com/1"}"#)
        #expect(files.fresh(bundleID: bundleID)
            == .init(title: "my-repo / fix login", url: "https://example.com/1"))
    }

    @Test func urlIsOptionalAndTitleIsTrimmed() throws {
        try write(#"{"title": "  my-repo\n"}"#)
        #expect(files.fresh(bundleID: bundleID) == .init(title: "my-repo", url: ""))
    }

    @Test func missingFileYieldsNothing() {
        #expect(files.fresh(bundleID: bundleID) == nil)
    }

    @Test func anotherAppsFileIsNotUsed() throws {
        try write(#"{"title": "my-repo"}"#)
        #expect(files.fresh(bundleID: "com.apple.Safari") == nil)
    }

    @Test func fileIsFreshUnderSixtySecondsAndStaleAfter() throws {
        let now = Date()
        try write(#"{"title": "my-repo"}"#, mtime: now.addingTimeInterval(-59))
        #expect(files.fresh(bundleID: bundleID, now: now)?.title == "my-repo")
        #expect(files.fresh(bundleID: bundleID, now: now.addingTimeInterval(1)) == nil)
    }

    @Test func farFutureMtimeCountsAsStale() throws {
        try write(#"{"title": "my-repo"}"#, mtime: Date().addingTimeInterval(3600))
        #expect(files.fresh(bundleID: bundleID) == nil)
    }

    @Test(arguments: ["not json", "{}", #"{"title": 7}"#, #"{"title": "   "}"#])
    func malformedFileYieldsNothing(body: String) throws {
        try write(body)
        #expect(files.fresh(bundleID: bundleID) == nil)
    }

    @Test func rewritingAMalformedFileRecovers() throws {
        let now = Date()
        try write("not json", mtime: now.addingTimeInterval(-2))
        #expect(files.fresh(bundleID: bundleID, now: now) == nil)
        try write(#"{"title": "my-repo"}"#, mtime: now.addingTimeInterval(-1))
        #expect(files.fresh(bundleID: bundleID, now: now)?.title == "my-repo")
    }

    @Test func rewritingPicksUpTheNewTitle() throws {
        let now = Date()
        try write(#"{"title": "first"}"#, mtime: now.addingTimeInterval(-2))
        #expect(files.fresh(bundleID: bundleID, now: now)?.title == "first")
        try write(#"{"title": "second"}"#, mtime: now.addingTimeInterval(-1))
        #expect(files.fresh(bundleID: bundleID, now: now)?.title == "second")
    }
}
