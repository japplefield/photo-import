// Draws the 1024×1024 app icon: a stack of photos on a blue tile, with a green "import" badge.
// Usage: swift scripts/make-icon.swift <output.png>
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func linear(_ colors: [CGColor], from: CGPoint, to: CGPoint) {
    let gradient = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: nil)!
    ctx.drawLinearGradient(gradient, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

// Tile, on Apple's macOS icon grid (824pt body inside the 1024 canvas), with a soft drop shadow.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let bodyPath = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0x000000, 0.35))
ctx.addPath(bodyPath)
ctx.setFillColor(rgb(0x2F6BE0))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(bodyPath)
ctx.clip()
linear([rgb(0x5AB8FF), rgb(0x2A62DB), rgb(0x1C3FA8)], from: CGPoint(x: 512, y: 924), to: CGPoint(x: 512, y: 100))
// Subtle top highlight.
linear([rgb(0xFFFFFF, 0.18), rgb(0xFFFFFF, 0)], from: CGPoint(x: 512, y: 924), to: CGPoint(x: 512, y: 600))
ctx.restoreGState()

// One photo print: white border around an image area.
func card(center: CGPoint, angle: CGFloat, drawImage: (CGRect) -> Void) {
    let w: CGFloat = 500, h: CGFloat = 390, border: CGFloat = 24
    ctx.saveGState()
    ctx.translateBy(x: center.x, y: center.y)
    ctx.rotate(by: angle * .pi / 180)
    let outer = CGRect(x: -w / 2, y: -h / 2, width: w, height: h)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 26, color: rgb(0x0A1B4D, 0.45))
    ctx.addPath(CGPath(roundedRect: outer, cornerWidth: 34, cornerHeight: 34, transform: nil))
    ctx.setFillColor(rgb(0xFFFFFF))
    ctx.fillPath()
    ctx.restoreGState()
    let inner = outer.insetBy(dx: border, dy: border)
    ctx.addPath(CGPath(roundedRect: inner, cornerWidth: 16, cornerHeight: 16, transform: nil))
    ctx.clip()
    drawImage(inner)
    ctx.restoreGState()
}

func scene(_ r: CGRect, sky: [UInt32], hills: (UInt32, UInt32), sun: UInt32?) {
    linear(sky.map { rgb($0) }, from: CGPoint(x: r.midX, y: r.maxY), to: CGPoint(x: r.midX, y: r.minY))
    if let sun {
        ctx.setFillColor(rgb(sun))
        ctx.fillEllipse(in: CGRect(x: r.minX + r.width * 0.62, y: r.minY + r.height * 0.55, width: 86, height: 86))
    }
    let back = CGMutablePath()
    back.move(to: CGPoint(x: r.minX, y: r.minY))
    back.addLine(to: CGPoint(x: r.minX, y: r.minY + r.height * 0.35))
    back.addLine(to: CGPoint(x: r.minX + r.width * 0.30, y: r.minY + r.height * 0.68))
    back.addLine(to: CGPoint(x: r.minX + r.width * 0.58, y: r.minY + r.height * 0.30))
    back.addLine(to: CGPoint(x: r.maxX, y: r.minY + r.height * 0.52))
    back.addLine(to: CGPoint(x: r.maxX, y: r.minY))
    back.closeSubpath()
    ctx.addPath(back)
    ctx.setFillColor(rgb(hills.0))
    ctx.fillPath()
    let front = CGMutablePath()
    front.move(to: CGPoint(x: r.minX, y: r.minY))
    front.addLine(to: CGPoint(x: r.minX, y: r.minY + r.height * 0.18))
    front.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY + r.height * 0.22),
                       control: CGPoint(x: r.minX + r.width * 0.55, y: r.minY + r.height * 0.45))
    front.addLine(to: CGPoint(x: r.maxX, y: r.minY))
    front.closeSubpath()
    ctx.addPath(front)
    ctx.setFillColor(rgb(hills.1))
    ctx.fillPath()
}

// A burst of similar shots: two prints fanned behind the front one.
card(center: CGPoint(x: 492, y: 560), angle: 13) { r in
    scene(r, sky: [0xB9D7F5, 0xDDEBFA], hills: (0x8FB3C9, 0x6F97B0), sun: nil)
}
card(center: CGPoint(x: 520, y: 540), angle: -9) { r in
    scene(r, sky: [0xFFD9A8, 0xFFE9CF], hills: (0x7FA9A0, 0x5E8C83), sun: 0xFFF3DC)
}
card(center: CGPoint(x: 505, y: 500), angle: 0) { r in
    scene(r, sky: [0xFF9F6E, 0xFFC978, 0xFFE3A3], hills: (0x2F8C7A, 0x1E6457), sun: 0xFFF6D6)
}

// Import badge: green circle with a down arrow.
let badgeCenter = CGPoint(x: 742, y: 292)
let badgeRadius: CGFloat = 118
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 20, color: rgb(0x0A1B4D, 0.45))
ctx.setFillColor(rgb(0xFFFFFF))
ctx.fillEllipse(in: CGRect(x: badgeCenter.x - badgeRadius - 14, y: badgeCenter.y - badgeRadius - 14,
                           width: 2 * (badgeRadius + 14), height: 2 * (badgeRadius + 14)))
ctx.restoreGState()
ctx.saveGState()
ctx.addEllipse(in: CGRect(x: badgeCenter.x - badgeRadius, y: badgeCenter.y - badgeRadius,
                          width: 2 * badgeRadius, height: 2 * badgeRadius))
ctx.clip()
linear([rgb(0x5BE07A), rgb(0x26A847)], from: CGPoint(x: badgeCenter.x, y: badgeCenter.y + badgeRadius),
       to: CGPoint(x: badgeCenter.x, y: badgeCenter.y - badgeRadius))
ctx.restoreGState()
ctx.setStrokeColor(rgb(0xFFFFFF))
ctx.setLineWidth(30)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)
ctx.move(to: CGPoint(x: badgeCenter.x, y: badgeCenter.y + 62))
ctx.addLine(to: CGPoint(x: badgeCenter.x, y: badgeCenter.y - 58))
ctx.move(to: CGPoint(x: badgeCenter.x - 52, y: badgeCenter.y - 6))
ctx.addLine(to: CGPoint(x: badgeCenter.x, y: badgeCenter.y - 58))
ctx.addLine(to: CGPoint(x: badgeCenter.x + 52, y: badgeCenter.y - 6))
ctx.strokePath()

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png")
let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
guard CGImageDestinationFinalize(dest) else { fatalError("couldn't write \(out.path)") }
print("Wrote \(out.path)")
