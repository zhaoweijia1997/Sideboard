// Draws the companion app's launcher icons and Android TV banner from Resources/AppIcon.icns.
//
//     swift tools/make-android-art.swift
//
// Run tools/make-icon.swift first if the icon changed.
import AppKit

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let res = root.appending(path: "android/app/src/main/res")
guard let icon = NSImage(contentsOf: root.appending(path: "Resources/AppIcon.icns")) else { fatalError("no AppIcon.icns") }

func render(width: Int, height: Int, _ draw: (CGContext) -> Void) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw(NSGraphicsContext.current!.cgContext)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

func write(_ data: Data, _ path: String) throws {
    let url = res.appending(path: path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url)
}

// Launcher icons. The macOS icon has a 10% margin around its tile, which suits Android's legacy icons.
for (folder, pixels) in [("mdpi", 48), ("hdpi", 72), ("xhdpi", 96), ("xxhdpi", 144), ("xxxhdpi", 192)] {
    try write(render(width: pixels, height: pixels) { _ in
        icon.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    }, "mipmap-\(folder)/ic_launcher.png")
}

// TV banner, 320 × 180: the icon and the name on the icon's green.
try write(render(width: 320, height: 180) { ctx in
    let gradient = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
        colors: [CGColor(red: 0.31, green: 0.85, blue: 0.66, alpha: 1), CGColor(red: 0.08, green: 0.38, blue: 0.43, alpha: 1)] as CFArray,
        locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 180), end: CGPoint(x: 320, y: 0), options: [])
    icon.draw(in: NSRect(x: 14, y: 34, width: 112, height: 112))
    let title = NSAttributedString(string: "Sideboard", attributes: [
        .font: NSFont.systemFont(ofSize: 40, weight: .bold), .foregroundColor: NSColor.white,
    ])
    title.draw(at: NSPoint(x: 128, y: 66))
}, "drawable-xhdpi/banner.png")
print("Wrote launcher icons and the TV banner")
