import Cocoa
import WebKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var webView: WKWebView!
    private var store: Store!
    private var sampler: Sampler!

    private let supportDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("ActivityMonitor", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private var rulesURL: URL { supportDir.appendingPathComponent("rules.json") }

    /// Set AM_RESOURCES to a source directory to iterate on the dashboard
    /// without rebuilding the bundle.
    private var resourceDir: URL {
        if let override = ProcessInfo.processInfo.environment["AM_RESOURCES"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return Bundle.main.resourceURL ?? URL(fileURLWithPath: ".")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            store = try Store(path: supportDir.appendingPathComponent("activity.sqlite3").path)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not open the activity database"
            alert.informativeText = "\(error)"
            alert.runModal()
            NSApp.terminate(nil)
            return
        }

        sampler = Sampler(store: store)
        if !sampler.isTrusted { sampler.requestAccessibility() }
        sampler.start()

        buildStatusItem()
        buildPopover()
    }

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "chart.bar.xaxis",
                                   accessibilityDescription: "Activity Monitor")
            button.image?.isTemplate = true
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    private func buildPopover() {
        let config = WKWebViewConfiguration()
        config.userContentController.addScriptMessageHandler(
            Bridge(delegate: self), contentWorld: .page, name: "bridge")

        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 960, height: 640), configuration: config)
        webView.setValue(false, forKey: "drawsBackground")

        let controller = NSViewController()
        controller.view = webView

        popover = NSPopover()
        popover.contentViewController = controller
        popover.contentSize = NSSize(width: 960, height: 640)
        popover.behavior = .transient
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            menu.addItem(withTitle: "Reveal Data Folder", action: #selector(revealData), keyEquivalent: "")
            menu.addItem(.separator())
            menu.addItem(withTitle: "Quit Activity Monitor", action: #selector(NSApp.terminate(_:)), keyEquivalent: "q")
            menu.items.forEach { $0.target = $0.action == #selector(revealData) ? self : NSApp }
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
            return
        }

        if popover.isShown {
            popover.performClose(sender)
        } else {
            let index = resourceDir.appendingPathComponent("dashboard.html")
            webView.loadFileURL(index, allowingReadAccessTo: resourceDir)
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    @objc private func revealData() {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: supportDir.path)
    }

    // MARK: - Bridge commands

    func handle(command: String, args: [String: Any]) -> String {
        switch command {
        case "getDay":     return json(getDay(args))
        case "getRange":   return json(getRange(args))
        case "getList":    return json(getList(args))
        case "getRaw":     return json(getRaw(args))
        case "getRules":   return jsonRules()
        case "setRules":   return setRules(args)
        case "status":     return json([
                                "trusted": sampler.isTrusted,
                                "last": sampler.lastObservation,
                           ])
        case "quit":       NSApp.terminate(nil); return "{}"
        default:           return json(["error": "unknown command \(command)"])
        }
    }

    private func json(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.withoutEscapingSlashes]),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }

    private func jsonRules() -> String {
        let set = RuleStore.load(at: rulesURL)
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? enc.encode(set), let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }

    private func setRules(_ args: [String: Any]) -> String {
        guard let body = args["rules"] as? String, let data = body.data(using: .utf8) else {
            return json(["ok": false, "error": "missing rules payload"])
        }
        do {
            let set = try JSONDecoder().decode(RuleSet.self, from: data)
            RuleStore.save(set, to: rulesURL)
            return json(["ok": true])
        } catch {
            return json(["ok": false, "error": "\(error)"])
        }
    }

    /// Day start as epoch seconds; defaults to today.
    private func dayStart(_ args: [String: Any]) -> Int {
        if let d = args["day"] as? Int { return d }
        return Int(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970)
    }

    /// Activities below this are noise -- a glance at a window on the way to
    /// somewhere else -- and are rolled into a single "hidden" line instead.
    static let minReportedSeconds = 300

    /// Category totals and collapsed activity rows for an arbitrary span. Backs
    /// both the whole-day view and the drill-down when a bucket is selected.
    /// `minSeconds` drops short activities; the drill-down passes 0 because you
    /// went there to see detail.
    private func summarize(rows: [TallyRow], engine: RuleEngine,
                           minSeconds: Int = 0) -> [String: Any] {
        var totals: [String: Int] = [:]
        var labelTotals: [String: (category: String, seconds: Int, switches: Int)] = [:]
        var colors: [String: String] = [:]

        for row in rows {
            let r = engine.resolve(bundleID: row.bundleID, appName: row.appName,
                                   title: row.title, url: row.url)
            totals[r.category, default: 0] += row.seconds
            colors[r.category] = r.color
            var entry = labelTotals[r.label] ?? (r.category, 0, 0)
            entry.seconds += row.seconds
            entry.switches += row.switches
            entry.category = r.category
            labelTotals[r.label] = entry
        }

        let ranked = labelTotals.sorted { $0.value.seconds > $1.value.seconds }
        let kept = ranked.filter { $0.value.seconds >= minSeconds }
        let dropped = ranked.filter { $0.value.seconds < minSeconds }

        return [
            "totals": totals.sorted { $0.value > $1.value }.map {
                ["category": $0.key, "seconds": $0.value, "color": colors[$0.key] ?? "#6b7280"] as [String: Any]
            },
            "labels": kept.prefix(120).map {
                ["label": $0.key, "category": $0.value.category, "seconds": $0.value.seconds,
                 "switches": $0.value.switches,
                 "color": colors[$0.value.category] ?? "#6b7280"] as [String: Any]
            },
            "hidden": ["count": dropped.count,
                       "seconds": dropped.reduce(0) { $0 + $1.value.seconds }],
        ]
    }

    private func getRange(_ args: [String: Any]) -> [String: Any] {
        let from = (args["from"] as? Int) ?? dayStart(args)
        let to = (args["to"] as? Int) ?? (from + Store.bucketSeconds)
        let engine = RuleEngine(RuleStore.load(at: rulesURL))
        return summarize(rows: store.rows(from: from, to: to), engine: engine)
    }

    /// The timeline draws one slice per minute, each showing the single activity
    /// that owned most of that minute. Collapsing to a winner is the point: it
    /// throws away the tab-flipping noise that made contiguous segments useless.
    private func getDay(_ args: [String: Any]) -> [String: Any] {
        let start = dayStart(args)
        let end = start + 86_400
        let engine = RuleEngine(RuleStore.load(at: rulesURL))
        let rows = store.rows(from: start, to: end)

        var perMinute: [Int: [String: Int]] = [:]        // minute -> label -> seconds
        var labelCat: [String: String] = [:]
        var labelApps: [String: [String: Int]] = [:]     // label -> app -> seconds
        var colors: [String: String] = [:]
        for row in rows {
            let r = engine.resolve(bundleID: row.bundleID, appName: row.appName,
                                   title: row.title, url: row.url)
            let minute = (row.bucketStart / 60) * 60
            perMinute[minute, default: [:]][r.label, default: 0] += row.seconds
            labelCat[r.label] = r.category
            labelApps[r.label, default: [:]][row.appName, default: 0] += row.seconds
            colors[r.category] = r.color
        }

        // Send the activity strings once and refer to them by index; a full day
        // is 1440 slices and most of them repeat the one before.
        var actIndex: [String: Int] = [:]
        var acts: [String] = []
        var actCats: [String] = []
        var actApps: [String] = []
        var minutes: [[Int]] = []
        for minute in perMinute.keys.sorted() {
            guard let winner = perMinute[minute]!.max(by: {
                // Ties break on the label so a redraw never reshuffles colours.
                $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key
            })?.key else { continue }
            if actIndex[winner] == nil {
                actIndex[winner] = acts.count
                acts.append(winner)
                actCats.append(labelCat[winner] ?? "Uncategorized")
                // A rule can collapse several apps into one label; name the app
                // that actually contributed most of the label's time.
                actApps.append(labelApps[winner]?.max { $0.value < $1.value }?.key ?? "")
            }
            minutes.append([minute, actIndex[winner]!])
        }

        var out: [String: Any] = [
            "dayStart": start,
            "minuteSeconds": 60,
            "minutes": minutes,
            "acts": acts,
            "actCats": actCats,
            "actApps": actApps,
            "palette": colors,
            "days": store.daysWithData(),
        ]
        summarize(rows: rows, engine: engine, minSeconds: Self.minReportedSeconds)
            .forEach { out[$0.key] = $0.value }
        return out
    }

    /// One row per distinct activity label, carrying when that label was first
    /// seen. `group` is "day" (one group for the whole day) or "hour".
    private func getList(_ args: [String: Any]) -> [String: Any] {
        let start = dayStart(args)
        let end = start + 86_400
        let byHour = (args["group"] as? String) == "hour"
        let engine = RuleEngine(RuleStore.load(at: rulesURL))

        struct Entry {
            let group: Int, category: String, label: String, color: String, firstSeen: Int
            var seconds = 0, switches = 0
        }
        var entries: [String: Entry] = [:]
        var order: [String] = []                     // first-seen order, ascending

        // store.rows() is ordered by bucket_start, so the first time a key is
        // created is by definition the first time that activity was observed.
        for row in store.rows(from: start, to: end) {
            let r = engine.resolve(bundleID: row.bundleID, appName: row.appName,
                                   title: row.title, url: row.url)
            let group = byHour ? (row.bucketStart / 3600) * 3600 : start
            let key = "\(group)\u{1}\(r.label)"
            if entries[key] == nil {
                entries[key] = Entry(group: group, category: r.category, label: r.label,
                                     color: r.color, firstSeen: row.bucketStart)
                order.append(key)
            }
            entries[key]!.seconds += row.seconds
            entries[key]!.switches += row.switches
        }

        var rows: [[String: Any]] = []
        var hidden: [Int: (count: Int, seconds: Int)] = [:]
        for key in order {
            let e = entries[key]!
            guard e.seconds >= Self.minReportedSeconds else {
                var h = hidden[e.group] ?? (0, 0)
                h.count += 1
                h.seconds += e.seconds
                hidden[e.group] = h
                continue
            }
            rows.append(["group": e.group, "start": e.firstSeen, "label": e.label,
                         "category": e.category, "color": e.color,
                         "seconds": e.seconds, "switches": e.switches])
        }

        return [
            "dayStart": start,
            "group": byHour ? "hour" : "day",
            "rows": rows,
            "hidden": hidden.keys.sorted().map {
                ["group": $0, "count": hidden[$0]!.count, "seconds": hidden[$0]!.seconds]
            },
            "days": store.daysWithData(),
        ]
    }

    /// Raw, unresolved rows -- the view you need in order to write a rule.
    private func getRaw(_ args: [String: Any]) -> [String: Any] {
        let start = (args["from"] as? Int) ?? dayStart(args)
        let end = (args["to"] as? Int) ?? (start + 86_400)
        let engine = RuleEngine(RuleStore.load(at: rulesURL))
        var merged: [String: [String: Any]] = [:]
        for row in store.rows(from: start, to: end) {
            let key = "\(row.bundleID)\u{1}\(row.title)\u{1}\(row.url)"
            let r = engine.resolve(bundleID: row.bundleID, appName: row.appName,
                                   title: row.title, url: row.url)
            if var e = merged[key] {
                e["seconds"] = (e["seconds"] as! Int) + row.seconds
                merged[key] = e
            } else {
                merged[key] = ["app": row.appName, "bundleId": row.bundleID,
                               "title": row.title, "url": row.url,
                               "seconds": row.seconds,
                               "category": r.category, "label": r.label]
            }
        }
        let list = merged.values.sorted { ($0["seconds"] as! Int) > ($1["seconds"] as! Int) }
        return ["rows": Array(list.prefix(300))]
    }
}

/// Bridges `await window.webkit.messageHandlers.bridge.postMessage({cmd, ...})`
/// to AppDelegate.handle. Replies are JSON strings, parsed on the JS side.
final class Bridge: NSObject, WKScriptMessageHandlerWithReply {
    private weak var delegate: AppDelegate?
    init(delegate: AppDelegate) { self.delegate = delegate }

    func userContentController(_ controller: WKUserContentController,
                               didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        guard let body = message.body as? [String: Any],
              let cmd = body["cmd"] as? String else {
            replyHandler(nil, "malformed bridge message")
            return
        }
        replyHandler(delegate?.handle(command: cmd, args: body) ?? "{}", nil)
    }
}
