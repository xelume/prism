import AppKit

guard CommandLine.arguments.count == 4 else {
    fatalError("Usage: generateIcons <app-logo.svg> <menu-logo.svg> <output-directory>")
}
let appSource = URL(fileURLWithPath: CommandLine.arguments[1])
let menuSource = URL(fileURLWithPath: CommandLine.arguments[2])
let output = URL(fileURLWithPath: CommandLine.arguments[3])
guard let appLogo = NSImage(contentsOf: appSource) else {
    fatalError("Cannot load app SVG logo")
}
guard let menuLogo = NSImage(contentsOf: menuSource) else {
    fatalError("Cannot load menu SVG logo")
}
let iconset = output.appendingPathComponent("appIcon.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func render(_ logo: NSImage, pixels: Int, appIcon: Bool) throws -> NSBitmapImageRep {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
        pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
        let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        fatalError("Cannot allocate icon bitmap")
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    defer { NSGraphicsContext.restoreGraphicsState() }
    context.imageInterpolation = .high
    context.shouldAntialias = true
    let bounds = NSRect(x: 0, y: 0, width: pixels, height: pixels)
    NSColor.clear.setFill()
    bounds.fill(using: .copy)
    var markBounds = bounds
    if appIcon {
        // Keep the original mark on a neutral tile so it remains visible in Finder
        // in either appearance. All dimensions scale from the 1024px icon canvas.
        let scale = CGFloat(pixels) / 1024
        let tile = bounds.insetBy(dx: 64 * scale, dy: 64 * scale)
        NSColor(srgbRed: 0.97, green: 0.97, blue: 0.98, alpha: 1).setFill()
        NSBezierPath(roundedRect: tile, xRadius: 196 * scale, yRadius: 196 * scale).fill()
        markBounds = bounds.insetBy(dx: 112 * scale, dy: 112 * scale)
    }
    logo.draw(in: markBounds, from: .zero, operation: .sourceOver, fraction: 1,
              respectFlipped: false, hints: [.interpolation: NSImageInterpolation.high])
    return bitmap
}

func writePNG(_ bitmap: NSBitmapImageRep, to url: URL) throws {
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        fatalError("Cannot encode icon PNG")
    }
    try data.write(to: url, options: .atomic)
}

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let suffix = scale == 2 ? "@2x" : ""
        try writePNG(render(appLogo, pixels: points * scale, appIcon: true),
            to: iconset.appendingPathComponent("icon_\(points)x\(points)\(suffix).png"))
    }
}
for scale in [1, 2] {
    let suffix = scale == 2 ? "@2x" : ""
    try writePNG(render(menuLogo, pixels: 18 * scale, appIcon: false),
                 to: output.appendingPathComponent("menuIcon\(suffix).png"))
}
try writePNG(render(appLogo, pixels: 256, appIcon: true), to: output.appendingPathComponent("appIconPreview.png"))
print("Generated app icon sizes 16–1024px and dedicated menu template sizes 18/36px")
