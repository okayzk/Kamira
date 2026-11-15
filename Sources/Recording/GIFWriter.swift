import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Writes an animated GIF one frame at a time, so memory use does not grow with the
/// length of the animation. (ImageIO's own multi-frame writer keeps every frame in
/// memory until the end.) ImageIO still does the hard part: each frame is encoded as a
/// single-image GIF, and its colour table and pixel data are copied into the output.
/// Each frame after the first stores only the pixels that changed, the rest being
/// transparent, which is what keeps screen recordings small; a frame with no change at
/// all just extends the one before it.
final class GIFWriter {
    private let handle: FileHandle
    private let framesPerSecond: Int
    private var wroteHeader = false
    /// Frames accepted so far, used to keep the rounded frame delays from drifting.
    private var frameIndex = 0
    /// The last frame, held back in case the next one changes nothing.
    private var pending: (frame: Frame, hundredths: Int)?
    /// RGBA pixels of what a viewer sees after the frames so far.
    private var canvas: [UInt8] = []
    private var canvasWidth = 0
    private var canvasHeight = 0
    /// Channel difference below which a pixel counts as unchanged (hides video noise).
    private static let tolerance = 4

    private struct Frame {
        var width: UInt16
        var height: UInt16
        var colorTable: Data
        /// GIF image descriptor flag for interlaced pixel data.
        var interlaced: Bool
        /// Colour table index that means "keep what is already there".
        var transparentIndex: UInt8?
        /// LZW minimum code size followed by the data sub-blocks and their terminator.
        var imageData: Data
    }

    init?(url: URL, framesPerSecond: Int) {
        guard framesPerSecond > 0, FileManager.default.createFile(atPath: url.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: url) else { return nil }
        self.handle = handle
        self.framesPerSecond = framesPerSecond
    }

    /// Appends a frame lasting one frame time. Returns false if it could not be encoded.
    func add(_ image: CGImage) -> Bool {
        // GIF delays are whole hundredths of a second; spread the rounding over frames.
        let hundredths = (frameIndex + 1) * 100 / framesPerSecond - frameIndex * 100 / framesPerSecond
        if canvas.isEmpty {
            canvasWidth = image.width
            canvasHeight = image.height
        }
        guard var pixels = Self.pixels(of: image, width: canvasWidth, height: canvasHeight) else { return false }
        var toEncode: CGImage?
        if canvas.isEmpty {
            canvas = pixels
            toEncode = Self.image(from: &pixels, width: canvasWidth, height: canvasHeight, alpha: false)
        } else {
            // Keep only the changed pixels; unchanged ones become transparent.
            var changed = 0
            let tolerance = Self.tolerance
            canvas.withUnsafeMutableBufferPointer { old in
                pixels.withUnsafeMutableBufferPointer { new in
                    var offset = 0
                    while offset < new.count {
                        if abs(Int(new[offset]) - Int(old[offset])) > tolerance
                            || abs(Int(new[offset + 1]) - Int(old[offset + 1])) > tolerance
                            || abs(Int(new[offset + 2]) - Int(old[offset + 2])) > tolerance {
                            old[offset] = new[offset]
                            old[offset + 1] = new[offset + 1]
                            old[offset + 2] = new[offset + 2]
                            changed += 1
                        } else {
                            new[offset] = 0
                            new[offset + 1] = 0
                            new[offset + 2] = 0
                            new[offset + 3] = 0
                        }
                        offset += 4
                    }
                }
            }
            if changed == 0, let last = pending, last.hundredths + hundredths <= 0xFFFF {
                frameIndex += 1
                pending = (last.frame, last.hundredths + hundredths)
                return true
            }
            toEncode = Self.image(from: &pixels, width: canvasWidth, height: canvasHeight, alpha: true)
        }
        guard let source = toEncode, let frame = Self.encode(source) else { return false }
        frameIndex += 1
        flushPending()
        pending = (frame, hundredths)
        return true
    }

    /// Draws `image` into an opaque RGBA buffer of the given size.
    private static func pixels(of image: CGImage, width: Int, height: Int) -> [UInt8]? {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        let drawn: Bool = bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        // The skipped alpha byte is made opaque so it can later mark transparency.
        var offset = 3
        while offset < bytes.count { bytes[offset] = 255; offset += 4 }
        return bytes
    }

    private static func image(from bytes: inout [UInt8], width: Int, height: Int, alpha: Bool) -> CGImage? {
        let info = alpha ? CGImageAlphaInfo.premultipliedLast : CGImageAlphaInfo.noneSkipLast
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: info.rawValue), provider: provider,
                       decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// Completes the file. Returns false if no frame was written.
    func finish() -> Bool {
        flushPending()
        guard wroteHeader else {
            try? handle.close()
            return false
        }
        handle.write(Data([0x3B]))
        try? handle.close()
        return true
    }

    private func flushPending() {
        guard let (frame, hundredths) = pending else { return }
        pending = nil
        var out = Data()
        func append16(_ value: UInt16) { out.append(contentsOf: [UInt8(value & 0xFF), UInt8(value >> 8)]) }
        if !wroteHeader {
            wroteHeader = true
            out.append(Data("GIF89a".utf8))
            append16(frame.width)
            append16(frame.height)
            out.append(contentsOf: [0x70, 0, 0])            // no global colour table
            out.append(contentsOf: [0x21, 0xFF, 0x0B])      // application extension: loop forever
            out.append(Data("NETSCAPE2.0".utf8))
            out.append(contentsOf: [0x03, 0x01, 0, 0, 0])
        }
        // Graphic control: leave the frame in place afterwards, delay, transparent index.
        out.append(contentsOf: [0x21, 0xF9, 0x04, frame.transparentIndex == nil ? 0x04 : 0x05])
        append16(UInt16(hundredths))
        out.append(contentsOf: [frame.transparentIndex ?? 0, 0])
        out.append(0x2C)                                    // image descriptor
        append16(0)
        append16(0)
        append16(frame.width)
        append16(frame.height)
        // A local colour table of 2^(n+1) entries is announced with n in the low bits.
        var sizeBits: UInt8 = 0
        while (3 << (Int(sizeBits) + 1)) < frame.colorTable.count { sizeBits += 1 }
        out.append(0x80 | (frame.interlaced ? 0x40 : 0) | sizeBits)
        out.append(frame.colorTable)
        out.append(frame.imageData)
        handle.write(out)
    }

    /// Encodes one image as a GIF with ImageIO and picks out the parts needed here.
    private static func encode(_ image: CGImage) -> Frame? {
        let buffer = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
                buffer, UTType.gif.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return parse([UInt8](buffer as Data))
    }

    /// Reads the first image of a GIF file: its size, colour table and compressed pixels.
    private static func parse(_ bytes: [UInt8]) -> Frame? {
        guard bytes.count > 13, bytes[0] == 0x47, bytes[1] == 0x49, bytes[2] == 0x46 else { return nil }
        var position = 13
        var table = Data()
        var transparentIndex: UInt8?
        if bytes[10] & 0x80 != 0 {
            let length = 3 << (Int(bytes[10] & 0x07) + 1)
            guard position + length <= bytes.count else { return nil }
            table = Data(bytes[position..<position + length])
            position += length
        }
        /// Moves past a run of length-prefixed sub-blocks, including the zero terminator.
        func skipSubBlocks() -> Bool {
            while position < bytes.count {
                let length = Int(bytes[position])
                position += 1 + length
                if length == 0 { return position <= bytes.count }
            }
            return false
        }
        while position < bytes.count {
            switch bytes[position] {
            case 0x21:                                      // extension: only transparency matters
                if position + 7 < bytes.count, bytes[position + 1] == 0xF9, bytes[position + 3] & 0x01 != 0 {
                    transparentIndex = bytes[position + 6]
                }
                position += 2
                guard skipSubBlocks() else { return nil }
            case 0x2C:                                      // image descriptor
                guard position + 10 <= bytes.count else { return nil }
                let width = UInt16(bytes[position + 5]) | UInt16(bytes[position + 6]) << 8
                let height = UInt16(bytes[position + 7]) | UInt16(bytes[position + 8]) << 8
                let flags = bytes[position + 9]
                position += 10
                if flags & 0x80 != 0 {
                    let length = 3 << (Int(flags & 0x07) + 1)
                    guard position + length <= bytes.count else { return nil }
                    table = Data(bytes[position..<position + length])
                    position += length
                }
                let start = position
                position += 1                               // LZW minimum code size
                guard skipSubBlocks(), !table.isEmpty else { return nil }
                return Frame(width: width, height: height, colorTable: table,
                             interlaced: flags & 0x40 != 0, transparentIndex: transparentIndex,
                             imageData: Data(bytes[start..<position]))
            default:
                return nil
            }
        }
        return nil
    }
}
