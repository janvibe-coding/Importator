// Draws Importator's app icon (Ratingmator's, with a downward arrow for the star) and writes every size into the AppIcon set.
// Run from the project folder: swift tools/make_icon.swift
import AppKit
import CoreGraphics

let size = 1024
let space = CGColorSpace(name: CGColorSpace.sRGB)!

func newContext(_ side: Int) -> CGContext {
    let context = CGContext(
        data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.interpolationQuality = .high
    return context
}

/// A downward arrow: a shaft on top, a wide head below, every corner rounded. y runs upward.
func arrowPath() -> CGPath {
    let points: [(CGPoint, CGFloat)] = [
        (CGPoint(x: 372, y: 850), 34),  // shaft, top left
        (CGPoint(x: 652, y: 850), 34),  // shaft, top right
        (CGPoint(x: 652, y: 500), 18),  // shaft meets head, right
        (CGPoint(x: 842, y: 500), 40),  // head, right
        (CGPoint(x: 512, y: 168), 52),  // tip
        (CGPoint(x: 182, y: 500), 40),  // head, left
        (CGPoint(x: 372, y: 500), 18),  // shaft meets head, left
    ]
    let path = CGMutablePath()
    let first = points[0].0, last = points[points.count - 1].0
    path.move(to: CGPoint(x: (first.x + last.x) / 2, y: (first.y + last.y) / 2))
    for index in 0..<points.count {
        let next = points[(index + 1) % points.count].0
        path.addArc(tangent1End: points[index].0, tangent2End: next, radius: points[index].1)
    }
    path.closeSubpath()
    return path
}

/// The colour field: yellow on top, orange and red in the middle, purple and blue below, green on the right.
/// Every pixel blends these points by distance. x and y run from 0 to 1, with y downward.
let stops: [(x: Double, y: Double, r: Double, g: Double, b: Double)] = [
    (0.50, 0.22, 1.00, 0.82, 0.00),
    (0.70, 0.27, 1.00, 0.62, 0.00),
    (0.27, 0.35, 1.00, 0.50, 0.00),
    (0.48, 0.47, 0.96, 0.30, 0.00),
    (0.20, 0.50, 0.92, 0.08, 0.20),
    (0.33, 0.66, 0.60, 0.03, 0.26),
    (0.50, 0.72, 0.36, 0.14, 0.38),
    (0.47, 0.88, 0.14, 0.20, 0.52),
    (0.68, 0.84, 0.00, 0.30, 0.52),
    (0.76, 0.66, 0.00, 0.42, 0.42),
    (0.84, 0.45, 0.36, 0.56, 0.22),
    (0.80, 0.33, 0.78, 0.62, 0.02),
]

func colourField() -> CGImage {
    let side = size
    var pixels = [UInt8](repeating: 255, count: side * side * 4)
    for row in 0..<side {
        let y = Double(row) / Double(side)
        for column in 0..<side {
            let x = Double(column) / Double(side)
            var r = 0.0, g = 0.0, b = 0.0, total = 0.0
            for stop in stops {
                let dx = x - stop.x, dy = y - stop.y
                let weight = 1 / pow(dx * dx + dy * dy + 0.0015, 2.0)
                r += stop.r * weight
                g += stop.g * weight
                b += stop.b * weight
                total += weight
            }
            let offset = (row * side + column) * 4
            pixels[offset] = UInt8(min(255, r / total * 255))
            pixels[offset + 1] = UInt8(min(255, g / total * 255))
            pixels[offset + 2] = UInt8(min(255, b / total * 255))
        }
    }
    let provider = CGDataProvider(data: Data(pixels) as CFData)!
    return CGImage(
        width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4, space: space,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider,
        decode: nil, shouldInterpolate: true, intent: .defaultIntent
    )!
}

func gradient(_ colours: [(CGFloat, CGFloat, CGFloat, CGFloat)], _ locations: [CGFloat]) -> CGGradient {
    CGGradient(
        colorSpace: space,
        colorComponents: colours.flatMap { [$0.0, $0.1, $0.2, $0.3] },
        locations: locations,
        count: colours.count
    )!
}

func drawIcon() -> CGImage {
    let context = newContext(size)
    let side = CGFloat(size)

    // The light tile, on Apple's icon grid: 824 of 1024, with a soft shadow.
    let tile = CGPath(
        roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824), cornerWidth: 185, cornerHeight: 185, transform: nil
    )
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -10), blur: 22, color: CGColor(gray: 0, alpha: 0.32))
    context.addPath(tile)
    context.setFillColor(CGColor(srgbRed: 0.95, green: 0.95, blue: 0.95, alpha: 1))
    context.fillPath()
    context.restoreGState()

    // The metal rim: the arrow widened by a round stroke, with a grey gradient, light on top.
    let arrow = arrowPath()
    let rim = CGMutablePath()
    rim.addPath(arrow.copy(strokingWithWidth: 104, lineCap: .round, lineJoin: .round, miterLimit: 10))
    rim.addPath(arrow)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -3), blur: 6, color: CGColor(gray: 0, alpha: 0.22))
    context.addPath(rim)
    context.setFillColor(CGColor(gray: 0.85, alpha: 1))
    context.fillPath(using: .winding)
    context.restoreGState()
    context.saveGState()
    context.addPath(rim)
    context.clip(using: .winding)
    context.drawLinearGradient(
        gradient([(0.89, 0.89, 0.89, 1), (0.74, 0.75, 0.77, 1)], [0, 1]),
        start: CGPoint(x: 0, y: 920), end: CGPoint(x: 0, y: 110), options: []
    )
    context.restoreGState()

    // The colour field inside the arrow.
    context.saveGState()
    context.addPath(arrow)
    context.clip()
    context.draw(colourField(), in: CGRect(x: 0, y: 0, width: side, height: side))

    // A soft glow on top, and a darker edge, so it reads as a glossy object rather than a flat shape.
    context.drawRadialGradient(
        gradient([(1, 0.93, 0.55, 0.42), (1, 0.85, 0.3, 0)], [0, 1]),
        startCenter: CGPoint(x: 470, y: 720), startRadius: 0,
        endCenter: CGPoint(x: 470, y: 720), endRadius: 300, options: []
    )
    context.addPath(arrow)
    context.setLineWidth(8)
    context.setStrokeColor(CGColor(gray: 0, alpha: 0.07))
    context.strokePath()
    context.restoreGState()

    return context.makeImage()!
}

func png(_ image: CGImage, side: Int) -> Data {
    let context = newContext(side)
    context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
    return NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .png, properties: [:])!
}

let output = URL(fileURLWithPath: "App/Assets.xcassets/AppIcon.appiconset")
let icon = drawIcon()
var images: [[String: String]] = []
for (points, scales) in [(16, [1, 2]), (32, [1, 2]), (128, [1, 2]), (256, [1, 2]), (512, [1, 2])] {
    for scale in scales {
        let name = "icon_\(points)x\(points)@\(scale)x.png"
        try png(icon, side: points * scale).write(to: output.appendingPathComponent(name))
        images.append(["filename": name, "idiom": "mac", "scale": "\(scale)x", "size": "\(points)x\(points)"])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: output.appendingPathComponent("Contents.json"))
