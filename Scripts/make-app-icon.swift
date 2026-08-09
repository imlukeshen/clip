#!/usr/bin/env swift

// Draws Clip's app icon at every size the asset catalogue asks for.
//
// The icon is generated rather than hand-drawn so it has a reviewable source:
// the shape, the palette, and the optical adjustments below are the design, and
// a diff to them is a diff to the icon.
//
// Usage: swift Scripts/make-app-icon.swift [output-directory]

import AppKit
import CoreGraphics
import Foundation

// MARK: - Design

/// Palette taken from the app's dark theme so the icon and the app agree.
private enum Ink {
    static let top = CGColor(red: 0.153, green: 0.153, blue: 0.165, alpha: 1)  // surfaceRaised
    static let bottom = CGColor(red: 0.043, green: 0.043, blue: 0.047, alpha: 1)  // surfaceBase
    static let mark = CGColor(red: 0.929, green: 0.929, blue: 0.937, alpha: 1)  // textPrimary
    static let rim = CGColor(red: 1, green: 1, blue: 1, alpha: 0.14)
}

/// macOS sits its icons inside the canvas rather than filling it, so a Dock
/// full of apps shares one silhouette. Apple's grid gives the body 824 of 1024
/// points; small sizes take a little more of the canvas because the margin
/// costs proportionally more pixels than it buys.
private func bodyFraction(forPixelSize size: Int) -> CGFloat {
    switch size {
    case ..<40: 0.94
    case ..<80: 0.88
    default: 824.0 / 1024.0
    }
}

/// Stroke of the mark as a fraction of the body. Thickened at small sizes,
/// where a hairline would disappear into the background.
private func strokeFraction(forPixelSize size: Int) -> CGFloat {
    size < 40 ? 0.150 : 0.115
}

/// Diameter of the mark as a fraction of the body. The mark carries more of
/// the canvas at small sizes, where surrounding air is the first thing that
/// stops reading.
private func markFraction(forPixelSize size: Int) -> CGFloat {
    size < 40 ? 0.62 : 0.56
}

/// A superellipse, which is what gives Apple's icons their continuous corner.
/// A circular rounded rectangle reads subtly wrong beside them.
private func squirclePath(in rect: CGRect, exponent: CGFloat = 5) -> CGPath {
    let path = CGMutablePath()
    let halfWidth = rect.width / 2
    let halfHeight = rect.height / 2
    let centerX = rect.midX
    let centerY = rect.midY
    let steps = 720
    for step in 0...steps {
        let angle = CGFloat(step) / CGFloat(steps) * 2 * .pi
        let cosine = cos(angle)
        let sine = sin(angle)
        let power = 2 / exponent
        let x = centerX + halfWidth * copysign(pow(abs(cosine), power), cosine)
        let y = centerY + halfHeight * copysign(pow(abs(sine), power), sine)
        if step == 0 {
            path.move(to: CGPoint(x: x, y: y))
        } else {
            path.addLine(to: CGPoint(x: x, y: y))
        }
    }
    path.closeSubpath()
    return path
}

private func drawIcon(size: Int, into context: CGContext) {
    let canvas = CGFloat(size)
    context.setAllowsAntialiasing(true)
    context.interpolationQuality = .high
    context.clear(CGRect(x: 0, y: 0, width: canvas, height: canvas))

    let body = canvas * bodyFraction(forPixelSize: size)
    // Sit the body a touch high: the shadow below it carries the visual weight
    // back to centre, which is how macOS icons balance in the Dock.
    let originY = (canvas - body) / 2 + canvas * (size >= 128 ? 0.012 : 0)
    let bodyRect = CGRect(x: (canvas - body) / 2, y: originY, width: body, height: body)
    let shape = squirclePath(in: bodyRect)

    // Shadow. Below 128 points it turns into a grey smear rather than depth.
    if size >= 128 {
        context.saveGState()
        context.setShadow(
            offset: CGSize(width: 0, height: -canvas * 0.012),
            blur: canvas * 0.03,
            color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.38)
        )
        context.addPath(shape)
        context.setFillColor(Ink.bottom)
        context.fillPath()
        context.restoreGState()
    }

    // Body, lit from above.
    context.saveGState()
    context.addPath(shape)
    context.clip()
    let space = CGColorSpaceCreateDeviceRGB()
    if let gradient = CGGradient(
        colorsSpace: space,
        colors: [Ink.top, Ink.bottom] as CFArray,
        locations: [0, 1]
    ) {
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: bodyRect.midX, y: bodyRect.maxY),
            end: CGPoint(x: bodyRect.midX, y: bodyRect.minY),
            options: []
        )
    }
    context.restoreGState()

    // A hairline along the top edge, so the body reads as a lit surface rather
    // than a flat cutout. Too fine to resolve at small sizes.
    if size >= 64 {
        context.saveGState()
        context.addPath(shape)
        context.setStrokeColor(Ink.rim)
        context.setLineWidth(max(canvas * 0.0032, 0.75))
        context.replacePathWithStrokedPath()
        context.clip()
        if let gradient = CGGradient(
            colorsSpace: space,
            colors: [
                Ink.rim,
                CGColor(red: 1, green: 1, blue: 1, alpha: 0),
            ] as CFArray,
            locations: [0, 1]
        ) {
            context.drawLinearGradient(
                gradient,
                start: CGPoint(x: bodyRect.midX, y: bodyRect.maxY),
                end: CGPoint(x: bodyRect.midX, y: bodyRect.midY),
                options: []
            )
        }
        context.restoreGState()
    }

    // The mark: a geometric C, drawn as an arc rather than set as a letter, so
    // its weight stays even and its terminals stay clean at every size.
    let stroke = body * strokeFraction(forPixelSize: size)
    let radius = (body * markFraction(forPixelSize: size) - stroke) / 2
    let gap: CGFloat = 52  // degrees of opening, centred on the right
    context.saveGState()
    context.setStrokeColor(Ink.mark)
    context.setLineWidth(stroke)
    context.setLineCap(.round)
    context.addArc(
        center: CGPoint(x: bodyRect.midX, y: bodyRect.midY),
        radius: radius,
        startAngle: gap / 2 * .pi / 180,
        endAngle: (360 - gap / 2) * .pi / 180,
        clockwise: false
    )
    context.strokePath()
    context.restoreGState()
}

// MARK: - Output

private func render(size: Int) -> Data? {
    guard
        let context = CGContext(
            data: nil,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    else { return nil }
    drawIcon(size: size, into: context)
    guard let image = context.makeImage() else { return nil }
    let representation = NSBitmapImageRep(cgImage: image)
    representation.size = NSSize(width: size, height: size)
    return representation.representation(using: .png, properties: [:])
}

/// Every entry the asset catalogue lists, and the pixel size it needs.
private let outputs: [(name: String, size: Int)] = [
    ("AppIcon-16", 16),
    ("AppIcon-16@2x", 32),
    ("AppIcon-32", 32),
    ("AppIcon-32@2x", 64),
    ("AppIcon-128", 128),
    ("AppIcon-128@2x", 256),
    ("AppIcon-256", 256),
    ("AppIcon-256@2x", 512),
    ("AppIcon-512", 512),
    ("AppIcon-512@2x", 1_024),
]

let destination =
    CommandLine.arguments.count > 1
    ? URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    : URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent(
            "App/Reel/Sources/Reel/Resources/Assets.xcassets/AppIcon.appiconset",
            isDirectory: true
        )

try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
var rendered: [Int: Data] = [:]
for output in outputs {
    let data: Data
    if let cached = rendered[output.size] {
        data = cached
    } else {
        guard let fresh = render(size: output.size) else {
            FileHandle.standardError.write(Data("Could not render \(output.size)px\n".utf8))
            exit(1)
        }
        rendered[output.size] = fresh
        data = fresh
    }
    try data.write(to: destination.appendingPathComponent("\(output.name).png"))
}
print("Wrote \(outputs.count) icon files to \(destination.path)")
