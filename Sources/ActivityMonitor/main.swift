import Cocoa

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// Menu-bar only; LSUIElement in Info.plist covers the bundled case, this covers
// running the binary directly during development.
app.setActivationPolicy(.accessory)
app.run()
