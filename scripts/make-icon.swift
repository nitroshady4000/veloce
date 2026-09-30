#!/usr/bin/env swift
import AppKit
import Foundation

// Draw the same simple V as the SwiftUI wordmark, directly into native bitmaps.
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = root.appendingPathComponent(".build/icon-assets/AppIcon.iconset")
let resources = root.appendingPathComponent("Resources")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)

func renderIcon(pixels: Int) throws -> Data {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: pixels * 4, bitsPerPixel: 32
    ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw NSError(domain: "VeloceIcon", code: 1)
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    context.shouldAntialias = true
    let transform = AffineTransform(scale: CGFloat(pixels) / 1024)
    (transform as NSAffineTransform).concat()

    let tile = NSBezierPath(roundedRect: NSRect(x: 79, y: 79, width: 866, height: 866), xRadius: 194, yRadius: 194)
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.15)
    shadow.shadowBlurRadius = 22
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.set()
    NSColor(srgbRed: 0.957, green: 0.947, blue: 0.922, alpha: 1).setFill()
    tile.fill()
    NSShadow().set()

    let inner = NSBezierPath(roundedRect: NSRect(x: 86, y: 86, width: 852, height: 852), xRadius: 187, yRadius: 187)
    NSColor.white.withAlphaComponent(0.62).setStroke()
    inner.lineWidth = 3
    inner.stroke()

    // Direction and spacing match the app's drawn mark, enlarged optically.
    let mark = NSBezierPath()
    mark.move(to: NSPoint(x: 267, y: 592))
    mark.line(to: NSPoint(x: 432, y: 295))
    mark.curve(to: NSPoint(x: 478, y: 295), controlPoint1: NSPoint(x: 445, y: 268), controlPoint2: NSPoint(x: 463, y: 268))
    mark.line(to: NSPoint(x: 743, y: 720))
    mark.lineWidth = 74
    mark.lineCapStyle = .round
    mark.lineJoinStyle = .round
    NSColor(srgbRed: 0.79, green: 0.27, blue: 0.18, alpha: 1).setStroke()
    mark.stroke()

    let dash = NSBezierPath()
    dash.move(to: NSPoint(x: 553, y: 710))
    dash.line(to: NSPoint(x: 638, y: 710))
    dash.lineWidth = 38
    dash.lineCapStyle = .round
    dash.stroke()
    NSGraphicsContext.restoreGraphicsState()

    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "VeloceIcon", code: 2)
    }
    return png
}

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let suffix = scale == 2 ? "@2x" : ""
        let data = try renderIcon(pixels: points * scale)
        try data.write(to: iconset.appendingPathComponent("icon_\(points)x\(points)\(suffix).png"))
    }
}
try renderIcon(pixels: 1024).write(to: resources.appendingPathComponent("AppIcon.png"))

// Modern ICNS elements carry PNG data. Writing that container directly also
// works on machines where iconutil cannot contact its image conversion service.
func bigEndian(_ value: Int) -> Data {
    var number = UInt32(value).bigEndian
    return withUnsafeBytes(of: &number) { Data($0) }
}
var elements = Data()
for (type, pixels) in [("icp4", 16), ("icp5", 32), ("icp6", 64), ("ic07", 128), ("ic08", 256), ("ic09", 512), ("ic10", 1024), ("ic11", 32), ("ic12", 64), ("ic13", 256), ("ic14", 512)] {
    let png = try renderIcon(pixels: pixels)
    elements.append(Data(type.utf8))
    elements.append(bigEndian(png.count + 8))
    elements.append(png)
}
var icns = Data("icns".utf8)
icns.append(bigEndian(elements.count + 8))
icns.append(elements)
try icns.write(to: resources.appendingPathComponent("AppIcon.icns"))
print("Created Resources/AppIcon.icns and Resources/AppIcon.png")
