import AppKit

// A printed insert for the disk image. Finder supplies the real draggable icons.
let output = CommandLine.arguments.dropFirst().first ?? "dist/installer-background.png"
let size = NSSize(width: 680, height: 420)
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1360, pixelsHigh: 840,
                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                             isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
bitmap.size = size
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
NSColor(calibratedWhite: 0.975, alpha: 1).setFill()
NSRect(origin: .zero, size: size).fill()
let ink = NSColor(calibratedRed: 0.12, green: 0.14, blue: 0.14, alpha: 1)
let muted = NSColor(calibratedWhite: 0.48, alpha: 1)
let accent = NSColor(calibratedRed: 0.92, green: 0.25, blue: 0.08, alpha: 1)
func label(_ text: String, x: CGFloat, top: CGFloat, width: CGFloat, font: NSFont, color: NSColor, centered: Bool = false) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = centered ? .center : .left
    (text as NSString).draw(in: NSRect(x: x, y: size.height - top - 40, width: width, height: 40),
                           withAttributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
}
func line(_ points: [NSPoint], color: NSColor, width: CGFloat) {
    let path = NSBezierPath()
    path.move(to: points[0])
    points.dropFirst().forEach { path.line(to: $0) }
    path.lineWidth = width
    path.lineCapStyle = .round
    color.setStroke()
    path.stroke()
}
label("Side A", x: 36, top: 20, width: 260, font: .systemFont(ofSize: 32, weight: .bold), color: ink)
label("SA–01  /  MAC EDITION", x: 465, top: 32, width: 200, font: .monospacedSystemFont(ofSize: 10, weight: .medium), color: muted)
line([NSPoint(x: 36, y: 328), NSPoint(x: 644, y: 328)], color: .init(calibratedWhite: 0.86, alpha: 1), width: 1)
// A quiet pair of concentric grooves ties the install insert to the physical player.
for radius in [CGFloat(77), 83] {
    let path = NSBezierPath(ovalIn: NSRect(x: 174-radius, y: 210-radius, width: radius*2, height: radius*2))
    NSColor(calibratedWhite: 0.91, alpha: 1).setStroke()
    path.lineWidth = 0.7
    path.stroke()
}
line([NSPoint(x: 314, y: 212), NSPoint(x: 366, y: 212)], color: ink, width: 2.5)
line([NSPoint(x: 355, y: 223), NSPoint(x: 366, y: 212), NSPoint(x: 355, y: 201)], color: accent, width: 2.5)
label("Drag Side A to Applications.", x: 36, top: 310, width: 608, font: .systemFont(ofSize: 20, weight: .medium), color: ink, centered: true)
label("macOS 14+   ·   Apple Silicon + Intel", x: 36, top: 364, width: 608, font: .systemFont(ofSize: 11), color: muted, centered: true)
NSGraphicsContext.restoreGraphicsState()
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
