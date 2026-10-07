// Renders Resources/AppIcon.icns: a dark rounded tile with a spectrum trace over a waterfall.
import AppKit

func render(_ size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024
    let tile = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let path = NSBezierPath(roundedRect: tile, xRadius: 185 * s, yRadius: 185 * s)
    path.addClip()
    NSGradient(colors: [NSColor(red: 0.02, green: 0.04, blue: 0.10, alpha: 1), NSColor(red: 0.06, green: 0.12, blue: 0.24, alpha: 1)])!
        .draw(in: tile, angle: 90)
    // Waterfall band.
    for row in 0..<28 {
        for col in 0..<60 {
            let x = Double(col) / 59, y = Double(row) / 27
            let peak = exp(-pow((x - 0.5) / 0.06, 2)) + 0.6 * exp(-pow((x - 0.25) / 0.03, 2)) * (sin(y * 9) > 0 ? 1 : 0.2)
                + 0.5 * exp(-pow((x - 0.78) / 0.04, 2))
            let v = min(1, 0.15 + peak + Double.random(in: 0...0.12))
            NSColor(hue: 0.62 - 0.5 * v, saturation: 0.9, brightness: 0.25 + 0.75 * v, alpha: 1).setFill()
            NSRect(x: tile.minX + CGFloat(x) * tile.width, y: tile.minY + CGFloat(y) * 300 * s, width: tile.width / 59 + 1, height: 300 * s / 27 + 1).fill()
        }
    }
    // Spectrum trace.
    let trace = NSBezierPath()
    for i in 0...200 {
        let x = Double(i) / 200
        let v = 0.12 + 0.75 * exp(-pow((x - 0.5) / 0.05, 2)) + 0.45 * exp(-pow((x - 0.25) / 0.02, 2))
            + 0.35 * exp(-pow((x - 0.78) / 0.03, 2)) + 0.03 * sin(x * 140)
        let p = NSPoint(x: tile.minX + CGFloat(x) * tile.width, y: tile.minY + 360 * s + CGFloat(v) * 420 * s)
        i == 0 ? trace.move(to: p) : trace.line(to: p)
    }
    let fill = trace.copy() as! NSBezierPath
    fill.line(to: NSPoint(x: tile.maxX, y: tile.minY + 300 * s))
    fill.line(to: NSPoint(x: tile.minX, y: tile.minY + 300 * s))
    fill.close()
    NSColor(red: 0.2, green: 0.6, blue: 1, alpha: 0.35).setFill()
    fill.fill()
    NSColor(red: 0.85, green: 0.95, blue: 1, alpha: 1).setStroke()
    trace.lineWidth = 14 * s
    trace.lineJoinStyle = .round
    trace.stroke()
    // VFO marker.
    NSColor(red: 1, green: 0.3, blue: 0.25, alpha: 1).setFill()
    NSRect(x: tile.midX - 6 * s, y: tile.minY, width: 12 * s, height: tile.height).fill()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let out = CommandLine.arguments[1]
let iconset = out + ".iconset"
try? FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = CGFloat(base * scale)
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try! render(px).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(iconset)/\(name)"))
    }
}
