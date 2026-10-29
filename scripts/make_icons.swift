#!/usr/bin/env swift
// Regenerates the Local Grammar artwork from code.
//
//   swift scripts/make_icons.swift
//
// Outputs (next to this script):
//   AppIcon.icns                 macOS app icon (16 ... 1024, incl. @2x), built with iconutil
//   Logo.png                     512x512 artwork, transparent outside the squircle
//   MenuBarIcon.png / @2x.png    18x18 / 36x36 black-on-transparent template glyph
//
// The intermediate .iconset is left in $TMPDIR/LocalGrammar.iconset for previewing.
//
// Design: Big Sur style squircle with an indigo -> violet gradient, a white
// serif lowercase "a" and a rose -> amber hand-drawn spelling squiggle that resolves
// into a checkmark ("your writing, corrected, on this Mac").

import AppKit
import CoreText
import Foundation

// MARK: - Geometry helpers (design space is 1024 x 1024, origin bottom-left)

/// Rounded square with continuous ("squircle") corners. Each corner is a
/// superellipse quadrant that meets the straight edges with zero curvature, so
/// the outline is curvature-continuous like Apple's icon shape.
func squirclePath(_ rect: CGRect, radius r: CGFloat) -> CGPath {
    let e = min(r * 1.528, min(rect.width, rect.height) / 2) // corner extent
    let n: CGFloat = 3.3                                    // superellipse exponent
    let steps = 48
    let path = CGMutablePath()
    // Corner centres, walked counter-clockwise starting at bottom-right.
    let corners: [(CGPoint, CGFloat)] = [
        (CGPoint(x: rect.maxX - e, y: rect.minY + e), -.pi / 2),
        (CGPoint(x: rect.maxX - e, y: rect.maxY - e), 0),
        (CGPoint(x: rect.minX + e, y: rect.maxY - e), .pi / 2),
        (CGPoint(x: rect.minX + e, y: rect.minY + e), .pi),
    ]
    for (i, (c, start)) in corners.enumerated() {
        for s in 0...steps {
            let t = start + (CGFloat(s) / CGFloat(steps)) * (.pi / 2)
            let ct = cos(t), st = sin(t)
            let x = c.x + e * copysign(pow(abs(ct), 2 / n), ct)
            let y = c.y + e * copysign(pow(abs(st), 2 / n), st)
            if i == 0 && s == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
        }
    }
    path.closeSubpath()
    return path
}

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

func gradient(_ colors: [CGColor], _ locations: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
               colors: colors as CFArray, locations: locations)!
}

/// Outline of a lowercase "a" in a system font design (New York serif or SF
/// Rounded), scaled so its ink box has height `height` and its bottom-left
/// sits at `origin`.
func glyphA(height: CGFloat, origin: CGPoint, design: NSFontDescriptor.SystemDesign,
            weight: NSFont.Weight) -> CGPath {
    var font = NSFont.systemFont(ofSize: 100, weight: weight)
    if let d = font.fontDescriptor.withDesign(design) { font = NSFont(descriptor: d, size: 100) ?? font }
    let ctFont = font as CTFont
    var ch: UniChar = 0x61 // "a"
    var glyph: CGGlyph = 0
    CTFontGetGlyphsForCharacters(ctFont, &ch, &glyph, 1)
    let raw = CTFontCreatePathForGlyph(ctFont, glyph, nil)!
    let box = raw.boundingBoxOfPath
    let k = height / box.height
    var t = CGAffineTransform(translationX: origin.x, y: origin.y)
        .scaledBy(x: k, y: k)
        .translatedBy(x: -box.minX, y: -box.minY)
    return raw.copy(using: &t)!
}

/// Hand-drawn spelling squiggle that ends in a checkmark. `start` is the left
/// end of the wave's centre line; the check's vertex sits below the baseline.
func squiggleCheck(start: CGPoint, waveLength: CGFloat, amplitude: CGFloat, waves: CGFloat,
                   vertex: CGPoint, tip: CGPoint) -> CGPath {
    let path = CGMutablePath()
    path.move(to: start)
    let steps = 120
    let span = waveLength * waves
    var last = start
    for s in 1...steps {
        let u = CGFloat(s) / CGFloat(steps)
        let x = start.x + span * u
        let y = start.y + amplitude * sin(u * waves * 2 * .pi)
        last = CGPoint(x: x, y: y)
        path.addLine(to: last)
    }
    // The wave's last downswing flows into the short arm of the check.
    let mid = CGPoint(x: (last.x + vertex.x) / 2, y: (last.y + vertex.y) / 2)
    path.addQuadCurve(to: vertex, control: CGPoint(x: mid.x + 6, y: mid.y + 4))
    path.addLine(to: tip)
    return path
}

// MARK: - Artwork

enum Layout {
    static let canvas: CGFloat = 1024
    static let body = CGRect(x: 100, y: 100, width: 824, height: 824)  // Apple macOS icon grid
    static let cornerRadius: CGFloat = 185.4                          // 22.5% of 824
}

/// The logo mark: a white "a" over a squiggle that resolves into a check.
/// `.detailed` is the hero artwork (New York serif "a", fine squiggle);
/// `.compact` is hand-tuned for tiny renditions (16/32 px and the menu bar):
/// a heavier rounded "a", fewer and larger waves, thicker stroke.
enum MarkStyle { case detailed, compact }

struct Mark {
    let a: CGPath
    let squiggle: CGPath   // stroked outline, ready to fill

    init(_ style: MarkStyle) {
        let centre: CGPath
        let width: CGFloat
        switch style {
        case .detailed:
            a = glyphA(height: 380, origin: CGPoint(x: 302, y: 428), design: .serif, weight: .bold)
            centre = squiggleCheck(start: CGPoint(x: 252, y: 324), waveLength: 104, amplitude: 22, waves: 2.25,
                                   vertex: CGPoint(x: 600, y: 250), tip: CGPoint(x: 782, y: 470))
            width = 58
        case .compact:
            a = glyphA(height: 390, origin: CGPoint(x: 290, y: 466), design: .rounded, weight: .heavy)
            centre = squiggleCheck(start: CGPoint(x: 250, y: 314), waveLength: 150, amplitude: 30, waves: 1.25,
                                   vertex: CGPoint(x: 600, y: 222), tip: CGPoint(x: 790, y: 480))
            width = 84
        }
        squiggle = centre.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 10)
    }
}

func drawAppIcon(in ctx: CGContext, style: MarkStyle, tileShadow: Bool) {
    let body = Layout.body
    let shape = squirclePath(body, radius: Layout.cornerRadius)

    // Soft drop shadow beneath the tile (app icon only; Logo.png stays clean).
    if tileShadow {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 22, color: rgb(0x000000, 0.35))
        ctx.addPath(shape)
        ctx.setFillColor(rgb(0x2A1F7A))
        ctx.fillPath()
        ctx.restoreGState()
    }

    // Background: violet (top-left) -> deep indigo (bottom-right).
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    ctx.drawLinearGradient(gradient([rgb(0x8A5CF6), rgb(0x5B3FE0), rgb(0x23196B)], [0, 0.45, 1]),
                           start: CGPoint(x: body.minX, y: body.maxY),
                           end: CGPoint(x: body.maxX, y: body.minY), options: [])
    // Gentle top glow for depth.
    ctx.drawRadialGradient(gradient([rgb(0xFFFFFF, 0.22), rgb(0xFFFFFF, 0)], [0, 1]),
                           startCenter: CGPoint(x: 400, y: 930), startRadius: 0,
                           endCenter: CGPoint(x: 400, y: 930), endRadius: 620, options: [])
    ctx.restoreGState()

    let mark = Mark(style)

    // White "a" with a soft indigo shadow so it lifts off the tile.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0x140C45, 0.45))
    ctx.addPath(mark.a)
    ctx.setFillColor(rgb(0xFFFFFF))
    ctx.fillPath()
    ctx.restoreGState()

    // Squiggle -> check: rose "spelling error" red warming to an amber check.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: rgb(0x140C45, 0.5))
    ctx.addPath(mark.squiggle)
    ctx.setFillColor(rgb(0xFF7A59))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(mark.squiggle)
    ctx.clip()
    let sb = mark.squiggle.boundingBoxOfPath
    ctx.drawLinearGradient(gradient([rgb(0xFF4F7B), rgb(0xFF7A5C), rgb(0xFFB547)], [0, 0.55, 1]),
                           start: CGPoint(x: sb.minX, y: sb.minY), end: CGPoint(x: sb.maxX, y: sb.maxY),
                           options: [])
    ctx.restoreGState()

    // Hairline inner rim to crisp up the edge.
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    ctx.addPath(shape)
    ctx.setLineWidth(4)
    ctx.setStrokeColor(rgb(0xFFFFFF, 0.14))
    ctx.strokePath()
    ctx.restoreGState()
}

/// Monochrome template glyph: the compact mark ("a" + squiggle-check),
/// cropped to its ink and filled black so macOS can tint it.
func drawMenuBarGlyph(in ctx: CGContext, size: CGFloat) {
    let mark = Mark(.compact)
    let box = mark.a.boundingBoxOfPath.union(mark.squiggle.boundingBoxOfPath)
    let inset = size * 0.02
    let k = (size - 2 * inset) / max(box.width, box.height)
    ctx.translateBy(x: size / 2, y: size / 2)
    ctx.scaleBy(x: k, y: k)
    ctx.translateBy(x: -box.midX, y: -box.midY)
    ctx.setFillColor(rgb(0x000000))
    ctx.addPath(mark.a)
    ctx.fillPath()
    ctx.addPath(mark.squiggle)
    ctx.fillPath()
}

// MARK: - Rendering

func render(pixels: Int, _ draw: (CGContext) -> Void) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    ctx.clear(CGRect(x: 0, y: 0, width: pixels, height: pixels))
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high
    draw(ctx)
    return rep.representation(using: .png, properties: [:])!
}

func renderAppIcon(pixels: Int, tileShadow: Bool = true) -> Data {
    render(pixels: pixels) { ctx in
        let k = CGFloat(pixels) / Layout.canvas
        ctx.scaleBy(x: k, y: k)
        drawAppIcon(in: ctx, style: pixels <= 32 ? .compact : .detailed, tileShadow: tileShadow)
    }
}

let outDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("app/Resources")
let fm = FileManager.default

let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("LocalGrammar.iconset")
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)

for points in [16, 32, 128, 256, 512] {
    try renderAppIcon(pixels: points).write(to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    try renderAppIcon(pixels: points * 2).write(to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", outDir.appendingPathComponent("AppIcon.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }

try renderAppIcon(pixels: 512, tileShadow: false).write(to: outDir.appendingPathComponent("Logo.png"))
try render(pixels: 18) { drawMenuBarGlyph(in: $0, size: 18) }
    .write(to: outDir.appendingPathComponent("MenuBarIcon.png"))
try render(pixels: 36) { drawMenuBarGlyph(in: $0, size: 36) }
    .write(to: outDir.appendingPathComponent("MenuBarIcon@2x.png"))

print("Wrote AppIcon.icns, Logo.png, MenuBarIcon.png, MenuBarIcon@2x.png to \(outDir.path)")
print("Preview iconset: \(iconset.path)")
