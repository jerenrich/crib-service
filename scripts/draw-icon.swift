import AppKit
import CoreGraphics
let size = 1024
if let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) {
    context.setFillColor(CGColor(red: 0.05, green: 0.09, blue: 0.14, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: size, height: size))
    context.setFillColor(CGColor(red: 0.55, green: 0.86, blue: 0.76, alpha: 1)); context.fillEllipse(in: CGRect(x: 208, y: 208, width: 608, height: 608))
    context.setFillColor(CGColor(red: 0.05, green: 0.09, blue: 0.14, alpha: 1)); context.fillEllipse(in: CGRect(x: 410, y: 365, width: 500, height: 500))
    context.setFillColor(CGColor(red: 0.55, green: 0.86, blue: 0.76, alpha: 1))
    for (x, height) in [(540, 100), (615, 180), (690, 260), (765, 140)] {
        context.addPath(CGPath(roundedRect: CGRect(x: x, y: 300 - height / 2, width: 38, height: height), cornerWidth: 19, cornerHeight: 19, transform: nil)); context.fillPath()
    }
    if let image = context.makeImage(), let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
        try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
    }
}
