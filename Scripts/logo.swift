import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Rvrb logo: an eighth note with two echo arcs (reverb), white on the app's purple.
// usage: swift Scripts/logo.swift Rvrb/Assets.xcassets
let assets = URL(fileURLWithPath: CommandLine.arguments[1])

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// Draws the logo into `rect` of `ctx` (origin bottom-left). `rounded`: macOS-style rounded square with margin.
func draw(_ ctx: CGContext, size: CGFloat, rounded: Bool) {
    var body = CGRect(x: 0, y: 0, width: size, height: size)
    if rounded {
        // macOS icon grid: 824/1024 body, centred, with a soft shadow.
        body = body.insetBy(dx: size * 100 / 1024, dy: size * 100 / 1024)
        let path = CGPath(roundedRect: body, cornerWidth: body.width * 0.225, cornerHeight: body.width * 0.225, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -size * 0.01), blur: size * 0.03, color: color(0x000000, 0.3))
        ctx.addPath(path)
        ctx.setFillColor(color(0x6A45DA))
        ctx.fillPath()
        ctx.restoreGState()
        ctx.addPath(path)
        ctx.clip()
    }

    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [color(0xA77BF5), color(0x5B3FD1)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: body.minX, y: body.maxY), end: CGPoint(x: body.maxX, y: body.minY), options: [])

    let w = body.width
    let origin = CGPoint(x: body.minX, y: body.minY)
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: origin.x + w * x, y: origin.y + w * y) }

    ctx.setFillColor(color(0xFFFFFF))
    ctx.setStrokeColor(color(0xFFFFFF))

    // An eighth note: a tilted head, a stem, and a flag.
    let head = p(0.33, 0.33)
    let (a, b, tilt) = (w * 0.115, w * 0.08, CGFloat.pi * 0.16)

    // The stem's outer edge meets the head where the tilted ellipse reaches furthest right, so nothing pokes out.
    let reach = (a * a * cos(tilt) * cos(tilt) + b * b * sin(tilt) * sin(tilt)).squareRoot()
    let reachY = (a * a - b * b) * sin(tilt) * cos(tilt) / reach
    let stemWidth = w * 0.05
    let stemX = head.x + reach - stemWidth
    let stemTop = p(0, 0.78).y
    ctx.fill(CGRect(x: stemX, y: head.y + reachY, width: stemWidth, height: stemTop - head.y - reachY))
    // A rounded top, where the flag starts.
    ctx.fillEllipse(in: CGRect(x: stemX, y: stemTop - stemWidth / 2, width: stemWidth, height: stemWidth))

    ctx.saveGState()
    ctx.translateBy(x: head.x, y: head.y)
    ctx.rotate(by: tilt)
    ctx.fillEllipse(in: CGRect(x: -a, y: -b, width: a * 2, height: b * 2))
    ctx.restoreGState()

    let flag = CGMutablePath()
    flag.move(to: CGPoint(x: stemX + stemWidth / 2, y: stemTop))
    flag.addCurve(to: CGPoint(x: stemX + w * 0.16, y: stemTop - w * 0.27),
                  control1: CGPoint(x: stemX + w * 0.04, y: stemTop - w * 0.10),
                  control2: CGPoint(x: stemX + w * 0.20, y: stemTop - w * 0.12))
    ctx.setLineWidth(w * 0.05)
    ctx.setLineCap(.round)
    ctx.addPath(flag)
    ctx.strokePath()

    // Its echoes, fading out.
    let center = p(0.50, 0.50)
    ctx.setLineWidth(w * 0.055)
    for (radius, alpha) in [(0.22, 0.85), (0.33, 0.5)] {
        ctx.setStrokeColor(color(0xFFFFFF, alpha))
        ctx.addArc(center: center, radius: w * radius, startAngle: -.pi * 0.25, endAngle: .pi * 0.25, clockwise: false)
        ctx.strokePath()
    }
}

func render(_ pixels: Int, rounded: Bool, to url: URL) {
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: rounded ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue)!
    draw(ctx, size: CGFloat(pixels), rounded: rounded)
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    CGImageDestinationFinalize(dest)
}

let iconSet = assets.appendingPathComponent("AppIcon.appiconset")
render(1024, rounded: false, to: iconSet.appendingPathComponent("icon-ios-1024.png"))

var images: [[String: String]] = [["idiom": "universal", "platform": "ios", "size": "1024x1024", "filename": "icon-ios-1024.png"]]
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon-mac-\(points)@\(scale)x.png"
        render(points * scale, rounded: true, to: iconSet.appendingPathComponent(name))
        images.append(["idiom": "mac", "scale": "\(scale)x", "size": "\(points)x\(points)", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try! JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys]).write(to: iconSet.appendingPathComponent("Contents.json"))

// The logo for the login screen: the rounded square, transparent around it.
let logoSet = assets.appendingPathComponent("Logo.imageset")
try! FileManager.default.createDirectory(at: logoSet, withIntermediateDirectories: true)
render(512, rounded: true, to: logoSet.appendingPathComponent("logo.png"))
let logoContents: [String: Any] = ["images": [["idiom": "universal", "filename": "logo.png"]], "info": ["author": "xcode", "version": 1]]
try! JSONSerialization.data(withJSONObject: logoContents, options: [.prettyPrinted, .sortedKeys]).write(to: logoSet.appendingPathComponent("Contents.json"))
print("done")
