import AppKit
import CoreGraphics

let sizes: [(name: String, px: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

func renderIcon(px: Int) -> Data? {
    let s = CGFloat(px)
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let ctx = CGContext(
        data: nil,
        width: px,
        height: px,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)

    // 1. macOS squircle background with margin
    let margin = s * 0.08
    let rect = CGRect(x: margin, y: margin, width: s - margin * 2, height: s - margin * 2)
    let corner = rect.width * 0.225
    let bgPath = CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil)

    // Drop shadow behind squircle
    ctx.saveGState()
    ctx.setShadow(
        offset: CGSize(width: 0, height: -s * 0.02),
        blur: s * 0.05,
        color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.45)
    )
    ctx.addPath(bgPath)
    ctx.setFillColor(CGColor(srgbRed: 0.05, green: 0.07, blue: 0.13, alpha: 1.0))
    ctx.fillPath()
    ctx.restoreGState()

    // Clip to squircle for internal gradients
    ctx.saveGState()
    ctx.addPath(bgPath)
    ctx.clip()

    // Deep obsidian-to-indigo background gradient
    let bgColors = [
        CGColor(srgbRed: 0.11, green: 0.15, blue: 0.26, alpha: 1.0),
        CGColor(srgbRed: 0.05, green: 0.07, blue: 0.13, alpha: 1.0)
    ] as CFArray
    if let grad = CGGradient(colorsSpace: colorSpace, colors: bgColors, locations: [0.0, 1.0]) {
        ctx.drawLinearGradient(
            grad,
            start: CGPoint(x: s * 0.5, y: rect.maxY),
            end: CGPoint(x: s * 0.5, y: rect.minY),
            options: []
        )
    }

    // Subtle top-left ambient glow
    let glowColors = [
        CGColor(srgbRed: 0.24, green: 0.56, blue: 1.0, alpha: 0.26),
        CGColor(srgbRed: 0.24, green: 0.56, blue: 1.0, alpha: 0.0)
    ] as CFArray
    if let rGrad = CGGradient(colorsSpace: colorSpace, colors: glowColors, locations: [0.0, 1.0]) {
        ctx.drawRadialGradient(
            rGrad,
            startCenter: CGPoint(x: s * 0.35, y: s * 0.72),
            startRadius: 0,
            endCenter: CGPoint(x: s * 0.35, y: s * 0.72),
            endRadius: s * 0.55,
            options: []
        )
    }

    let center = CGPoint(x: s * 0.5, y: s * 0.48)

    // 2. Outer Gauge Arc (Codex / 7-Day Window) & Inner Gauge Arc (Gemini / 5h Window)
    // Angles in CoreGraphics (y-up): 220 deg (bottom-left) clockwise to -40 deg (bottom-right)
    let startDeg: CGFloat = 215.0
    let endDeg: CGFloat = -35.0
    let deg2rad = CGFloat.pi / 180.0

    func drawTrackAndArc(radius: CGFloat, lineWidth: CGFloat, fillEndDeg: CGFloat, c1: CGColor, c2: CGColor) {
        // Track
        ctx.saveGState()
        ctx.setLineWidth(lineWidth)
        ctx.setLineCap(.round)
        ctx.setStrokeColor(CGColor(srgbRed: 0.20, green: 0.25, blue: 0.38, alpha: 0.55))
        ctx.addArc(center: center, radius: radius, startAngle: startDeg * deg2rad, endAngle: endDeg * deg2rad, clockwise: true)
        ctx.strokePath()
        ctx.restoreGState()

        // Active gradient arc
        ctx.saveGState()
        ctx.setLineWidth(lineWidth)
        ctx.setLineCap(.round)
        ctx.addArc(center: center, radius: radius, startAngle: startDeg * deg2rad, endAngle: fillEndDeg * deg2rad, clockwise: true)
        ctx.replacePathWithStrokedPath()
        ctx.clip()
        let span = radius + lineWidth * 1.2
        if let g = CGGradient(colorsSpace: colorSpace, colors: [c1, c2] as CFArray, locations: [0.0, 1.0]) {
            ctx.drawLinearGradient(
                g,
                start: CGPoint(x: center.x - span, y: center.y),
                end: CGPoint(x: center.x + span, y: center.y),
                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
            )
        }
        ctx.restoreGState()
    }

    // Outer Arc: Emerald -> Cyan (Healthy / High Quota)
    let outerR = s * 0.285
    let outerW = s * 0.068
    drawTrackAndArc(
        radius: outerR,
        lineWidth: outerW,
        fillEndDeg: 5.0,
        c1: CGColor(srgbRed: 0.15, green: 0.88, blue: 0.56, alpha: 1.0),
        c2: CGColor(srgbRed: 0.20, green: 0.72, blue: 1.00, alpha: 1.0)
    )

    // Inner Arc: Blue -> Amber-Coral (Secondary Window)
    let innerR = s * 0.190
    let innerW = s * 0.056
    drawTrackAndArc(
        radius: innerR,
        lineWidth: innerW,
        fillEndDeg: 45.0,
        c1: CGColor(srgbRed: 0.38, green: 0.55, blue: 1.00, alpha: 1.0),
        c2: CGColor(srgbRed: 1.00, green: 0.68, blue: 0.22, alpha: 1.0)
    )

    // 3. Precision tick marks around the outer gauge
    ctx.saveGState()
    let tickCount = 9
    for i in 0..<tickCount {
        let t = CGFloat(i) / CGFloat(tickCount - 1)
        let deg = startDeg - t * (startDeg - endDeg)
        let rad = deg * deg2rad
        let r1 = outerR + outerW * 0.78
        let r2 = outerR + outerW * (i % 2 == 0 ? 1.12 : 0.98)
        let p1 = CGPoint(x: center.x + cos(rad) * r1, y: center.y + sin(rad) * r1)
        let p2 = CGPoint(x: center.x + cos(rad) * r2, y: center.y + sin(rad) * r2)
        ctx.setLineWidth(max(1.0, s * 0.012))
        ctx.setLineCap(.round)
        ctx.setStrokeColor(CGColor(srgbRed: 0.75, green: 0.84, blue: 0.98, alpha: i % 2 == 0 ? 0.65 : 0.35))
        ctx.move(to: p1)
        ctx.addLine(to: p2)
        ctx.strokePath()
    }
    ctx.restoreGState()

    // 4. Center AI Four-Point Sparkle + Gauge Needle Tip
    let spR = s * 0.095
    let spIn = s * 0.026
    let spCenter = CGPoint(x: center.x, y: center.y - s * 0.01)
    let spPath = CGMutablePath()
    spPath.move(to: CGPoint(x: spCenter.x, y: spCenter.y + spR))
    spPath.addQuadCurve(to: CGPoint(x: spCenter.x + spR, y: spCenter.y), control: CGPoint(x: spCenter.x + spIn, y: spCenter.y + spIn))
    spPath.addQuadCurve(to: CGPoint(x: spCenter.x, y: spCenter.y - spR), control: CGPoint(x: spCenter.x + spIn, y: spCenter.y - spIn))
    spPath.addQuadCurve(to: CGPoint(x: spCenter.x - spR, y: spCenter.y), control: CGPoint(x: spCenter.x - spIn, y: spCenter.y - spIn))
    spPath.addQuadCurve(to: CGPoint(x: spCenter.x, y: spCenter.y + spR), control: CGPoint(x: spCenter.x - spIn, y: spCenter.y + spIn))
    spPath.closeSubpath()

    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: s * 0.04, color: CGColor(srgbRed: 0.35, green: 0.85, blue: 1.0, alpha: 0.75))
    ctx.addPath(spPath)
    ctx.setFillColor(CGColor(srgbRed: 0.96, green: 0.99, blue: 1.0, alpha: 1.0))
    ctx.fillPath()
    ctx.restoreGState()

    // Bottom pill badge ("AI")
    let pillW = s * 0.24
    let pillH = s * 0.095
    let pillRect = CGRect(x: center.x - pillW * 0.5, y: s * 0.165, width: pillW, height: pillH)
    let pillPath = CGPath(roundedRect: pillRect, cornerWidth: pillH * 0.5, cornerHeight: pillH * 0.5, transform: nil)
    ctx.saveGState()
    ctx.addPath(pillPath)
    ctx.setFillColor(CGColor(srgbRed: 0.16, green: 0.22, blue: 0.36, alpha: 0.95))
    ctx.fillPath()
    ctx.addPath(pillPath)
    ctx.setLineWidth(max(1.0, s * 0.01))
    ctx.setStrokeColor(CGColor(srgbRed: 0.32, green: 0.78, blue: 0.98, alpha: 0.65))
    ctx.strokePath()
    ctx.restoreGState()

    // Three glowing status dots inside the bottom pill (Green / Yellow / Red traffic light motif)
    let dotR = s * 0.017
    let dotY = pillRect.midY
    let dotSpacing = s * 0.052
    let dotColors: [CGColor] = [
        CGColor(srgbRed: 0.18, green: 0.90, blue: 0.55, alpha: 1.0),
        CGColor(srgbRed: 1.00, green: 0.75, blue: 0.22, alpha: 1.0),
        CGColor(srgbRed: 1.00, green: 0.38, blue: 0.40, alpha: 1.0)
    ]
    for (idx, dc) in dotColors.enumerated() {
        let dx = center.x + CGFloat(idx - 1) * dotSpacing
        let dRect = CGRect(x: dx - dotR, y: dotY - dotR, width: dotR * 2, height: dotR * 2)
        ctx.saveGState()
        ctx.setFillColor(dc)
        ctx.fillEllipse(in: dRect)
        ctx.restoreGState()
    }

    ctx.restoreGState() // end squircle clip

    // Squircle inner border highlight
    ctx.saveGState()
    ctx.addPath(bgPath)
    ctx.setLineWidth(max(1.0, s * 0.014))
    ctx.setStrokeColor(CGColor(srgbRed: 0.45, green: 0.65, blue: 1.0, alpha: 0.32))
    ctx.strokePath()
    ctx.restoreGState()

    guard let cgImg = ctx.makeImage() else { return nil }
    let rep = NSBitmapImageRep(cgImage: cgImg)
    return rep.representation(using: .png, properties: [:])
}

let scriptDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let outDir = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "\(scriptDir)/AppIcon.iconset"

try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

for item in sizes {
    if let data = renderIcon(px: item.px) {
        let url = URL(fileURLWithPath: "\(outDir)/\(item.name)")
        try! data.write(to: url)
    }
}
print("Generated iconset in \(outDir)")

// Also pack a native Apple ICNS file directly without relying on /var/folders temp dir
let icnsPath = CommandLine.arguments.count > 2
    ? CommandLine.arguments[2]
    : "\(scriptDir)/AppIcon.icns"
let icnsTypes: [(ostype: String, px: Int)] = [
    ("icp4", 16),
    ("icp5", 32),
    ("icp6", 64),
    ("ic07", 128),
    ("ic08", 256),
    ("ic09", 512),
    ("ic10", 1024),
    ("ic11", 32),
    ("ic12", 64),
    ("ic13", 256),
    ("ic14", 512)
]

func u32BE(_ val: UInt32) -> Data {
    var v = val.bigEndian
    return Data(bytes: &v, count: 4)
}

var bodyData = Data()
for entry in icnsTypes {
    if let png = renderIcon(px: entry.px) {
        bodyData.append(entry.ostype.data(using: .ascii)!)
        bodyData.append(u32BE(UInt32(8 + png.count)))
        bodyData.append(png)
    }
}

var icnsData = Data()
icnsData.append("icns".data(using: .ascii)!)
icnsData.append(u32BE(UInt32(8 + bodyData.count)))
icnsData.append(bodyData)
try! icnsData.write(to: URL(fileURLWithPath: icnsPath))
print("Packed native ICNS to \(icnsPath) (\(icnsData.count) bytes)")

