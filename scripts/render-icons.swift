#!/usr/bin/env swift
// One canonical SVG supplies the app bundle, website logo, and web icons.
import AppKit

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let source = root.appendingPathComponent("Design/oneact-icon-b-spotlight.svg")
let iconset = root.appendingPathComponent("build/icons/OneAct.iconset", isDirectory: true)
let fileManager = FileManager.default

guard let image = NSImage(contentsOf: source) else {
    fatalError("Cannot load the canonical OneAct SVG")
}
try fileManager.createDirectory(at: iconset, withIntermediateDirectories: true)

func png(size: Int) throws -> Data {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
        isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        fatalError("Cannot create an icon bitmap")
    }
    bitmap.size = NSSize(width: size, height: size)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    let rect = NSRect(x: 0, y: 0, width: size, height: size)
    NSColor.clear.setFill()
    rect.fill(using: .copy)
    image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        fatalError("Cannot encode an icon PNG")
    }
    return data
}

for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let suffix = scale == 2 ? "@2x" : ""
        try png(size: size * scale).write(
            to: iconset.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"), options: .atomic
        )
    }
}
let conversion = Process()
conversion.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
conversion.arguments = ["--convert", "icns", iconset.path, "--output", root.appendingPathComponent("AppIcon.icns").path]
try conversion.run()
conversion.waitUntilExit()
guard conversion.terminationStatus == 0 else { fatalError("iconutil failed") }
try Data(contentsOf: source).write(to: root.appendingPathComponent("website/assets/logo.svg"), options: .atomic)
try png(size: 256).write(to: root.appendingPathComponent("website/assets/icon-256.png"), options: .atomic)
print("Rendered AppIcon.icns, website SVG, and 256px web icon from the canonical SVG.")
