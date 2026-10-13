import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Rvrb logo: a sound source with three echo arcs (reverb), white on the app's purple.
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
    let center = CGPoint(x: body.minX + w * 0.30, y: body.midY)

    // The source.
    ctx.setFillColor(color(0xFFFFFF))
    let dot = w * 0.08
    ctx.fillEllipse(in: CGRect(x: center.x - dot, y: center.y - dot, width: dot * 2, height: dot * 2))

    // The echoes, fading out.
    ctx.setLineCap(.round)
    ctx.setLineWidth(w * 0.06)
    for (radius, alpha) in [(0.19, 1.0), (0.30, 0.72), (0.41, 0.45)] {
        ctx.setStrokeColor(color(0xFFFFFF, alpha))
        ctx.addArc(center: center, radius: w * radius, startAngle: -.pi * 0.27, endAngle: .pi * 0.27, clockwise: false)
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
