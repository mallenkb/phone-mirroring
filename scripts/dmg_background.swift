#!/usr/bin/env swift
import AppKit

// Renders the PhoneRelay DMG installer background. The app and Applications
// icons are placed by Finder on top of this image (see make_dmg.sh), so they
// are intentionally NOT drawn here. Output is 1440×880 px (a 720×440 pt window
// @2x). Usage: swift dmg_background.swift /path/to/background.png

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "background.png"

let S: CGFloat = 2                 // @2x
let W: CGFloat = 720 * S
let H: CGFloat = 440 * S
func P(_ v: CGFloat) -> CGFloat { v * S }          // points -> px
func topY(_ t: CGFloat) -> CGFloat { H - t * S }   // top-origin pt -> bottom-origin px

func hex(_ s: String, _ a: CGFloat = 1) -> NSColor {
    var h = s; if h.hasPrefix("#") { h.removeFirst() }
    let n = Int(h, radix: 16) ?? 0
    return NSColor(srgbRed: CGFloat((n >> 16) & 0xff) / 255,
                   green: CGFloat((n >> 8) & 0xff) / 255,
                   blue: CGFloat(n & 0xff) / 255, alpha: a)
}

func rectFromTop(_ x: CGFloat, _ topPt: CGFloat, _ w: CGFloat, _ hPt: CGFloat) -> NSRect {
    NSRect(x: P(x), y: topY(topPt + hPt), width: P(w), height: P(hPt))
}

func roundedRect(_ x: CGFloat, _ topPt: CGFloat, _ w: CGFloat, _ hPt: CGFloat, _ r: CGFloat) -> NSBezierPath {
    let rect = rectFromTop(x, topPt, w, hPt)
    return NSBezierPath(roundedRect: rect, xRadius: P(r), yRadius: P(r))
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W), pixelsHigh: Int(H),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

// Soft cyan installer wallpaper.
let g = NSGradient(colors: [hex("#e8fbff"), hex("#d8f7fb"), hex("#bdeff5")],
                   atLocations: [0, 0.58, 1], colorSpace: .sRGB)!
g.draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: 0)

hex("#8eddea", 0.44).setFill()
NSBezierPath(rect: rectFromTop(528, 0, 192, 440)).fill()

let lowerBlob = NSBezierPath(roundedRect: rectFromTop(-70, 330, 540, 184), xRadius: P(52), yRadius: P(52))
hex("#80dce9", 0.58).setFill()
lowerBlob.fill()

for y in [214, 298, 388] as [CGFloat] {
    let line = NSBezierPath()
    line.lineWidth = P(1.4)
    line.move(to: NSPoint(x: P(-40), y: topY(y)))
    line.curve(to: NSPoint(x: P(760), y: topY(y + 18)),
               controlPoint1: NSPoint(x: P(160), y: topY(y - 34)),
               controlPoint2: NSPoint(x: P(430), y: topY(y + 58)))
    hex("#ffffff", 0.40).setStroke()
    line.stroke()
}

// Pill header.
let pillText = "Drag and open from Applications"
let pillFont = NSFont.systemFont(ofSize: P(15), weight: .semibold)
let pillAttrs: [NSAttributedString.Key: Any] = [.font: pillFont, .foregroundColor: hex("#083344")]
let pillSize = (pillText as NSString).size(withAttributes: pillAttrs)
let pillW = pillSize.width + P(36), pillH = P(38)
let pillX = (W - pillW) / 2
let pillRect = rectFromTop((pillX / S), 56, pillW / S, pillH / S)
let pillPath = NSBezierPath(roundedRect: pillRect, xRadius: pillH / 2, yRadius: pillH / 2)
hex("#ffffff", 0.55).setFill(); pillPath.fill()
hex("#ffffff", 0.7).setStroke(); pillPath.lineWidth = P(1); pillPath.stroke()
(pillText as NSString).draw(at: NSPoint(x: pillX + P(18), y: pillRect.midY - pillSize.height / 2), withAttributes: pillAttrs)

// Frosted card.
let card = roundedRect(92, 122, 536, 264, 26)
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: P(24), color: hex("#0e7490", 0.35).cgColor)
hex("#ffffff", 0.30).setFill(); card.fill()
ctx.restoreGState()
hex("#ffffff", 0.55).setStroke(); card.lineWidth = P(1.5); card.stroke()

// Chevrons (>>>), centered between the two large icon slots.
hex("#164e63", 0.96).setStroke()
let cy: CGFloat = 222
for cx in [336, 362, 388] as [CGFloat] {
    let p = NSBezierPath(); p.lineWidth = P(3.4); p.lineCapStyle = .round; p.lineJoinStyle = .round
    p.move(to: NSPoint(x: P(cx - 8), y: topY(cy - 10)))
    p.line(to: NSPoint(x: P(cx + 8), y: topY(cy)))
    p.line(to: NSPoint(x: P(cx - 8), y: topY(cy + 10)))
    p.stroke()
}

NSGraphicsContext.restoreGraphicsState()

// Stamp the rep as @2x (720×440 pt for 1440×880 px) after drawing. Setting it
// before drawing changes AppKit's user-space scale and double-applies our P().
rep.size = NSSize(width: W / S, height: H / S)

guard let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("Failed to encode PNG\n".utf8)); exit(1)
}
do {
    try png.write(to: URL(fileURLWithPath: outPath))
    print("Wrote \(outPath)")
} catch {
    FileHandle.standardError.write(Data("Failed to write \(outPath): \(error)\n".utf8)); exit(1)
}
