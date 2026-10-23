import AppKit
import CoreGraphics
import ImageIO

// Export the checked-in bellhop artwork rather than recreating the retired moon icon.
// Usage: swift scripts/draw-icon.swift [destination.png]
// With no destination, refresh both the iPhone and Watch asset catalogs.
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let sourceURL = root.appendingPathComponent("artwork/crib-service-icon.png")
guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
      let artwork = CGImageSourceCreateImageAtIndex(source, 0, nil),
      artwork.width == artwork.height else {
    fatalError("Expected square source artwork at \(sourceURL.path)")
}

let size = 1024
guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
      let context = CGContext(data: nil, width: size, height: size,
                              bitsPerComponent: 8, bytesPerRow: size * 4,
                              space: colorSpace,
                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
    fatalError("Could not create the opaque app icon canvas")
}
context.interpolationQuality = .high
context.draw(artwork, in: CGRect(x: 0, y: 0, width: size, height: size))
guard let image = context.makeImage(),
      let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
    fatalError("Could not encode the app icon")
}

let destinations: [URL]
if CommandLine.arguments.count == 2 {
    destinations = [URL(fileURLWithPath: CommandLine.arguments[1])]
} else if CommandLine.arguments.count == 1 {
    destinations = ["BabyCryMonitor", "BabyCryWatch"].map {
        root.appendingPathComponent("ios/\($0)/Assets.xcassets/AppIcon.appiconset/AppIcon.png")
    }
} else {
    fatalError("Usage: swift scripts/draw-icon.swift [destination.png]")
}
for destination in destinations {
    try png.write(to: destination, options: .atomic)
    print("Exported 1024×1024 opaque icon: \(destination.path)")
}
