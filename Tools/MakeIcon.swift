import AppKit

// Draws the Gauge app icon and writes out an .iconset.
//
// Everything is drawn in code rather than loaded from an image, so the icon is
// sharp at every size and can be adjusted by changing the numbers here.
// Run it with Tools/make-icon.sh.

// MARK: - Colours

func rgb(_ r: Double, _ g: Double, _ b: Double) -> CGColor {
    NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: 1).cgColor
}

let slateTop    = rgb(54, 61, 75)
let slateBottom = rgb(13, 15, 20)
let needleWhite = rgb(246, 248, 251)

// The same scale the app uses for its bars: calm when there is headroom, warm
// as it runs out.
let scaleGreen  = rgb(52, 199, 89)
let scaleYellow = rgb(255, 214, 10)
let scaleOrange = rgb(255, 159, 10)
let scaleRed    = rgb(255, 69, 58)

let space = CGColorSpaceCreateDeviceRGB()

func gradient(_ colors: [CGColor], _ locations: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: space, colors: colors as CFArray, locations: locations)!
}

// MARK: - The drawing

func draw(in cg: CGContext, size: CGFloat) {
    // The artwork fills the whole canvas, edge to edge, with no rounded corners
    // of its own.
    //
    // This matters on macOS 26 and later: the system rounds icons to its own
    // shape. An icon that already carries its own rounded square inside a
    // transparent margin gets treated as a small image, and the system draws
    // its own tile behind it — one rounded square nested inside another.
    // Filling the canvas lets the system simply mask it.
    let box = CGRect(x: 0, y: 0, width: size, height: size)

    // Below this the fine detail turns to mud, so the small sizes get a
    // chunkier version of the same idea.
    let detailed = size >= 64

    cg.saveGState()

    cg.drawLinearGradient(gradient([slateTop, slateBottom], [0, 1]),
                          start: CGPoint(x: box.midX, y: box.maxY),
                          end: CGPoint(x: box.midX, y: box.minY),
                          options: [])

    // The dial. A speedometer sweep: it starts low on the left, rises over the
    // top and comes down on the right, leaving a gap at the bottom.
    //
    // The dial is sized to carry about as much optical weight as the artwork in
    // Apple's own icons. Drawn smaller it reads as a postage stamp sitting in
    // the middle of a tile, next to neighbours that fill theirs.
    let centre = CGPoint(x: box.midX, y: box.height * 0.445)
    let radius = box.width * 0.335
    let start = 210.0 * .pi / 180
    let end = -30.0 * .pi / 180
    let arcWidth = box.width * (detailed ? 0.125 : 0.155)

    cg.saveGState()
    cg.setLineWidth(arcWidth)
    cg.setLineCap(.round)
    cg.addArc(center: centre, radius: radius,
              startAngle: start, endAngle: end, clockwise: true)
    // Turning the stroke into a shape lets a gradient run along it, so the
    // scale shades from green through to red the way the app's bars do.
    cg.replacePathWithStrokedPath()
    cg.clip()
    cg.drawLinearGradient(
        gradient([scaleGreen, scaleYellow, scaleOrange, scaleRed], [0, 0.45, 0.74, 1]),
        start: CGPoint(x: centre.x - radius, y: centre.y),
        end: CGPoint(x: centre.x + radius, y: centre.y),
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    cg.restoreGState()

    // The needle, pointing a little right of vertical — a machine under load
    // but not in trouble.
    let angle = 70.0 * .pi / 180
    let reach = radius * (detailed ? 0.78 : 0.72)
    let tail = radius * 0.16
    let tip = CGPoint(x: centre.x + cos(angle) * reach,
                      y: centre.y + sin(angle) * reach)
    let back = CGPoint(x: centre.x - cos(angle) * tail,
                       y: centre.y - sin(angle) * tail)

    // A round-capped line is a capsule, which holds its shape when the icon is
    // drawn small far better than a tapered triangle does.
    cg.saveGState()
    cg.setLineCap(.round)
    cg.setLineWidth(box.width * (detailed ? 0.052 : 0.070))
    cg.setStrokeColor(needleWhite)
    cg.move(to: back)
    cg.addLine(to: tip)
    cg.strokePath()
    cg.restoreGState()

    // The hub the needle turns on. At the smallest sizes this is a single dot;
    // larger, it gets a dark centre so it reads as a pivot.
    let hub = box.width * (detailed ? 0.075 : 0.090)
    cg.setFillColor(needleWhite)
    cg.fillEllipse(in: CGRect(x: centre.x - hub / 2, y: centre.y - hub / 2,
                              width: hub, height: hub))
    if detailed {
        let inner = hub * 0.42
        cg.setFillColor(slateBottom)
        cg.fillEllipse(in: CGRect(x: centre.x - inner / 2, y: centre.y - inner / 2,
                                  width: inner, height: inner))
    }

    cg.restoreGState()
}

// MARK: - Writing the files

func render(size: CGFloat) -> Data {
    let pixels = Int(size)
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                     pixelsWide: pixels, pixelsHigh: pixels,
                                     bitsPerSample: 8, samplesPerPixel: 4,
                                     hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0),
          let context = NSGraphicsContext(bitmapImageRep: rep) else {
        fatalError("could not make a bitmap at \(pixels)px")
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    draw(in: context.cgContext, size: size)
    NSGraphicsContext.restoreGraphicsState()

    guard let png = rep.representation(using: .png, properties: [:]) else {
        fatalError("could not encode \(pixels)px as PNG")
    }
    return png
}

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

// The names iconutil expects. A size appears twice when it serves as both a
// 1x and a 2x image.
let wanted: [(name: String, size: CGFloat)] = [
    ("icon_16x16.png", 16),     ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),     ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),  ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),  ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),  ("icon_512x512@2x.png", 1024),
]

var cache: [CGFloat: Data] = [:]
for (name, size) in wanted {
    let png = cache[size] ?? render(size: size)
    cache[size] = png
    try png.write(to: URL(fileURLWithPath: out).appendingPathComponent(name))
    print("  \(name)  (\(Int(size))px)")
}
