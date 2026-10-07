// Draws Sideboard's app icon and writes Resources/AppIcon.icns.
//
//     swift tools/make-icon.swift
//
// Everything is drawn with Core Graphics paths (SF Symbols may not be used in app icons).
// A TV with a pulse line (watching how it's doing) and a phone in front: any Android device.
import AppKit

let size: CGFloat = 1024

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func roundedRect(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func drawIcon(in ctx: CGContext) {
    // Work top-down, like the design grid.
    ctx.translateBy(x: 0, y: size)
    ctx.scaleBy(x: 1, y: -1)

    // Background tile on the macOS icon grid: 824 pt body, 100 pt margin.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = roundedRect(tile, 185)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 12), blur: 28, color: color(0x000000, 0.28))
    ctx.addPath(tilePath)
    ctx.setFillColor(color(0x1E8E7E))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    let background = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
        colors: [color(0x4FD8A8), color(0x1F9E86), color(0x15606E)] as CFArray,
        locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(background, start: CGPoint(x: 220, y: 100), end: CGPoint(x: 804, y: 924), options: [])
    // Soft light from the top.
    let glow = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
        colors: [color(0xFFFFFF, 0.26), color(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 380, y: 160), startRadius: 0,
                           endCenter: CGPoint(x: 380, y: 160), endRadius: 620, options: [])

    let shadow = color(0x07343A, 0.38)

    // TV: frame, stand, screen.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 14), blur: 26, color: shadow)
    ctx.addPath(roundedRect(CGRect(x: 190, y: 250, width: 600, height: 400), 46))
    ctx.addPath(roundedRect(CGRect(x: 452, y: 640, width: 76, height: 70), 10))
    ctx.addPath(roundedRect(CGRect(x: 360, y: 700, width: 260, height: 36), 18))
    ctx.setFillColor(color(0xFFFFFF, 0.97))
    ctx.fillPath()
    ctx.restoreGState()
    let screen = CGRect(x: 218, y: 278, width: 544, height: 344)
    ctx.addPath(roundedRect(screen, 24))
    ctx.setFillColor(color(0x0F3238))
    ctx.fillPath()

    // Pulse line across the screen.
    ctx.saveGState()
    ctx.addPath(roundedRect(screen, 24))
    ctx.clip()
    let pulse = CGMutablePath()
    pulse.move(to: CGPoint(x: 230, y: 460))
    for point in [(370, 460), (408, 392), (452, 548), (502, 336), (546, 460), (750, 460)] {
        pulse.addLine(to: CGPoint(x: point.0, y: point.1))
    }
    ctx.addPath(pulse)
    ctx.setStrokeColor(color(0x5CF2C2))
    ctx.setLineWidth(26)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.strokePath()
    ctx.restoreGState()

    // Phone in front, bottom right.
    let phone = CGRect(x: 650, y: 470, width: 170, height: 300)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 14), blur: 26, color: shadow)
    ctx.addPath(roundedRect(phone, 34))
    ctx.setFillColor(color(0xFFFFFF))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.addPath(roundedRect(phone.insetBy(dx: 16, dy: 16), 22))
    ctx.setFillColor(color(0x0F3238))
    ctx.fillPath()
    // Three bars: the phone's own readings.
    ctx.setFillColor(color(0x5CF2C2))
    for (index, height) in [70.0, 120.0, 95.0].enumerated() {
        let x = phone.minX + 42 + CGFloat(index) * 32
        ctx.addPath(roundedRect(CGRect(x: x, y: phone.maxY - 52 - height, width: 22, height: height), 8))
    }
    ctx.fillPath()
    ctx.restoreGState()
}

let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
    samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
drawIcon(in: NSGraphicsContext.current!.cgContext)
NSGraphicsContext.restoreGraphicsState()

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let master = FileManager.default.temporaryDirectory.appending(path: "sideboard-icon-1024.png")
try rep.representation(using: .png, properties: [:])!.write(to: master)

// Every size macOS asks for, then pack them into an .icns.
let iconset = FileManager.default.temporaryDirectory.appending(path: "SideboardIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        let sips = Process()
        sips.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
        sips.arguments = ["-z", "\(pixels)", "\(pixels)", master.path, "--out", iconset.appending(path: name).path]
        sips.standardOutput = FileHandle.nullDevice
        try sips.run()
        sips.waitUntilExit()
    }
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", root.appending(path: "Resources/AppIcon.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
print("Wrote Resources/AppIcon.icns (preview: \(master.path))")
