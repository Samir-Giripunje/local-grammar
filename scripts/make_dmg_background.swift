import AppKit

// Renders the DMG window background: usage: make_dmg_background.swift <output.png> <scale>
let outputPath = CommandLine.arguments[1]
let scale = CGFloat(Double(CommandLine.arguments[2]) ?? 1)
let size = NSSize(width: 660, height: 400)

let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(size.width * scale),
    pixelsHigh: Int(size.height * scale),
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
)!
bitmap.size = size

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)

NSGradient(colors: [
    NSColor(calibratedRed: 0.97, green: 0.97, blue: 1.0, alpha: 1),
    NSColor(calibratedRed: 0.90, green: 0.92, blue: 0.99, alpha: 1),
])!.draw(in: NSRect(origin: .zero, size: size), angle: -90)

let accent = NSColor(calibratedRed: 0.36, green: 0.35, blue: 0.95, alpha: 0.85)
let arrow = NSBezierPath()
arrow.move(to: NSPoint(x: 268, y: 210))
arrow.line(to: NSPoint(x: 380, y: 210))
arrow.lineWidth = 6
arrow.lineCapStyle = .round
accent.setStroke()
arrow.stroke()
let head = NSBezierPath()
head.move(to: NSPoint(x: 396, y: 210))
head.line(to: NSPoint(x: 374, y: 226))
head.line(to: NSPoint(x: 374, y: 194))
head.close()
accent.setFill()
head.fill()

let paragraph = NSMutableParagraphStyle()
paragraph.alignment = .center
let title: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 20, weight: .semibold),
    .foregroundColor: NSColor(calibratedWhite: 0.15, alpha: 1),
    .paragraphStyle: paragraph,
]
let caption: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 13),
    .foregroundColor: NSColor(calibratedWhite: 0.35, alpha: 1),
    .paragraphStyle: paragraph,
]
"Drag Local Grammar into Applications".draw(in: NSRect(x: 0, y: 330, width: size.width, height: 30), withAttributes: title)
"Then open it, select some text anywhere and press ⌥⌘G.".draw(in: NSRect(x: 0, y: 64, width: size.width, height: 20), withAttributes: caption)

NSGraphicsContext.restoreGraphicsState()
try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: outputPath))
