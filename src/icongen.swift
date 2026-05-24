import AppKit
import CoreGraphics

let size = 1024
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
guard let ctx = CGContext(
    data: nil, width: size, height: size,
    bitsPerComponent: 8, bytesPerRow: 0, space: cs,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else { fputs("ctx fail\n", stderr); exit(1) }

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
let rect = NSRect(x: 0, y: 0, width: size, height: size)

// Squircle bg
let r: CGFloat = CGFloat(size) * 0.225
let path = NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r)
path.addClip()

// Deep indigo → violet → magenta gradient (vertical)
NSGradient(colors: [
    NSColor(calibratedRed: 0.16, green: 0.12, blue: 0.55, alpha: 1.0), // deep indigo
    NSColor(calibratedRed: 0.36, green: 0.31, blue: 0.92, alpha: 1.0), // indigo
    NSColor(calibratedRed: 0.55, green: 0.36, blue: 0.96, alpha: 1.0), // violet
    NSColor(calibratedRed: 0.84, green: 0.30, blue: 0.78, alpha: 1.0), // magenta
])!.draw(in: rect, angle: -75)

// Soft top-left highlight
NSGradient(colors: [
    NSColor.white.withAlphaComponent(0.28),
    NSColor.white.withAlphaComponent(0.0),
])!.draw(in: rect, relativeCenterPosition: NSPoint(x: -0.5, y: 0.6))

// Cyan rim glow at bottom
NSGradient(colors: [
    NSColor(calibratedRed: 0.18, green: 0.74, blue: 0.91, alpha: 0.45),
    NSColor.clear,
])!.draw(in: rect, relativeCenterPosition: NSPoint(x: 0.0, y: -0.65))

// Hex M mark
let center = NSPoint(x: rect.midX, y: rect.midY)
let hexR: CGFloat = CGFloat(size) * 0.30

func hexPath(center: NSPoint, radius: CGFloat) -> NSBezierPath {
    let p = NSBezierPath()
    for i in 0..<6 {
        let theta = CGFloat(i) * .pi / 3 + .pi / 6
        let pt = NSPoint(x: center.x + radius * cos(theta),
                         y: center.y + radius * sin(theta))
        if i == 0 { p.move(to: pt) } else { p.line(to: pt) }
    }
    p.close()
    return p
}

// Outer hex (frosted glass plate)
let outerHex = hexPath(center: center, radius: hexR + 24)
NSColor.white.withAlphaComponent(0.10).setFill()
outerHex.fill()
NSColor.white.withAlphaComponent(0.35).setStroke()
outerHex.lineWidth = 6
outerHex.stroke()

// Inner hex filled
let hex = hexPath(center: center, radius: hexR)
NSColor.white.withAlphaComponent(0.95).setFill()
hex.fill()

// Big "M" inside the hex
let fontSize: CGFloat = CGFloat(size) * 0.34
let font = NSFont.systemFont(ofSize: fontSize, weight: .black)
let para = NSMutableParagraphStyle(); para.alignment = .center
let attrs: [NSAttributedString.Key: Any] = [
    .font: font,
    .foregroundColor: NSColor(calibratedRed: 0.20, green: 0.10, blue: 0.45, alpha: 1.0),
    .paragraphStyle: para,
    .kern: -2,
]
let s = NSAttributedString(string: "M", attributes: attrs)
let textSize = s.size()
let textRect = NSRect(
    x: center.x - textSize.width / 2,
    y: center.y - textSize.height / 2 - fontSize * 0.06,
    width: textSize.width, height: textSize.height
)
s.draw(in: textRect)

// Two tiny accent dots near the M to suggest "multi-model"
for (dx, color) in [
    (CGFloat(-fontSize) * 0.62, NSColor(calibratedRed: 0.18, green: 0.74, blue: 0.91, alpha: 1.0)),
    (CGFloat(fontSize) * 0.62, NSColor(calibratedRed: 0.99, green: 0.72, blue: 0.20, alpha: 1.0)),
] {
    let dotR = fontSize * 0.10
    let dotRect = NSRect(x: center.x + dx - dotR, y: center.y + fontSize * 0.30 - dotR,
                         width: dotR * 2, height: dotR * 2)
    color.setFill()
    NSBezierPath(ovalIn: dotRect).fill()
}

NSGraphicsContext.restoreGraphicsState()

guard let cg = ctx.makeImage() else { exit(1) }
let rep = NSBitmapImageRep(cgImage: cg)
let png = rep.representation(using: .png, properties: [:])!
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
try png.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
