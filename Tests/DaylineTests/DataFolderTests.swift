import Foundation
import Testing
@testable import Dayline

struct DataFolderTests {
    let former: URL
    let dir: URL

    init() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        former = root.appendingPathComponent("ActivityMonitor", isDirectory: true)
        dir = root.appendingPathComponent("Dayline", isDirectory: true)
        try FileManager.default.createDirectory(at: former, withIntermediateDirectories: true)
        try write("old data", to: former)
    }

    private func write(_ body: String, to folder: URL) throws {
        try Data(body.utf8).write(to: folder.appendingPathComponent("activity.sqlite3"))
    }

    private func contents(of folder: URL) throws -> String {
        try String(contentsOf: folder.appendingPathComponent("activity.sqlite3"), encoding: .utf8)
    }

    @Test func movesTheFormerFolderOver() throws {
        try DataFolder.adopt(former: former, into: dir, formerAppRunning: false)
        #expect(try contents(of: dir) == "old data")
        #expect(!FileManager.default.fileExists(atPath: former.path))
    }

    @Test func refusesWhileTheFormerAppIsRunning() throws {
        #expect(throws: DataFolderError.self) {
            try DataFolder.adopt(former: former, into: dir, formerAppRunning: true)
        }
        #expect(try contents(of: former) == "old data")
        #expect(!FileManager.default.fileExists(atPath: dir.path))
    }

    @Test func leavesBothAloneWhenTheNewFolderExists() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try write("new data", to: dir)
        try DataFolder.adopt(former: former, into: dir, formerAppRunning: true)
        #expect(try contents(of: dir) == "new data")
        #expect(try contents(of: former) == "old data")
    }

    @Test func doesNothingWithoutAFormerFolder() throws {
        try FileManager.default.removeItem(at: former)
        try DataFolder.adopt(former: former, into: dir, formerAppRunning: true)
        #expect(!FileManager.default.fileExists(atPath: dir.path))
    }
}
