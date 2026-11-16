// Renders the Artemis RGB app icon into an .iconset folder.
// Usage: swift app/make-icon.swift build/AppIcon.iconset && iconutil -c icns build/AppIcon.iconset -o app/AppIcon.icns
import AppKit

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

func rainbow(_ t: CGFloat) -> NSColor {
    NSColor(calibratedHue: (0.98 - t * 0.85).truncatingRemainder(dividingBy: 1), saturation: 0.85, brightness: 1, alpha: 1)
}

/// Draws the icon on a 1024×1024 canvas (macOS icon grid: 824 pt body, 100 pt margin).
func drawIcon(in ctx: CGContext) {
    let S: CGFloat = 1024
    ctx.clear(CGRect(x: 0, y: 0, width: S, height: S))

    // Body with drop shadow
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.45).cgColor)
    ctx.addPath(bodyPath); ctx.setFillColor(NSColor.black.cgColor); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(bodyPath); ctx.clip()
    let bg = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                        colors: [NSColor(calibratedRed: 0.17, green: 0.17, blue: 0.23, alpha: 1).cgColor,
                                 NSColor(calibratedRed: 0.05, green: 0.05, blue: 0.08, alpha: 1).cgColor] as CFArray,
                        locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: 924), end: CGPoint(x: 0, y: 100), options: [])

    // Soft rainbow glow under the keyboard
    for i in 0..<7 {
        let t = CGFloat(i) / 6
        let c = rainbow(t).withAlphaComponent(0.28).cgColor
        let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [c, NSColor.clear.cgColor] as CFArray, locations: [0, 1])!
        let center = CGPoint(x: 230 + t * 564, y: 470)
        ctx.drawRadialGradient(glow, startCenter: center, startRadius: 0, endCenter: center, endRadius: 230, options: [])
    }

    // Keyboard case
    let kb = CGRect(x: 175, y: 330, width: 674, height: 330)
    let kbPath = CGPath(roundedRect: kb, cornerWidth: 48, cornerHeight: 48, transform: nil)
    ctx.addPath(kbPath); ctx.setFillColor(NSColor(calibratedWhite: 0.09, alpha: 1).cgColor); ctx.fillPath()
    ctx.addPath(kbPath); ctx.setStrokeColor(NSColor(calibratedWhite: 1, alpha: 0.10).cgColor); ctx.setLineWidth(4); ctx.strokePath()

    // Keys: 4 rows; each key glows with the colour for its horizontal position
    let pad: CGFloat = 32, gap: CGFloat = 12
    let rows: [[CGFloat]] = [ // key widths in units
        Array(repeating: 1, count: 10),
        [1.5] + Array(repeating: 1, count: 8) + [1.5],
        [1.25, 1, 1, 1, 1, 1, 1, 1, 1, 1.75],
        [1.5, 1, 5.5, 1, 1.5],
    ]
    let innerW = kb.width - pad * 2, innerH = kb.height - pad * 2
    let keyH = (innerH - gap * 3) / 4
    for (r, widths) in rows.enumerated() {
        let units = widths.reduce(0, +)
        let unitW = (innerW - gap * CGFloat(widths.count - 1)) / units
        var x = kb.minX + pad
        let y = kb.maxY - pad - keyH - CGFloat(r) * (keyH + gap)
        for w in widths {
            let rect = CGRect(x: x, y: y, width: unitW * w, height: keyH)
            let t = (rect.midX - kb.minX) / kb.width
            let col = rainbow(t)
            let keyPath = CGPath(roundedRect: rect, cornerWidth: 14, cornerHeight: 14, transform: nil)
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: 22, color: col.withAlphaComponent(0.9).cgColor)
            ctx.addPath(keyPath); ctx.setFillColor(col.withAlphaComponent(0.92).cgColor); ctx.fillPath()
            ctx.restoreGState()
            // Glossy top highlight
            ctx.saveGState()
            ctx.addPath(keyPath); ctx.clip()
            let hl = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                colors: [NSColor(white: 1, alpha: 0.45).cgColor, NSColor(white: 1, alpha: 0).cgColor] as CFArray,
                                locations: [0, 1])!
            ctx.drawLinearGradient(hl, start: CGPoint(x: 0, y: rect.maxY), end: CGPoint(x: 0, y: rect.midY), options: [])
            ctx.restoreGState()
            x += unitW * w + gap
        }
    }

    // Subtle top sheen on the body
    let sheen = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                           colors: [NSColor(white: 1, alpha: 0.10).cgColor, NSColor(white: 1, alpha: 0).cgColor] as CFArray,
                           locations: [0, 1])!
    ctx.drawLinearGradient(sheen, start: CGPoint(x: 0, y: 924), end: CGPoint(x: 0, y: 700), options: [])
    ctx.restoreGState()
}

// Render once at 1024, then downscale for each size.
let master = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8, samplesPerPixel: 4,
                              hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: master)
drawIcon(in: NSGraphicsContext.current!.cgContext)
NSGraphicsContext.restoreGraphicsState()
let masterImage = master.cgImage!

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = base * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        let g = NSGraphicsContext(bitmapImageRep: rep)!
        g.imageInterpolation = .high
        NSGraphicsContext.current = g
        g.cgContext.draw(masterImage, in: CGRect(x: 0, y: 0, width: px, height: px))
        NSGraphicsContext.restoreGraphicsState()
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(outDir)/\(name)"))
    }
}
print("Wrote iconset to \(outDir)")
