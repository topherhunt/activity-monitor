// Draws the app icon and writes Sources/ActivityMonitor/Resources/AppIcon.icns.
// Run with:  swift scripts/make-icon.swift
//
// The shape is the menu-bar symbol (SF Symbols "chart.bar.xaxis"): four bars on
// a baseline under a rounded axis rule. Here each bar takes one of the default
// category colours, which is what the timeline uses.
//
// Every size is drawn from the vector geometry rather than downscaled from the
// largest, so the 16pt icon in a Finder list stays crisp.

import Cocoa

let categoryColors = ["#e0a03c", "#3b7dd8", "#7d5bbe", "#3fa88a"]
let axisColor = "#e8eaee"
let plateTop = "#2f3542"
let plateBottom = "#1b1e24"

// Measured off the rendered symbol, in its own 343x266 space with y running
// down from the top. Bars share a baseline; the rule sits below it.
let symW = 343.0, symH = 266.0
let barTops = [72.0, 14.0, 43.0, 101.0]
let barLefts = [44.0, 111.3, 178.6, 245.9]
let barW = 53.0
let baseline = 207.0
let ruleRect = NSRect(x: 30, y: 232, width: 283, height: 15)

func color(_ hex: String) -> NSColor {
    var v: UInt64 = 0
    Scanner(string: String(hex.dropFirst())).scanHexInt64(&v)
    return NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255,
                   green: CGFloat((v >> 8) & 0xff) / 255,
                   blue: CGFloat(v & 0xff) / 255, alpha: 1)
}

func draw(side: CGFloat) -> NSBitmapImageRep {
    let px = Int(side)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high

    let u = side / 1024                     // everything below is in 1024 units

    // The rounded plate. macOS leaves a margin around the artwork so icons of
    // different shapes optically match; 100/1024 is Apple's grid for a square.
    let plate = NSRect(x: 100 * u, y: 100 * u, width: 824 * u, height: 824 * u)
    let platePath = NSBezierPath(roundedRect: plate, xRadius: 184 * u, yRadius: 184 * u)
    platePath.addClip()
    NSGradient(starting: color(plateTop), ending: color(plateBottom))!
        .draw(in: plate, angle: -90)

    // Content box, keeping the symbol's own aspect ratio.
    let contentW = 620 * u
    let contentH = contentW * (symH / symW)
    let cx = (side - contentW) / 2
    let cy = (side - contentH) / 2
    let s = contentW / symW

    /// Symbol space (y down) -> canvas (y up).
    func mapped(_ r: NSRect) -> NSRect {
        NSRect(x: cx + r.minX * s, y: cy + (symH - r.minY - r.height) * s,
               width: r.width * s, height: r.height * s)
    }

    for (i, top) in barTops.enumerated() {
        let r = mapped(NSRect(x: barLefts[i], y: top, width: barW, height: baseline - top))
        let radius = r.width * 0.22
        color(categoryColors[i]).setFill()
        NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius).fill()
    }

    let rule = mapped(ruleRect)
    color(axisColor).setFill()
    NSBezierPath(roundedRect: rule, xRadius: rule.height / 2, yRadius: rule.height / 2).fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

// ---- write the iconset and convert it ----

let root = URL(fileURLWithPath: CommandLine.arguments.first.map {
    URL(fileURLWithPath: $0).deletingLastPathComponent().deletingLastPathComponent().path
} ?? ".")
let fm = FileManager.default
let iconset = fm.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)

// (point size, scale) -> the filenames iconutil expects.
for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
                        (256, 1), (256, 2), (512, 1), (512, 2)] {
    let rep = draw(side: CGFloat(points * scale))
    let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
    try rep.representation(using: .png, properties: [:])!
        .write(to: iconset.appendingPathComponent(name))
}

let out = root.appendingPathComponent("Sources/ActivityMonitor/Resources/AppIcon.icns")
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try task.run()
task.waitUntilExit()
guard task.terminationStatus == 0 else {
    FileHandle.standardError.write("iconutil failed\n".data(using: .utf8)!)
    exit(1)
}
try? fm.removeItem(at: iconset)
print("wrote \(out.path)")
