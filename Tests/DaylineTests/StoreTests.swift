import Foundation
import SQLite3
import Testing
@testable import Dayline

struct StoreTests {
    let store: Store
    /// Local midnight, so buckets can be placed either side of a day boundary.
    let midnight = Int(Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_793_000_000))
        .timeIntervalSince1970)

    init() throws {
        store = try Store(path: ":memory:")
    }

    private func add(_ bundleID: String, at bucket: Int, seconds: Int) {
        store.add(bucketStart: bucket, bundleID: bundleID, appName: bundleID, title: "", url: "",
                  seconds: seconds, switches: 0)
    }

    private func key(_ epoch: Int) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(epoch)))
    }

    @Test func addReportsWhetherTheWriteLanded() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).sqlite3").path
        let store = try Store(path: path)
        let write = { store.add(bucketStart: 0, bundleID: "a", appName: "a", title: "", url: "",
                                seconds: 1, switches: 0) }
        #expect(write())

        var other: OpaquePointer?
        #expect(sqlite3_open(path, &other) == SQLITE_OK)
        defer { sqlite3_close(other) }
        let trigger = "CREATE TRIGGER refuse BEFORE UPDATE ON bucket_tally BEGIN SELECT RAISE(ABORT, 'no'); END;"
        #expect(sqlite3_exec(other, trigger, nil, nil, nil) == SQLITE_OK)
        #expect(!write())
    }

    @Test func sumsEveryAppInADay() throws {
        add("com.apple.Safari", at: midnight + 60, seconds: 40)
        add("dev.herdr.app", at: midnight + 60, seconds: 15)
        add("dev.herdr.app", at: midnight + 3600, seconds: 30)
        let days = try store.activeSecondsByDay(from: midnight, to: midnight + 7200)
        #expect(days == [key(midnight): 85])
    }

    @Test func idleAndLockedDoNotCount() throws {
        add("dev.herdr.app", at: midnight + 60, seconds: 20)
        add(Sampler.idleBundleID, at: midnight + 120, seconds: 60)
        add(Sampler.lockedBundleID, at: midnight + 180, seconds: 60)
        let days = try store.activeSecondsByDay(from: midnight, to: midnight + 7200)
        #expect(days == [key(midnight): 20])
    }

    @Test func aDayOfOnlyIdleAndLockedIsAbsent() throws {
        add(Sampler.idleBundleID, at: midnight + 120, seconds: 60)
        add(Sampler.lockedBundleID, at: midnight + 180, seconds: 60)
        #expect(try store.activeSecondsByDay(from: midnight, to: midnight + 7200).isEmpty)
    }

    @Test func splitsDaysAtLocalMidnight() throws {
        add("dev.herdr.app", at: midnight - 60, seconds: 10)
        add("dev.herdr.app", at: midnight, seconds: 20)
        let days = try store.activeSecondsByDay(from: midnight - 3600, to: midnight + 3600)
        #expect(days == [key(midnight - 60): 10, key(midnight): 20])
    }

    @Test func excludesBucketsOutsideTheRange() throws {
        add("dev.herdr.app", at: midnight - 60, seconds: 10)
        add("dev.herdr.app", at: midnight, seconds: 20)
        add("dev.herdr.app", at: midnight + 60, seconds: 30)
        #expect(try store.activeSecondsByDay(from: midnight, to: midnight + 60) == [key(midnight): 20])
    }
}
