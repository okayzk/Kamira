import AppKit
import ImageIO
import UniformTypeIdentifiers

// What the test groups share: the check itself, and pictures to test with.

var failures = 0
func check(_ condition: Bool, _ message: String, file: String = #fileID, line: Int = #line) {
    if condition { return }
    failures += 1
    print("FAIL (\(file):\(line)): \(message)")
}

/// Encodes a solid-colour bitmap of the given pixel size, tagged with a DPI.
func makeImageData(width: Int, height: Int, dpi: Double, type: UTType) -> Data {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let out = NSMutableData()
    let destination = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil)!
    let properties: [CFString: Any] = [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi]
    CGImageDestinationAddImage(destination, context.makeImage()!, properties as CFDictionary)
    CGImageDestinationFinalize(destination)
    return out as Data
}

func isPNG(_ data: Data) -> Bool { data.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]) }

/// An 800 × 400 pixel PNG at 144 dpi: a Retina capture of 400 × 200 points.
let retinaPNG = makeImageData(width: 800, height: 400, dpi: 144, type: .png)

/// Reads one pixel (x from the left, y from the top) as 0...1 RGB.
func pixel(_ image: CGImage, x: Int, y: Int) -> (r: Double, g: Double, b: Double) {
    var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
    let context = CGContext(data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8,
                            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    let i = (y * image.width + x) * 4
    return (Double(bytes[i]) / 255, Double(bytes[i + 1]) / 255, Double(bytes[i + 2]) / 255)
}
