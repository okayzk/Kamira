// Writes the app icon at one size. The drawing itself is AppMark.drawAppIcon in
// Sources/App/AppMark.swift, shared with the menu bar icon; scripts/make_icon.sh
// compiles the two files together and turns the sizes into AppIcon.icns.
//
//   make_icon <size in pixels> <output.png>
import AppKit

@main
struct MakeIcon {
    static func main() throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 3, let size = Double(arguments[1]) else {
            FileHandle.standardError.write(Data("usage: make_icon <size> <output.png>\n".utf8))
            exit(2)
        }
        let side = CGFloat(size)
        let context = CGContext(data: nil, width: Int(side), height: Int(side), bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let unit = side / 1024
        context.scaleBy(x: unit, y: unit)
        AppMark.drawAppIcon(in: context, unit: unit)
        let bitmap = NSBitmapImageRep(cgImage: context.makeImage()!)
        try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: arguments[2]))
    }
}
