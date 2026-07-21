//
// IconGenerator.swift — draws Vestige's app icon and writes a 1024pt PNG.
//
// The icon is generated from code rather than committed as a binary asset so
// that the entire repository stays reviewable as text, and so contributors can
// adjust the mark without a design tool. Run via Scripts/make-icon.sh.
//
import AppKit
import CoreGraphics
import Foundation

let size = 1024
let scale = CGFloat(size) / 1024.0

guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
      let context = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      )
else {
    FileHandle.standardError.write(Data("Could not create drawing context\n".utf8))
    exit(1)
}

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: colorSpace, components: [r, g, b, a])!
}

// macOS app icons sit inside a rounded-rectangle plate with a margin, matching
// the grid Apple uses so Vestige looks correctly sized next to system apps.
let margin: CGFloat = 100 * scale
let plate = CGRect(x: margin, y: margin, width: CGFloat(size) - margin * 2, height: CGFloat(size) - margin * 2)
let cornerRadius: CGFloat = 185 * scale

let platePath = CGPath(roundedRect: plate, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)

// Dark graphite plate with a top-to-bottom gradient.
context.saveGState()
context.addPath(platePath)
context.clip()

let plateGradient = CGGradient(
    colorsSpace: colorSpace,
    colors: [color(0.16, 0.17, 0.20), color(0.08, 0.08, 0.10)] as CFArray,
    locations: [0, 1]
)!
context.drawLinearGradient(
    plateGradient,
    start: CGPoint(x: 0, y: plate.maxY),
    end: CGPoint(x: 0, y: plate.minY),
    options: []
)
context.restoreGState()

let center = CGPoint(x: CGFloat(size) / 2, y: CGFloat(size) / 2)

// A broken ring: the gap reads as a loop that is continuously being rewritten,
// which is what a replay buffer actually is.
let ringRadius: CGFloat = 268 * scale
let ringWidth: CGFloat = 62 * scale

context.saveGState()
context.setLineWidth(ringWidth)
context.setLineCap(.round)
context.setStrokeColor(color(1, 1, 1, 0.16))
context.addArc(
    center: center,
    radius: ringRadius,
    startAngle: .pi * 0.28,
    endAngle: .pi * 2.72,
    clockwise: false
)
context.strokePath()
context.restoreGState()

// The leading edge of the ring, drawn in red, showing the buffer filling.
context.saveGState()
context.setLineWidth(ringWidth)
context.setLineCap(.round)
context.setStrokeColor(color(0.98, 0.22, 0.26, 1))
context.addArc(
    center: center,
    radius: ringRadius,
    startAngle: .pi * 0.28,
    endAngle: .pi * 1.15,
    clockwise: false
)
context.strokePath()
context.restoreGState()

// Centre record dot with a soft glow.
let dotRadius: CGFloat = 132 * scale

context.saveGState()
context.setShadow(
    offset: .zero,
    blur: 90 * scale,
    color: color(0.98, 0.22, 0.26, 0.55)
)
context.setFillColor(color(0.98, 0.24, 0.28, 1))
context.addEllipse(in: CGRect(
    x: center.x - dotRadius,
    y: center.y - dotRadius,
    width: dotRadius * 2,
    height: dotRadius * 2
))
context.fillPath()
context.restoreGState()

// A highlight along the top edge of the plate, the standard macOS icon bevel.
context.saveGState()
context.addPath(platePath)
context.clip()
context.setLineWidth(6 * scale)
context.setStrokeColor(color(1, 1, 1, 0.14))
context.addPath(platePath)
context.strokePath()
context.restoreGState()

guard let image = context.makeImage() else {
    FileHandle.standardError.write(Data("Could not render icon\n".utf8))
    exit(1)
}

let outputPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-1024.png"
let outputURL = URL(fileURLWithPath: outputPath)

let bitmap = NSBitmapImageRep(cgImage: image)
guard let data = bitmap.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("Could not encode PNG\n".utf8))
    exit(1)
}

try data.write(to: outputURL)
print("Wrote \(outputPath)")
