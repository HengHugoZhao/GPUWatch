// Draws the app icon: eight GPU slots, some free. Usage: swift scripts/make_icon.swift out.png
import AppKit

let size: CGFloat = 1024
let outputPath = CommandLine.arguments[1]

let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
    // macOS expects the icon body on an 824pt rounded square inside the 1024pt canvas.
    let body = NSRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = NSBezierPath(roundedRect: body, xRadius: 186, yRadius: 186)
    NSGradient(
        starting: NSColor(srgbRed: 0.17, green: 0.19, blue: 0.23, alpha: 1),
        ending: NSColor(srgbRed: 0.07, green: 0.08, blue: 0.10, alpha: 1)
    )?.draw(in: bodyPath, angle: -90)

    let free = NSColor(srgbRed: 0.05, green: 0.70, blue: 0.20, alpha: 1)
    let partial = NSColor(srgbRed: 0.98, green: 0.70, blue: 0.10, alpha: 1)
    let busy = NSColor(white: 1, alpha: 0.20)
    let slots: [[NSColor]] = [
        [free, free, busy, busy],
        [partial, busy, busy, busy],
    ]

    let slotSize: CGFloat = 138
    let gap: CGFloat = 32
    let gridWidth = slotSize * 4 + gap * 3
    let gridHeight = slotSize * 2 + gap
    let originX = body.midX - gridWidth / 2
    let originY = body.midY - gridHeight / 2

    for (row, colors) in slots.enumerated() {
        for (column, color) in colors.enumerated() {
            let rect = NSRect(
                x: originX + CGFloat(column) * (slotSize + gap),
                y: originY + CGFloat(1 - row) * (slotSize + gap),
                width: slotSize,
                height: slotSize
            )
            color.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 30, yRadius: 30).fill()
        }
    }
    return true
}

guard let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("Couldn't render the icon")
}
try png.write(to: URL(fileURLWithPath: outputPath))
