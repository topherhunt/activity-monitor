import Cocoa

enum DataFolderError: Error, CustomStringConvertible {
    case formerAppRunning

    var description: String {
        "Quit the old Activity Monitor app and delete it, then open Dayline again. Your data moves over on that launch."
    }
}

/// Creates the data folder, first adopting the one left by this app's former
/// name, "Activity Monitor".
enum DataFolder {
    static func prepare(_ dir: URL) throws {
        let former = dir.deletingLastPathComponent().appendingPathComponent("ActivityMonitor", isDirectory: true)
        let running = !NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.topherhunt.activitymonitor").isEmpty
        try adopt(former: former, into: dir, formerAppRunning: running)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    /// Moves `former` to `dir` unless `dir` already exists, in which case both are
    /// left alone so nothing gets merged or overwritten. The former app must not
    /// be running: it would keep the database open and write to it mid-move.
    static func adopt(former: URL, into dir: URL, formerAppRunning: Bool) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: former.path), !fm.fileExists(atPath: dir.path) else { return }
        guard !formerAppRunning else { throw DataFolderError.formerAppRunning }
        try fm.moveItem(at: former, to: dir)
    }
}
