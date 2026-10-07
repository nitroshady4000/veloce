#!/usr/bin/env swift
import AppKit
import Foundation

// Draw the same waveform V as the SwiftUI wordmark, directly into native bitmaps.
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
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.30)
    shadow.shadowBlurRadius = 22
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.set()
    NSColor(srgbRed: 0.10, green: 0.09, blue: 0.075, alpha: 1).setFill()
    tile.fill()
    NSShadow().set()

    NSGradient(colors: [
        NSColor(srgbRed: 0.078, green: 0.068, blue: 0.056, alpha: 1),
        NSColor(srgbRed: 0.177, green: 0.157, blue: 0.126, alpha: 1)
    ])?.draw(in: tile, angle: 90)

    let inner = NSBezierPath(roundedRect: NSRect(x: 86, y: 86, width: 852, height: 852), xRadius: 187, yRadius: 187)
    NSColor(srgbRed: 1, green: 0.88, blue: 0.67, alpha: 0.20).setStroke()
    inner.lineWidth = 2
    inner.stroke()

    // The waveform V of VeloceMarkShape (unit space, y down), flipped for AppKit.
    let bars: [(CGFloat, CGFloat, CGFloat)] = [
        (0.180, 0.260, 0.470), (0.340, 0.385, 0.690), (0.500, 0.560, 0.840),
        (0.660, 0.300, 0.700), (0.820, 0.150, 0.450)
    ]
    let side: CGFloat = 640, width = side * 0.13
    let mark = CGMutablePath()
    for (x, top, bottom) in bars {
        let rect = CGRect(x: 512 + (x - 0.5) * side - width / 2, y: 512 + (0.495 - bottom) * side,
                          width: width, height: (bottom - top) * side)
        mark.addRoundedRect(in: rect, cornerWidth: width / 2, cornerHeight: width / 2)
    }
    let cg = context.cgContext
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    cg.saveGState()
    cg.addPath(mark)
    cg.setFillColor(NSColor(srgbRed: 1, green: 0.71, blue: 0.28, alpha: 0.76).cgColor)
    cg.setShadow(offset: .zero, blur: 46, color: NSColor(srgbRed: 1, green: 0.47, blue: 0.21, alpha: 0.48).cgColor)
    cg.fillPath()
    cg.restoreGState()

    cg.saveGState()
    cg.addPath(mark)
    cg.clip()
    let colors = [
        NSColor(srgbRed: 1, green: 0.435, blue: 0.369, alpha: 1).cgColor,
        NSColor(srgbRed: 1, green: 0.710, blue: 0.278, alpha: 1).cgColor,
        NSColor(srgbRed: 1, green: 0.839, blue: 0.420, alpha: 1).cgColor,
        NSColor(srgbRed: 1, green: 0.890, blue: 0.639, alpha: 1).cgColor
    ]
    if let gradient = CGGradient(colorsSpace: colorSpace, colors: colors as CFArray, locations: [0, 0.38, 0.77, 1]) {
        cg.drawLinearGradient(gradient, start: CGPoint(x: 335, y: 260), end: CGPoint(x: 685, y: 750), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }
    // A restrained violet reflection along the lower edge recalls the pill's
    // spectrum without turning the small icon into a multicolour illustration.
    if let reflection = CGGradient(colorsSpace: colorSpace, colors: [
        NSColor(srgbRed: 0.56, green: 0.36, blue: 1, alpha: 0.30).cgColor,
        NSColor(srgbRed: 0.56, green: 0.36, blue: 1, alpha: 0).cgColor
    ] as CFArray, locations: [0, 1]) {
        cg.drawLinearGradient(reflection, start: CGPoint(x: 370, y: 255), end: CGPoint(x: 490, y: 375), options: [])
    }
    cg.restoreGState()
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
