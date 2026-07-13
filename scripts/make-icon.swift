// Generates AppIcon.icns: dark rounded-square with a glowing notch cutout.
// Run by scripts/bundle.sh; requires only CoreGraphics + iconutil.
import AppKit

func drawIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else {
        image.unlockFocus()
        return image
    }
    let s = size
    // Background: dark gradient rounded square (macOS icon grid inset ~10%).
    let inset = s * 0.09
    let bgRect = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let bgPath = CGPath(roundedRect: bgRect, cornerWidth: s * 0.2, cornerHeight: s * 0.2, transform: nil)
    ctx.addPath(bgPath)
    ctx.clip()
    let colors = [
        CGColor(red: 0.13, green: 0.14, blue: 0.18, alpha: 1),
        CGColor(red: 0.03, green: 0.03, blue: 0.05, alpha: 1),
    ] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(
        gradient,
        start: CGPoint(x: s / 2, y: s), end: CGPoint(x: s / 2, y: 0), options: []
    )
    // Screen: subtle blue glow area under the notch.
    let screenRect = CGRect(x: bgRect.minX + s * 0.06, y: bgRect.minY + s * 0.06,
                            width: bgRect.width - s * 0.12, height: bgRect.height - s * 0.12)
    let screenPath = CGPath(roundedRect: screenRect, cornerWidth: s * 0.09, cornerHeight: s * 0.09, transform: nil)
    ctx.addPath(screenPath)
    ctx.setFillColor(CGColor(red: 0.10, green: 0.35, blue: 0.90, alpha: 0.55))
    ctx.fillPath()
    // Notch: black rounded tab hanging from the top edge of the screen.
    let notchWidth = screenRect.width * 0.42
    let notchHeight = s * 0.085
    let notchRect = CGRect(
        x: screenRect.midX - notchWidth / 2,
        y: screenRect.maxY - notchHeight,
        width: notchWidth, height: notchHeight
    )
    let notch = CGMutablePath()
    let r = notchHeight * 0.45
    notch.move(to: CGPoint(x: notchRect.minX, y: notchRect.maxY))
    notch.addLine(to: CGPoint(x: notchRect.minX, y: notchRect.minY + r))
    notch.addQuadCurve(to: CGPoint(x: notchRect.minX + r, y: notchRect.minY),
                       control: CGPoint(x: notchRect.minX, y: notchRect.minY))
    notch.addLine(to: CGPoint(x: notchRect.maxX - r, y: notchRect.minY))
    notch.addQuadCurve(to: CGPoint(x: notchRect.maxX, y: notchRect.minY + r),
                       control: CGPoint(x: notchRect.maxX, y: notchRect.minY))
    notch.addLine(to: CGPoint(x: notchRect.maxX, y: notchRect.maxY))
    notch.closeSubpath()
    ctx.addPath(notch)
    ctx.setFillColor(CGColor(gray: 0, alpha: 1))
    ctx.fillPath()
    // Live-activity dots beside the notch.
    ctx.setFillColor(CGColor(red: 0.2, green: 0.85, blue: 0.4, alpha: 1))
    let dotR = s * 0.018
    ctx.fillEllipse(in: CGRect(x: notchRect.minX - dotR * 4, y: notchRect.midY - dotR,
                               width: dotR * 2, height: dotR * 2))
    ctx.setFillColor(CGColor(red: 1, green: 0.6, blue: 0.2, alpha: 1))
    ctx.fillEllipse(in: CGRect(x: notchRect.maxX + dotR * 2, y: notchRect.midY - dotR,
                               width: dotR * 2, height: dotR * 2))
    image.unlockFocus()
    return image
}

let iconset = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for (name, px) in [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
] {
    let image = drawIcon(size: CGFloat(px))
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { continue }
    try? png.write(to: iconset.appendingPathComponent("\(name).png"))
}
print("iconset written")
