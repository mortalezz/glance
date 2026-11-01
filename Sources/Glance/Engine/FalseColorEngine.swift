import Foundation
import CoreGraphics
import Accelerate

/// Professional ARRI-style False Color exposure verification engine mapping Rec.709 scene luminance
/// to standard 0–100 IRE exposure zones (Purple for shadow crush, Blue for shadow detail, Green for 18% gray,
/// Pink for Caucasian skin tones, Orange for high highlights, Yellow for near-clipping, Red for blown highlights,
/// with intermediate values preserved as natural monochrome grayscale).
public enum FalseColorEngine {
    /// 256-entry lookup table mapping 8-bit Rec.709 luminance (0..255) to ARRI False Color RGBA pixels
    private static let lut: [(r: UInt8, g: UInt8, b: UInt8, a: UInt8)] = {
        var table = [(r: UInt8, g: UInt8, b: UInt8, a: UInt8)](repeating: (0, 0, 0, 255), count: 256)
        for y in 0...255 {
            let ire = Double(y) * 100.0 / 255.0
            if ire >= 99.0 {
                // Blown Specular Highlights / Sensor Clip: Pure Red (#FF002B)
                table[y] = (255, 0, 43, 255)
            } else if ire >= 97.0 {
                // Near-Clipping Warning / Roll-off: Bright Yellow (#FFE600)
                table[y] = (255, 230, 0, 255)
            } else if ire >= 78.0 && ire <= 82.0 {
                // High Highlights / Specular Skin: Amber Orange (#FF7A00)
                table[y] = (255, 122, 0, 255)
            } else if ire >= 52.0 && ire <= 56.0 {
                // Caucasian / Fair Skin Tone Reference: Orchid Pink (#FF66B2)
                table[y] = (255, 102, 178, 255)
            } else if ire >= 38.0 && ire <= 42.0 {
                // 18% Neutral Gray Card Reference: Kelly Green (#00E64D)
                table[y] = (0, 230, 77, 255)
            } else if ire >= 2.5 && ire <= 4.0 {
                // Deep Shadow Detail (Above Crush): Cyan-Blue (#007AFF)
                table[y] = (0, 122, 255, 255)
            } else if ire <= 2.5 {
                // Crushed Blacks / Underexposed Noise Floor: Neon Purple (#8B1FA2)
                table[y] = (139, 31, 162, 255)
            } else {
                // Natural Monochrome Grayscale for contextual midtones
                let v = UInt8(y)
                table[y] = (v, v, v, 255)
            }
        }
        return table
    }()

    /// Inspects the pixels of `cgImage` and returns a real-time ARRI False Color `CGImage`.
    public static func generateFalseColorImage(for cgImage: CGImage) -> CGImage? {
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0 && height > 0 else { return nil }

        // Bounding resolution for instant 120 FPS real-time generation (max 1920 dimension)
        let maxDim = max(width, height)
        let scale: CGFloat = maxDim > 1920 ? (1920.0 / CGFloat(maxDim)) : 1.0
        let targetW = max(1, Int(CGFloat(width) * scale))
        let targetH = max(1, Int(CGFloat(height) * scale))

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var format = vImage_CGImageFormat(
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            colorSpace: Unmanaged.passUnretained(colorSpace),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            version: 0,
            decode: nil,
            renderingIntent: .defaultIntent
        )

        var srcBuf = vImage_Buffer()
        guard vImageBuffer_InitWithCGImage(&srcBuf, &format, nil, cgImage, vImage_Flags(kvImageNoFlags)) == kvImageNoError else {
            return nil
        }
        defer { free(srcBuf.data) }

        var workBuf = vImage_Buffer()
        if scale < 1.0 {
            guard vImageBuffer_Init(&workBuf, vImagePixelCount(targetH), vImagePixelCount(targetW), 32, vImage_Flags(kvImageNoFlags)) == kvImageNoError else {
                return nil
            }
            _ = vImageScale_ARGB8888(&srcBuf, &workBuf, nil, vImage_Flags(kvImageHighQualityResampling))
        } else {
            workBuf = srcBuf
        }
        defer {
            if scale < 1.0 {
                free(workBuf.data)
            }
        }

        let w = Int(workBuf.width)
        let h = Int(workBuf.height)
        let bytesPerRow = w * 4
        var falseColorData = [UInt8](repeating: 0, count: h * bytesPerRow)

        let srcPtr = workBuf.data.assumingMemoryBound(to: UInt8.self)
        let srcRowBytes = workBuf.rowBytes
        let localLut = lut

        for y in 0..<h {
            let rowSrc = srcPtr.advanced(by: y * srcRowBytes)
            let rowDst = y * bytesPerRow

            for x in 0..<w {
                let px = x * 4
                let r = Int(rowSrc[px])
                let g = Int(rowSrc[px + 1])
                let b = Int(rowSrc[px + 2])

                // Standard Rec.709 integer luma: (54*R + 183*G + 19*B) >> 8
                let lum = (54 * r + 183 * g + 19 * b) >> 8
                let mapped = localLut[max(0, min(255, lum))]

                let dst = rowDst + px
                falseColorData[dst] = mapped.r
                falseColorData[dst + 1] = mapped.g
                falseColorData[dst + 2] = mapped.b
                falseColorData[dst + 3] = mapped.a
            }
        }

        guard let ctx = CGContext(
            data: &falseColorData,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        return ctx.makeImage()
    }
}
