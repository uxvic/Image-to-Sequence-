#!/usr/bin/env swift
//
// Generates the macOS app-icon PNGs into Assets.xcassets/AppIcon.appiconset.
// Run from the repo root on macOS:
//
//   swift scripts/make_icon.swift
//
// If Branding/icon-1024.png exists, it is scaled down to all sizes (use your own
// designed icon). Otherwise a clean built-in "stacked frames + play" icon is drawn.
//
import AppKit
import Foundation

// (filename, pixel size) — the full macOS app-icon set.
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
    ("icon_512x512@2x.png", 1024),
]

let fm = FileManager.default
let root = URL(fileURLWithPath: fm.currentDirectoryPath)
let outDir = root.appendingPathComponent("Assets.xcassets/AppIcon.appiconset", isDirectory: true)
try? fm.createDirectory(at: outDir, withIntermediateDirectories: true)

// Use the designer's own 1024px art if present.
let customArtURL = root.appendingPathComponent("Branding/icon-1024.png")
let customArt: NSImage? = fm.fileExists(atPath: customArtURL.path) ? NSImage(contentsOf: customArtURL) : nil

func roundedRect(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func drawBuiltIn(_ cg: CGContext, _ dim: CGFloat) {
    // Squircle background with the macOS-style margin + corner radius.
    let margin = dim * 0.10
    let side = dim - margin * 2
    let bg = CGRect(x: margin, y: margin, width: side, height: side)

    cg.saveGState()
    cg.addPath(roundedRect(bg, side * 0.2237))
    cg.clip()
    let space = CGColorSpaceCreateDeviceRGB()
    let colors = [
        CGColor(red: 0.20, green: 0.85, blue: 0.50, alpha: 1),
        CGColor(red: 0.06, green: 0.52, blue: 0.29, alpha: 1),
    ] as CFArray
    if let grad = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1]) {
        cg.drawLinearGradient(grad, start: CGPoint(x: 0, y: dim), end: CGPoint(x: 0, y: 0), options: [])
    }
    cg.restoreGState()

    // Stacked "frames" → an image sequence.
    let fw = side * 0.46
    let fh = fw * 0.72
    let cx = dim / 2, cy = dim / 2
    let corner = fw * 0.12
    let off = side * 0.055
    for p in [(dx: -off, dy: off, a: CGFloat(0.35)), (dx: CGFloat(0), dy: CGFloat(0), a: CGFloat(1.0))] {
        let r = CGRect(x: cx - fw / 2 + p.dx, y: cy - fh / 2 + p.dy, width: fw, height: fh)
        cg.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: p.a))
        cg.addPath(roundedRect(r, corner))
        cg.fillPath()
    }

    // Play triangle on the front frame.
    let triH = fh * 0.42, triW = triH * 0.86
    cg.setFillColor(CGColor(red: 0.10, green: 0.60, blue: 0.35, alpha: 1))
    cg.move(to: CGPoint(x: cx - triW / 2, y: cy + triH / 2))
    cg.addLine(to: CGPoint(x: cx - triW / 2, y: cy - triH / 2))
    cg.addLine(to: CGPoint(x: cx + triW / 2, y: cy))
    cg.closePath()
    cg.fillPath()
}

func renderPNG(px: Int) -> Data? {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { return nil }
    let dim = CGFloat(px)
    rep.size = NSSize(width: dim, height: dim)

    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    guard let gctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    NSGraphicsContext.current = gctx
    let cg = gctx.cgContext

    if let art = customArt, let cgImg = art.cgImage(forProposedRect: nil, context: nil, hints: nil) {
        cg.draw(cgImg, in: CGRect(x: 0, y: 0, width: dim, height: dim))
    } else {
        drawBuiltIn(cg, dim)
    }
    gctx.flushGraphics()
    return rep.representation(using: .png, properties: [:])
}

var count = 0
for entry in sizes {
    guard let data = renderPNG(px: entry.px) else { print("✗ render failed: \(entry.name)"); continue }
    do {
        try data.write(to: outDir.appendingPathComponent(entry.name))
        count += 1
    } catch {
        print("✗ write failed: \(entry.name): \(error)")
    }
}
print("✓ Wrote \(count)/\(sizes.count) icon PNGs to \(outDir.path)")
print(customArt != nil
      ? "  (scaled from Branding/icon-1024.png)"
      : "  (built-in design — drop Branding/icon-1024.png and re-run to use your own)")
