#!/usr/bin/env swift

import AppKit
import Foundation

guard CommandLine.arguments.count == 5 else {
    fputs("usage: compose_screenshot.swift INPUT OUTPUT HEADLINE DETAIL\n", stderr)
    exit(2)
}

let input = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2])
let headline = CommandLine.arguments[3]
let detail = CommandLine.arguments[4]

guard let source = NSImage(contentsOf: input) else {
    fputs("could not read input image\n", stderr)
    exit(3)
}

let size = NSSize(width: 1440, height: 900)
let canvas = NSImage(size: size)
canvas.lockFocus()

NSColor(calibratedWhite: 0.035, alpha: 1).setFill()
NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()

let ink = NSColor(calibratedRed: 0.93, green: 0.93, blue: 0.90, alpha: 1)
let muted = NSColor(calibratedWhite: 0.58, alpha: 1)

let headlineAttributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.monospacedSystemFont(ofSize: 42, weight: .black),
    .foregroundColor: ink,
]
let detailAttributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.monospacedSystemFont(ofSize: 19, weight: .medium),
    .foregroundColor: muted,
]

(headline as NSString).draw(at: NSPoint(x: 96, y: 812), withAttributes: headlineAttributes)
(detail as NSString).draw(at: NSPoint(x: 98, y: 772), withAttributes: detailAttributes)

let maxWidth: CGFloat = 1248
let maxHeight: CGFloat = 680
let scale = min(maxWidth / source.size.width, maxHeight / source.size.height)
let imageSize = NSSize(width: source.size.width * scale, height: source.size.height * scale)
let imageRect = NSRect(
    x: (size.width - imageSize.width) / 2,
    y: 56,
    width: imageSize.width,
    height: imageSize.height
)

NSColor.black.withAlphaComponent(0.55).setFill()
NSBezierPath(rect: imageRect.insetBy(dx: -18, dy: -18)).fill()
source.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: 1)
ink.setStroke()
let border = NSBezierPath(rect: imageRect)
border.lineWidth = 2
border.stroke()

canvas.unlockFocus()

guard let tiff = canvas.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:]) else {
    fputs("could not encode output image\n", stderr)
    exit(4)
}

try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
try png.write(to: output, options: .atomic)

