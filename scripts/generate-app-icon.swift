import AppKit

// A small native vector mark. Keep the drawing source alongside the generated icon.
let size = NSSize(width: 1024, height: 1024)
guard let context = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8,
    bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
else { fatalError("Could not create icon canvas") }
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
NSColor.black.setFill()
NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
NSColor.white.setStroke()
let card = NSBezierPath(roundedRect: NSRect(x: 180, y: 120, width: 664, height: 784), xRadius: 24, yRadius: 24)
card.lineWidth = 12
card.stroke()
let text = NSAttributedString(string: "R", attributes: [.font: NSFont.systemFont(ofSize: 560, weight: .regular), .foregroundColor: NSColor.white])
text.draw(at: NSPoint(x: (1024 - text.size().width) / 2, y: (1024 - text.size().height) / 2))
NSGraphicsContext.restoreGraphicsState()
guard let image = context.makeImage(),
      let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { fatalError("Could not render app icon") }
let output = URL(fileURLWithPath: "ios/Reed/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png")
try png.write(to: output, options: .atomic)
