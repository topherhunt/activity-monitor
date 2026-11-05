import Foundation

/// Reads `<dir>/<bundle id>.json`, written by apps whose window title can't say
/// what the user is doing. See "Reporting context from your app" in the README.
final class ContextFiles {
    /// Clients rewrite at least every 30s while frontmost. Past this one is
    /// presumed dead, so it can't keep crediting an old title.
    static let maxAge: TimeInterval = 60

    struct Context: Equatable {
        var title: String
        var url: String
    }

    private struct Payload: Decodable {
        var title: String
        var url: String?
    }

    private let dir: URL
    /// Last parse per app, so a malformed file logs once per write, not per poll.
    private var parsed: [String: (mtime: Date, context: Context?)] = [:]

    init(dir: URL) {
        self.dir = dir
    }

    /// The app's reported context, or nil if its file is missing, stale or
    /// malformed. A future mtime counts as age too: `now` can predate a write
    /// that lands mid-poll, but a clock jump must not make a file immortal.
    func fresh(bundleID: String, now: Date = Date()) -> Context? {
        let file = dir.appendingPathComponent("\(bundleID).json")
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              let mtime = attributes[.modificationDate] as? Date,
              abs(now.timeIntervalSince(mtime)) < Self.maxAge else { return nil }

        if let hit = parsed[bundleID], hit.mtime == mtime { return hit.context }
        let context = parse(file)
        parsed[bundleID] = (mtime, context)
        return context
    }

    private func parse(_ file: URL) -> Context? {
        do {
            let payload = try JSONDecoder().decode(Payload.self, from: Data(contentsOf: file))
            let title = payload.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else {
                NSLog("Ignoring context file %@: title is blank", file.path)
                return nil
            }
            return Context(title: title, url: payload.url ?? "")
        } catch {
            NSLog("Ignoring context file %@: %@", file.path, "\(error)")
            return nil
        }
    }
}
