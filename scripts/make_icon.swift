#!/usr/bin/env swift
//
// make_icon.swift
// Renders the Photon "single photon" app icon to an .icns file.
//
// Concept: one bright point of light (the photon) off-center upper-right,
// with a fading cyan streak behind it — calm, fast, lightweight.
//
// Run:  swift scripts/make_icon.swift
// Outputs: Assets/AppIcon.iconset/ + Assets/AppIcon.icns

import AppKit
import CoreGraphics
import ImageIO
import Foundation

// MARK: - Colors (sRGB)

/// Near-black with a faint blue tint.
func bgTop()      -> CGColor { CGColor(srgbRed: 0.16, green: 0.185, blue: 0.255, alpha: 1) }   // #292F41-ish, soft center
func bgBottom()   -> CGColor { CGColor(srgbRed: 0.035, green: 0.045, blue: 0.075, alpha: 1) }   // #090B13 edge

func cyanFaint()  -> CGColor { CGColor(srgbRed: 0.49, green: 0.83, blue: 0.988, alpha: 1) }     // #7DD3FC
func cyanBright() -> CGColor { CGColor(srgbRed: 0.878, green: 0.949, blue: 0.996, alpha: 1) }    // #E0F2FE pale white-ish

// MARK: - Drawing

/// Draws the photon into the given CGContext at the given pixel size.
func drawPhoton(into ctx: CGContext, size S: CGFloat) {
    let bounds = CGRect(x: 0, y: 0, width: S, height: S)
    let k = S / 1024.0   // scale factor so the design is resolution-independent

    // macOS app icons use a "squircle" (superellipse-ish) mask. A rounded rect
    // with ~22.4% corner radius is a close-enough approximation.
    let cornerRadius = S * 0.224
    let maskPath = CGPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                         cornerWidth: cornerRadius, cornerHeight: cornerRadius,
                         transform: nil)
    ctx.addPath(maskPath)
    ctx.clip()

    // 1) Background: a soft radial gradient, brighter in the middle, fading to deep near-black at edges.
    let center = CGPoint(x: S * 0.50, y: S * 0.48)
    if let bgGrad = CGGradient(colorsSpace: ctx.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
                               colors: [bgTop(), bgBottom()] as CFArray,
                               locations: [0.0, 1.0]) {
        ctx.drawRadialGradient(bgGrad,
                               startCenter: center, startRadius: 0,
                               endCenter: center, endRadius: S * 0.78,
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }

    // 2) Photon geometry: tail (lower-left) → head (upper-right). The head is the focal point.
    let head = CGPoint(x: S * 0.635, y: S * 0.615)
    let tail = CGPoint(x: S * 0.345, y: S * 0.375)

    // 3) The streak — ONE continuous gradient, drawn as a chain of overlapping
    //    soft radial disks along the tail→head axis. There are no distinct
    //    "tiers" or constant-width bands: width and brightness both vary as
    //    smooth functions of position along the stroke, so it reads as a single
    //    comet-like beam that is narrow + bright at the head and wider + dimmer
    //    toward the tail, ultimately fading into the background.
    func lerpColor(_ a: CGColor, _ b: CGColor, _ t: CGFloat) -> CGColor {
        let ar = a.components ?? [0, 0, 0, 0]
        let br = b.components ?? [0, 0, 0, 0]
        guard ar.count >= 4, br.count >= 4 else { return b }
        return CGColor(srgbRed: ar[0] + (br[0] - ar[0]) * t,
                       green:    ar[1] + (br[1] - ar[1]) * t,
                       blue:     ar[2] + (br[2] - ar[2]) * t,
                       alpha:    ar[3] + (br[3] - ar[3]) * t)
    }

    let headHalf: CGFloat = 5 * k      // beam radius at the head (thin)
    let tailHalf: CGFloat = 95 * k     // beam radius at the tail (thick)
    let diskCount = 160              // dense enough to be perfectly smooth
    for i in 0...diskCount {
        let s = CGFloat(i) / CGFloat(diskCount)          // 0 at tail → 1 at head
        // Width: wide at the tail, narrowing toward the head (eased).
        let w = headHalf + (tailHalf - headHalf) * pow(1 - s, 0.7)
        // Brightness along the axis: transparent at the tail → full at the head.
        let alpha = pow(s, 0.55)
        // Hue shifts from faint cyan (tail) toward pale white (head).
        let color = lerpColor(cyanFaint(), cyanBright(), s).copy(alpha: alpha)!
        let c = CGPoint(x: tail.x + (head.x - tail.x) * s,
                        y: tail.y + (head.y - tail.y) * s)
        if let grad = CGGradient(colorsSpace: ctx.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
                                 colors: [color, color.copy(alpha: 0)!] as CFArray,
                                 locations: [0.0, 1.0]) {
            ctx.drawRadialGradient(grad,
                                   startCenter: c, startRadius: 0,
                                   endCenter: c, endRadius: w,
                                   options: [])
        }
    }

    // 4) Photon head: stacked radial gradients form a soft bloom + a bright hot core.
    struct Halo {
        let radius: CGFloat
        let color: CGColor
    }
    // Each halo goes from the color at center to fully transparent at the edge.
    let halos: [Halo] = [
        Halo(radius: 360 * k, color: cyanFaint().copy(alpha: 0.22)!),
        Halo(radius: 170 * k, color: cyanFaint().copy(alpha: 0.40)!),
        Halo(radius: 72 * k,  color: cyanBright().copy(alpha: 0.85)!),
        Halo(radius: 26 * k,  color: cyanBright().copy(alpha: 1.0)!),
    ]
    for halo in halos {
        if let grad = CGGradient(colorsSpace: ctx.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
                                 colors: [halo.color, halo.color.copy(alpha: 0.0)!] as CFArray,
                                 locations: [0.0, 1.0]) {
            ctx.drawRadialGradient(grad,
                                   startCenter: head, startRadius: 0,
                                   endCenter: head, endRadius: halo.radius,
                                   options: [])
        }
    }

    // 5) A tiny pure-white spec at the very center — the "hot" point that survives at 16×16.
    ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
    ctx.fillEllipse(in: CGRect(x: head.x - 6 * k, y: head.y - 6 * k,
                                width: 12 * k, height: 12 * k))
}

// MARK: - PNG export

func renderPNG(size: CGFloat, to url: URL) {
    let cs = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(data: nil, width: Int(size), height: Int(size),
                              bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        fatalError("Could not create bitmap context for size \(size)")
    }
    drawPhoton(into: ctx, size: size)

    guard let cgImage = ctx.makeImage() else { fatalError("Could not make image") }
    let bitmap = NSBitmapImageRep(cgImage: cgImage)
    guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
        fatalError("Could not encode PNG")
    }
    try? pngData.write(to: url)
}

// MARK: - Build the iconset + .icns

let fm = FileManager.default
let projectRoot = URL(fileURLWithPath: #file)              // scripts/make_icon.swift
    .deletingLastPathComponent().deletingLastPathComponent()
let iconsetDir = projectRoot.appendingPathComponent("Assets/AppIcon.iconset")
let icnsURL = projectRoot.appendingPathComponent("Assets/AppIcon.icns")

try? fm.removeItem(at: iconsetDir)
try? fm.createDirectory(at: iconsetDir, withIntermediateDirectories: true)

// Apple's iconset spec: each name maps to a specific pixel size.
let entries: [(name: String, pixels: CGFloat)] = [
    ("icon_16x16.png",         16),
    ("icon_16x16@2x.png",      32),
    ("icon_32x32.png",         32),
    ("icon_32x32@2x.png",      64),
    ("icon_128x128.png",      128),
    ("icon_128x128@2x.png",   256),
    ("icon_256x256.png",      256),
    ("icon_256x256@2x.png",   512),
    ("icon_512x512.png",      512),
    ("icon_512x512@2x.png",  1024),
]

print("Rendering Photon icon…")
for entry in entries {
    let outURL = iconsetDir.appendingPathComponent(entry.name)
    renderPNG(size: entry.pixels, to: outURL)
    print("  ✓ \(entry.name) (\(Int(entry.pixels))×\(Int(entry.pixels)))")
}

// Convert the iconset folder into a single .icns file.
let p = Process()
p.launchPath = "/usr/bin/iconutil"
p.arguments = ["-c", "icns", iconsetDir.path, "-o", icnsURL.path]
p.standardError = FileHandle.standardError
try? p.run()
p.waitUntilExit()

if p.terminationStatus == 0 {
    print("\n✅ Created \(icnsURL.path)")
} else {
    print("\n❌ iconutil failed with status \(p.terminationStatus)")
    exit(p.terminationStatus)
}
