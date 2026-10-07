import AppKit
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let image = NSImage(size: NSSize(width: 1024, height: 1024), flipped: false) { rect in
    NSColor(calibratedRed: 0.12, green: 0.15, blue: 0.14, alpha: 1).setFill()
    NSBezierPath(roundedRect: rect.insetBy(dx: 30, dy: 30), xRadius: 210, yRadius: 210).fill()
    if let model = NSImage(contentsOf: root.appendingPathComponent("design/discman.png")) {
        model.draw(in: NSRect(x: 20, y: 60, width: 984, height: 895))
    }
    return true
}
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
image.draw(in: NSRect(x: 0, y: 0, width: 1024, height: 1024))
NSGraphicsContext.restoreGraphicsState()
try bitmap.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent("design/icon.png"))
