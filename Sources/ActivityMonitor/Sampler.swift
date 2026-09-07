import Cocoa
import ApplicationServices

/// Polls the frontmost app + focused window title and adds the elapsed time to
/// the current bucket. Idle and lock override app attribution entirely, so time
/// spent away is never credited to whatever happened to be in front.
final class Sampler {
    static let idleBundleID = "__idle__"
    static let lockedBundleID = "__locked__"

    private let store: Store
    private let pollInterval: TimeInterval = 2.0
    private let idleThreshold: TimeInterval = 120.0
    /// Cap on seconds credited to one poll, so a sleep/wake gap does not get
    /// billed as hours of whatever app was last in front.
    private let maxAttribution: TimeInterval = 10.0

    private var timer: Timer?
    private var lastPollAt = Date()
    private var lastKey: String?
    private var screenLocked = false

    /// Cached so we only pay the AppleScript round-trip when the page changed.
    private var lastURLKey: String?
    private var lastURL = ""

    private(set) var lastObservation = "starting up"

    init(store: Store) {
        self.store = store
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            self?.screenLocked = true
        }
        dnc.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            self?.screenLocked = false
        }
    }

    func start() {
        lastPollAt = Date()
        let t = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    var isTrusted: Bool { AXIsProcessTrusted() }

    @discardableResult
    func requestAccessibility() -> Bool {
        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
    }

    private func poll() {
        let now = Date()
        let elapsed = min(now.timeIntervalSince(lastPollAt), maxAttribution)
        lastPollAt = now
        guard elapsed > 0 else { return }

        let (bundleID, appName, title, url) = observe()

        let key = "\(bundleID)\u{1}\(title)\u{1}\(url)"
        let isSwitch = (lastKey != nil && lastKey != key)
        lastKey = key

        let bucket = (Int(now.timeIntervalSince1970) / Store.bucketSeconds) * Store.bucketSeconds
        store.add(bucketStart: bucket, bundleID: bundleID, appName: appName,
                  title: title, url: url,
                  seconds: Int(elapsed.rounded()), switches: isSwitch ? 1 : 0)

        lastObservation = title.isEmpty ? appName : "\(appName) — \(title)"
    }

    private func observe() -> (String, String, String, String) {
        if screenLocked {
            return (Self.lockedBundleID, "Locked", "", "")
        }
        if idleSeconds() >= idleThreshold {
            return (Self.idleBundleID, "Idle", "", "")
        }
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return (Self.idleBundleID, "Idle", "", "")
        }
        let bundleID = app.bundleIdentifier ?? "unknown"
        let appName = app.localizedName ?? bundleID
        let title = focusedWindowTitle(pid: app.processIdentifier)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var url = ""
        if BrowserScript.isBrowser(bundleID) {
            let urlKey = "\(bundleID)\u{1}\(title)"
            if urlKey == lastURLKey {
                url = lastURL
            } else {
                url = BrowserScript.currentURL(bundleID: bundleID) ?? ""
                lastURLKey = urlKey
                lastURL = url
            }
        }
        return (bundleID, appName, title, url)
    }

    private func idleSeconds() -> TimeInterval {
        // kCGAnyInputEventType (~0) is not a declared CGEventType case.
        guard let anyInput = CGEventType(rawValue: ~UInt32(0)) else { return 0 }
        return CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: anyInput)
    }

    /// AX calls block until the target app replies, so every element gets a
    /// short messaging timeout -- otherwise one hung app stalls the sampler.
    private func focusedWindowTitle(pid: pid_t) -> String {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)

        for attribute in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            var value: CFTypeRef?
            let err = AXUIElementCopyAttributeValue(app, attribute as CFString, &value)
            guard err == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { continue }
            let window = value as! AXUIElement
            AXUIElementSetMessagingTimeout(window, 0.5)

            var titleValue: CFTypeRef?
            if AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleValue) == .success,
               let title = titleValue as? String, !title.isEmpty {
                return title
            }
        }
        return ""
    }
}

enum BrowserScript {
    private static let chromium: [String: String] = [
        "com.google.Chrome": "Google Chrome",
        "com.google.Chrome.beta": "Google Chrome Beta",
        "com.google.Chrome.canary": "Google Chrome Canary",
        "com.brave.Browser": "Brave Browser",
        "com.microsoft.edgemac": "Microsoft Edge",
        "com.vivaldi.Vivaldi": "Vivaldi",
        "company.thebrowser.Browser": "Arc",
    ]

    static func isBrowser(_ bundleID: String) -> Bool {
        chromium[bundleID] != nil || bundleID == "com.apple.Safari"
    }

    static func currentURL(bundleID: String) -> String? {
        let source: String
        if let name = chromium[bundleID] {
            source = "tell application \"\(name)\" to return URL of active tab of front window"
        } else if bundleID == "com.apple.Safari" {
            source = "tell application \"Safari\" to return URL of front document"
        } else {
            return nil
        }
        guard let script = NSAppleScript(source: source) else { return nil }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        return error == nil ? result.stringValue : nil
    }
}
