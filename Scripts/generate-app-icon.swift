#!/usr/bin/env swift

//
//  generate-app-icon.swift
//  Contact SyncMate
//
//  Renders the macOS app icon set from code, following Apple's macOS icon
//  geometry (Human Interface Guidelines → App icons → macOS).
//
//  Geometry, expressed on the canonical 1024 pt canvas:
//    • Canvas            1024 × 1024, fully transparent
//    • Icon body          824 × 824  — a "squircle" rounded rectangle
//    • Corner radius     185.4 pt    (0.225 × body width)
//    • Body origin       (100, 90) from the top-left, i.e. horizontally
//                        centred and nudged up so the drop shadow occupies
//                        the空 space at the bottom
//    • Drop shadow       y +12, blur 24, black @ 22 %
//
//  Everything is drawn as vectors and scaled per output size, so the 16 pt
//  icon is a true render rather than a downsample of the 1024 pt artwork.
//
//  Run:  swift Scripts/generate-app-icon.swift
//

import AppKit
import Foundation

// ─────────────────────────────────────────────────────────────────────────
// MARK: - Configuration
// ─────────────────────────────────────────────────────────────────────────

let outputDirectory = "Contact SyncMate/Assets.xcassets/AppIcon.appiconset"
// Marketing artwork lives OUTSIDE the app source folder. The target uses a
// file-system-synchronised group, so any loose file dropped beside the source
// is copied into the built .app as a resource — a 538 KB PNG nobody reads.
let marketingOutput = "docs/assets/app-icon-1024.png"
let sizes: [Int] = [16, 32, 64, 128, 256, 512, 1024]

/// Brand palette. Indigo → violet, matching the app's BrandIndigo asset.
enum Palette {
    static let gradientTop    = NSColor(srgbRed: 0.412, green: 0.373, blue: 0.949, alpha: 1) // #695FF2
    static let gradientBottom = NSColor(srgbRed: 0.243, green: 0.184, blue: 0.769, alpha: 1) // #3E2FC4
    static let glyph          = NSColor.white
}

// ─────────────────────────────────────────────────────────────────────────
// MARK: - Drawing
// ─────────────────────────────────────────────────────────────────────────

/// Draw the complete icon into `ctx`, scaled so that the design — authored
/// against a 1024 pt canvas — fills `pixelSize`.
func drawIcon(in ctx: CGContext, pixelSize: CGFloat) {
    let s = pixelSize / 1024.0            // design-unit → pixel scale
    ctx.saveGState()
    ctx.scaleBy(x: s, y: s)               // now work in 1024-pt design units

    // ── Icon body: the macOS squircle ───────────────────────────────────
    // Core Graphics origin is bottom-left; the body sits 90 pt from the top,
    // which is 110 pt from the bottom (1024 − 90 − 824).
    let bodyRect = CGRect(x: 100, y: 110, width: 824, height: 824)
    let cornerRadius: CGFloat = 185.4
    let body = CGPath(roundedRect: bodyRect,
                      cornerWidth: cornerRadius,
                      cornerHeight: cornerRadius,
                      transform: nil)

    // Drop shadow beneath the body
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12),
                  blur: 24,
                  color: NSColor.black.withAlphaComponent(0.22).cgColor)
    ctx.addPath(body)
    ctx.setFillColor(Palette.gradientBottom.cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    // Gradient fill, clipped to the body
    ctx.saveGState()
    ctx.addPath(body)
    ctx.clip()
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    if let gradient = CGGradient(colorsSpace: colorSpace,
                                 colors: [Palette.gradientTop.cgColor,
                                          Palette.gradientBottom.cgColor] as CFArray,
                                 locations: [0, 1]) {
        ctx.drawLinearGradient(gradient,
                               start: CGPoint(x: bodyRect.minX, y: bodyRect.maxY),
                               end:   CGPoint(x: bodyRect.maxX, y: bodyRect.minY),
                               options: [])
    }

    // Top sheen — a soft highlight across the upper third, the way macOS
    // system icons catch light.
    if let sheen = CGGradient(colorsSpace: colorSpace,
                              colors: [NSColor.white.withAlphaComponent(0.20).cgColor,
                                       NSColor.white.withAlphaComponent(0.0).cgColor] as CFArray,
                              locations: [0, 1]) {
        ctx.drawLinearGradient(sheen,
                               start: CGPoint(x: bodyRect.midX, y: bodyRect.maxY),
                               end:   CGPoint(x: bodyRect.midX, y: bodyRect.midY + 40),
                               options: [])
    }
    ctx.restoreGState()

    // ── Glyph: a sync ring around a person ──────────────────────────────
    // Chosen because it survives downscaling: at 16 pt the ring plus the
    // head silhouette still read as "contacts, syncing".
    let cx: CGFloat = 512, cy: CGFloat = 522     // optical centre of the body
    let ringRadius: CGFloat = 244
    let ringWidth: CGFloat  = 66                 // chunky enough to survive 16 pt
    let d = CGFloat.pi / 180

    ctx.setStrokeColor(Palette.glyph.cgColor)
    ctx.setLineWidth(ringWidth)
    ctx.setLineCap(.butt)

    // Two arcs, each ending where an arrowhead takes over.
    func arc(fromDeg a0: CGFloat, toDeg a1: CGFloat) {
        ctx.beginPath()
        ctx.addArc(center: CGPoint(x: cx, y: cy), radius: ringRadius,
                   startAngle: a0 * d, endAngle: a1 * d, clockwise: false)
        ctx.strokePath()
    }
    arc(fromDeg: 24,  toDeg: 158)      // upper sweep
    arc(fromDeg: 204, toDeg: 338)      // lower sweep

    // Arrowheads. Base is a radial chord at the arc's end; the tip continues
    // along the tangent. Proportions kept short and wide — long spiky heads
    // turn to mush below 32 pt.
    func arrowHead(atDeg deg: CGFloat, clockwise: Bool) {
        let a = deg * d
        let tangent = a + (clockwise ? -.pi / 2 : .pi / 2)
        let tipLength: CGFloat = 82
        let halfBase:  CGFloat = 66

        let onRing = CGPoint(x: cx + cos(a) * ringRadius,
                             y: cy + sin(a) * ringRadius)
        let tip = CGPoint(x: onRing.x + cos(tangent) * tipLength,
                          y: onRing.y + sin(tangent) * tipLength)
        let outer = CGPoint(x: cx + cos(a) * (ringRadius + halfBase),
                            y: cy + sin(a) * (ringRadius + halfBase))
        let inner = CGPoint(x: cx + cos(a) * (ringRadius - halfBase),
                            y: cy + sin(a) * (ringRadius - halfBase))

        ctx.beginPath()
        ctx.move(to: tip)
        ctx.addLine(to: outer)
        ctx.addLine(to: inner)
        ctx.closePath()
        ctx.setFillColor(Palette.glyph.cgColor)
        ctx.fillPath()
    }
    // Both arcs are drawn counter-clockwise, so both arrowheads must continue
    // counter-clockwise (tangent = angle + 90°). Giving one of them the
    // opposite sense makes the pair read as a translation rather than a
    // rotation — the symbol stops looking like "sync".
    arrowHead(atDeg: 158, clockwise: false)   // end of upper sweep
    arrowHead(atDeg: 338, clockwise: false)   // end of lower sweep

    // ── Person silhouette inside the ring ───────────────────────────────
    ctx.setFillColor(Palette.glyph.cgColor)

    let headRadius: CGFloat = 62
    let headCenter = CGPoint(x: cx, y: cy + 58)
    ctx.fillEllipse(in: CGRect(x: headCenter.x - headRadius,
                               y: headCenter.y - headRadius,
                               width: headRadius * 2,
                               height: headRadius * 2))

    // Shoulders: the TOP half of an ellipse — a dome, rounded across the top
    // and flat along the bottom, the way SF Symbols draws `person.fill`.
    // Clipping to the upper half is what makes it shoulders rather than a
    // pill or an inverted bowl.
    let torsoWidth:  CGFloat = 196
    let torsoHeight: CGFloat = 90
    let torsoBottom: CGFloat = cy - 100
    let torsoRect = CGRect(x: cx - torsoWidth / 2, y: torsoBottom,
                           width: torsoWidth, height: torsoHeight)
    ctx.saveGState()
    ctx.clip(to: torsoRect)
    ctx.fillEllipse(in: CGRect(x: torsoRect.minX,
                               y: torsoBottom - torsoHeight,   // ellipse centred
                               width: torsoWidth,              // on the flat edge,
                               height: torsoHeight * 2))       // so the dome shows
    ctx.restoreGState()

    ctx.restoreGState()
}

// ─────────────────────────────────────────────────────────────────────────
// MARK: - Rendering helpers
// ─────────────────────────────────────────────────────────────────────────

func renderPNG(size: Int) -> Data? {
    let px = size
    guard let ctx = CGContext(data: nil,
                              width: px, height: px,
                              bitsPerComponent: 8,
                              bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }

    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high

    drawIcon(in: ctx, pixelSize: CGFloat(px))

    guard let cgImage = ctx.makeImage() else { return nil }
    let rep = NSBitmapImageRep(cgImage: cgImage)
    rep.size = NSSize(width: px, height: px)
    return rep.representation(using: .png, properties: [:])
}

// ─────────────────────────────────────────────────────────────────────────
// MARK: - Main
// ─────────────────────────────────────────────────────────────────────────

let fm = FileManager.default
var wrote = 0

for size in sizes {
    guard let data = renderPNG(size: size) else {
        FileHandle.standardError.write("FAILED to render \(size)px\n".data(using: .utf8)!)
        continue
    }
    let path = "\(outputDirectory)/icon_\(size)x\(size).png"
    do {
        try data.write(to: URL(fileURLWithPath: path))
        print("  ✓ icon_\(size)x\(size).png   (\(data.count.formatted()) bytes)")
        wrote += 1
    } catch {
        FileHandle.standardError.write("FAILED writing \(path): \(error)\n".data(using: .utf8)!)
    }
}

// Marketing artwork — same design at 1024. macOS store art keeps the squircle
// silhouette, so the alpha channel here is correct (unlike iOS, which requires
// a fully opaque icon).
if let data = renderPNG(size: 1024) {
    try? data.write(to: URL(fileURLWithPath: marketingOutput))
    print("  ✓ \(marketingOutput)  (\(data.count.formatted()) bytes)")
}

print("\nRendered \(wrote)/\(sizes.count) icon sizes into \(outputDirectory)")
_ = fm
