// One-off icon generator: swift gen-icon.swift
// Draws a gradient + white photo glyph, writes AppIcon.iconset/*.png
import AppKit

let canvas: CGFloat = 1024
let image = NSImage(size: NSSize(width: canvas, height: canvas))
image.lockFocus()

let top = NSColor(calibratedRed: 0.36, green: 0.16, blue: 0.78, alpha: 1)
let bottom = NSColor(calibratedRed: 0.10, green: 0.07, blue: 0.32, alpha: 1)
NSGradient(colors: [bottom, top])!.draw(
    in: NSRect(x: 0, y: 0, width: canvas, height: canvas), angle: 70)

let config = NSImage.SymbolConfiguration(pointSize: 480, weight: .medium)
if let sym = NSImage(systemSymbolName: "photo.fill", accessibilityDescription: nil)?
    .withSymbolConfiguration(config) {
    let scale = 620 / max(sym.size.width, sym.size.height)
    let drawSize = NSSize(width: sym.size.width * scale, height: sym.size.height * scale)

    let white = NSImage(size: drawSize)
    white.lockFocus()
    sym.draw(in: NSRect(origin: .zero, size: drawSize))
    NSColor.white.set()
    NSRect(origin: .zero, size: drawSize).fill(using: .sourceAtop)
    white.unlockFocus()

    white.draw(in: NSRect(x: (canvas - drawSize.width) / 2,
                          y: (canvas - drawSize.height) / 2,
                          width: drawSize.width, height: drawSize.height),
               from: .zero, operation: .sourceOver, fraction: 0.95)
}
image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("failed to render icon")
}
let dir = URL(fileURLWithPath: "AppIcon.iconset")
try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
try png.write(to: dir.appendingPathComponent("icon_512x512@2x.png"))
print("wrote AppIcon.iconset/icon_512x512@2x.png")
