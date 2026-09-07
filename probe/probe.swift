// Probe: confirms we can read frontmost app, focused-window title, and browser URL.
// Throwaway diagnostic for the real sampler. Prints on change, mirrors to JSONL.
//
//   swiftc -O probe/probe.swift -o probe/probe && probe/probe
//
// Run as a CLI, the Accessibility + Automation grants attach to the terminal,
// not to this binary. The real app gets its own grants.

import Cocoa
import ApplicationServices

let pollInterval = 2.0
let idleThreshold = 120.0
let logPath = FileManager.default.currentDirectoryPath + "/probe/probe-log.jsonl"

// ---------- Accessibility ----------

/// AX calls block until the target app answers. A hung app would otherwise hang
/// the sampler, so every app element gets a short messaging timeout.
func axMessagingTimeout(_ element: AXUIElement) {
    AXUIElementSetMessagingTimeout(element, 0.5)
}

func axCopy(_ element: AXUIElement, _ attribute: String) -> (CFTypeRef?, AXError) {
    var value: CFTypeRef?
    let err = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
    return (value, err)
}

func axString(_ element: AXUIElement, _ attribute: String) -> String? {
    let (value, err) = axCopy(element, attribute)
    guard err == .success else { return nil }
    return value as? String
}

/// Returns the focused window's title, plus a diagnostic string describing how we got it.
func focusedWindowTitle(pid: pid_t) -> (title: String?, how: String) {
    let app = AXUIElementCreateApplication(pid)
    axMessagingTimeout(app)

    for attribute in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
        let (value, err) = axCopy(app, attribute)
        if err == .apiDisabled {
            return (nil, "AX not trusted (apiDisabled)")
        }
        guard err == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            continue
        }
        let window = value as! AXUIElement
        axMessagingTimeout(window)
        if let title = axString(window, kAXTitleAttribute), !title.isEmpty {
            return (title, attribute)
        }
        return (nil, "\(attribute) resolved but kAXTitle was empty/unsupported")
    }
    return (nil, "no focused or main window (err on both attributes)")
}

// ---------- Browser URL via AppleScript ----------

let chromiumFamily: [String: String] = [
    "com.google.Chrome": "Google Chrome",
    "com.google.Chrome.beta": "Google Chrome Beta",
    "com.google.Chrome.canary": "Google Chrome Canary",
    "com.brave.Browser": "Brave Browser",
    "com.microsoft.edgemac": "Microsoft Edge",
    "com.vivaldi.Vivaldi": "Vivaldi",
    "company.thebrowser.Browser": "Arc",
]

func runAppleScript(_ source: String) -> (result: String?, error: String?) {
    guard let script = NSAppleScript(source: source) else {
        return (nil, "could not compile script")
    }
    var errorInfo: NSDictionary?
    let descriptor = script.executeAndReturnError(&errorInfo)
    if let errorInfo {
        let number = errorInfo["NSAppleScriptErrorNumber"] as? Int ?? 0
        let message = errorInfo["NSAppleScriptErrorMessage"] as? String ?? "\(errorInfo)"
        return (nil, "AppleScript \(number): \(message)")
    }
    return (descriptor.stringValue, nil)
}

/// nil for non-browsers. Otherwise (url, error) where exactly one side is populated.
func browserURL(bundleID: String) -> (url: String?, error: String?)? {
    let source: String
    if let appName = chromiumFamily[bundleID] {
        source = "tell application \"\(appName)\" to return URL of active tab of front window"
    } else if bundleID == "com.apple.Safari" {
        source = "tell application \"Safari\" to return URL of front document"
    } else {
        return nil
    }
    let (result, error) = runAppleScript(source)
    return (result, error)
}

// ---------- Idle ----------

func idleSeconds() -> Double {
    // kCGAnyInputEventType is ~0, which is not a declared CGEventType case.
    guard let anyInput = CGEventType(rawValue: ~UInt32(0)) else { return -1 }
    return CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: anyInput)
}

// ---------- Sampling ----------

struct Sample: Equatable {
    var bundleID: String
    var appName: String
    var title: String
    var url: String
    var idle: Bool
    var locked: Bool
}

var screenLocked = false
var lastSample: Sample?
var titleDiagnostics = Set<String>()

let logHandle: FileHandle? = {
    let fm = FileManager.default
    if !fm.fileExists(atPath: logPath) {
        fm.createFile(atPath: logPath, contents: nil)
    }
    return FileHandle(forWritingAtPath: logPath)
}()

func appendLog(_ sample: Sample, at date: Date) {
    guard let logHandle else { return }
    let row: [String: Any] = [
        "ts": ISO8601DateFormatter().string(from: date),
        "bundle_id": sample.bundleID,
        "app": sample.appName,
        "title": sample.title,
        "url": sample.url,
        "idle": sample.idle,
        "locked": sample.locked,
    ]
    guard let data = try? JSONSerialization.data(withJSONObject: row) else { return }
    logHandle.seekToEndOfFile()
    logHandle.write(data)
    logHandle.write(Data("\n".utf8))
}

let clock: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    return f
}()

func sample() {
    let now = Date()
    let idle = idleSeconds()

    guard let app = NSWorkspace.shared.frontmostApplication else {
        print("\(clock.string(from: now))  <no frontmost application>")
        return
    }

    let bundleID = app.bundleIdentifier ?? "unknown"
    let (rawTitle, how) = focusedWindowTitle(pid: app.processIdentifier)

    // Surface each distinct AX failure reason once, so we learn which apps misbehave.
    if rawTitle == nil {
        let key = "\(bundleID)|\(how)"
        if titleDiagnostics.insert(key).inserted {
            print("           ! \(app.localizedName ?? bundleID): \(how)")
        }
    }

    var url = ""
    if let (resolved, error) = browserURL(bundleID: bundleID) {
        if let resolved {
            url = resolved
        } else if let error {
            let key = "\(bundleID)|\(error)"
            if titleDiagnostics.insert(key).inserted {
                print("           ! \(app.localizedName ?? bundleID) URL: \(error)")
            }
        }
    }

    let current = Sample(
        bundleID: bundleID,
        appName: app.localizedName ?? bundleID,
        title: rawTitle ?? "",
        url: url,
        idle: idle >= idleThreshold,
        locked: screenLocked
    )

    guard current != lastSample else { return }
    lastSample = current
    appendLog(current, at: now)

    var line = "\(clock.string(from: now))  \(current.appName.padding(toLength: max(22, current.appName.count), withPad: " ", startingAt: 0))"
    line += current.title.isEmpty ? "(no title)" : "\"\(current.title)\""
    if !current.url.isEmpty { line += "  \(current.url)" }
    if current.locked { line += "  [LOCKED]" }
    else if current.idle { line += "  [IDLE \(Int(idle))s]" }
    print(line)
}

// ---------- Startup ----------

// Line-buffer so output stays live when piped to a file or another process.
setvbuf(stdout, nil, _IOLBF, 0)

let trusted = AXIsProcessTrustedWithOptions(
    [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
)

print("activity-monitor probe")
print("  accessibility trusted: \(trusted)")
print("  idle timer:            \(idleSeconds() >= 0 ? "ok" : "UNAVAILABLE (CGEventType(~0) was nil)")")
print("  logging to:            \(logPath)")
if !trusted {
    print("")
    print("  Grant Accessibility to your terminal in System Settings > Privacy & Security")
    print("  > Accessibility, then re-run. Window titles are unavailable until you do.")
}
print("")
print("  Printing on change, every \(Int(pollInterval))s. Ctrl-C to stop.")
print("")

let dnc = DistributedNotificationCenter.default()
dnc.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { _ in
    screenLocked = true
}
dnc.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { _ in
    screenLocked = false
}

sample()
let timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { _ in sample() }
RunLoop.main.add(timer, forMode: .common)
RunLoop.main.run()
