import AppKit
import Foundation

private extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            calibratedRed: CGFloat((hex >> 16) & 0xff) / 255,
            green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255,
            alpha: alpha
        )
    }
}

private func stroke(_ path: NSBezierPath, color: NSColor, width: CGFloat) {
    color.setStroke()
    path.lineWidth = width
    path.lineCapStyle = .round
    path.lineJoinStyle = .round
    path.stroke()
}

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: generate-app-icon output.png\n".utf8))
    exit(64)
}

let side = 1024
guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: side,
    pixelsHigh: side,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else { exit(1) }

guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else { exit(1) }
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
NSColor.clear.setFill()
NSRect(x: 0, y: 0, width: side, height: side).fill()

context.cgContext.setShouldAntialias(true)
context.cgContext.setAllowsAntialiasing(true)

let bodyRect = NSRect(x: 72, y: 72, width: 880, height: 880)
let body = NSBezierPath(roundedRect: bodyRect, xRadius: 210, yRadius: 210)
body.addClip()

let baseGradient = NSGradient(
    colorsAndLocations:
        (NSColor(hex: 0x246BFD), 0.0),
        (NSColor(hex: 0x4058E8), 0.48),
        (NSColor(hex: 0x7C3AED), 1.0)
)!
baseGradient.draw(in: body, angle: -35)

let topGlowColors = [
    NSColor(hex: 0x8EEBFF, alpha: 0.34).cgColor,
    NSColor(hex: 0x8EEBFF, alpha: 0.0).cgColor
] as CFArray
guard let topGlow = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: topGlowColors,
    locations: [0.0, 1.0]
) else { exit(1) }
let topGlowCenter = CGPoint(x: 390, y: 790)
context.cgContext.drawRadialGradient(
    topGlow,
    startCenter: topGlowCenter,
    startRadius: 0,
    endCenter: topGlowCenter,
    endRadius: 500,
    options: []
)

let lowerShade = NSGradient(
    colorsAndLocations:
        (NSColor(hex: 0x071A46, alpha: 0.0), 0.0),
        (NSColor(hex: 0x071A46, alpha: 0.38), 1.0)
)!
lowerShade.draw(in: NSRect(x: 72, y: 72, width: 880, height: 390), angle: -90)

let lightPoints: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
    (230.0, 690.0, 5.0, 0.18),
    (805.0, 650.0, 4.0, 0.14),
    (790.0, 315.0, 5.0, 0.12),
    (250.0, 340.0, 3.0, 0.10)
]
for (x, y, radius, alpha) in lightPoints {
    NSColor(hex: 0xBDF5FF, alpha: alpha).setFill()
    NSBezierPath(
        ovalIn: NSRect(
            x: x - radius,
            y: y - radius,
            width: radius * 2,
            height: radius * 2
        )
    ).fill()
}

NSGraphicsContext.restoreGraphicsState()
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context

stroke(body, color: NSColor(hex: 0x071A46, alpha: 0.42), width: 16)
let innerBorder = NSBezierPath(
    roundedRect: bodyRect.insetBy(dx: 14, dy: 14),
    xRadius: 196,
    yRadius: 196
)
stroke(innerBorder, color: NSColor.white.withAlphaComponent(0.14), width: 5)

let ringGlow = NSBezierPath()
ringGlow.appendArc(
    withCenter: NSPoint(x: 512, y: 490),
    radius: 232,
    startAngle: 130,
    endAngle: 410,
    clockwise: false
)
stroke(ringGlow, color: NSColor(hex: 0x8EEBFF, alpha: 0.28), width: 86)

let ring = NSBezierPath()
ring.appendArc(
    withCenter: NSPoint(x: 512, y: 490),
    radius: 232,
    startAngle: 130,
    endAngle: 410,
    clockwise: false
)
stroke(ring, color: .white, width: 66)

let powerStemGlow = NSBezierPath()
powerStemGlow.move(to: NSPoint(x: 512, y: 742))
powerStemGlow.line(to: NSPoint(x: 512, y: 558))
stroke(powerStemGlow, color: NSColor(hex: 0x8EEBFF, alpha: 0.28), width: 86)

let powerStem = NSBezierPath()
powerStem.move(to: NSPoint(x: 512, y: 742))
powerStem.line(to: NSPoint(x: 512, y: 558))
stroke(powerStem, color: .white, width: 66)

let chevronGlow = NSBezierPath()
chevronGlow.move(to: NSPoint(x: 455, y: 575))
chevronGlow.line(to: NSPoint(x: 610, y: 490))
chevronGlow.line(to: NSPoint(x: 455, y: 405))
stroke(chevronGlow, color: NSColor(hex: 0x8EEBFF, alpha: 0.28), width: 82)

let chevron = NSBezierPath()
chevron.move(to: NSPoint(x: 455, y: 575))
chevron.line(to: NSPoint(x: 610, y: 490))
chevron.line(to: NSPoint(x: 455, y: 405))
stroke(chevron, color: .white, width: 62)

NSGraphicsContext.restoreGraphicsState()
guard let png = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic)
