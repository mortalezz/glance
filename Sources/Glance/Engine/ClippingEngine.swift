import Foundation
import CoreGraphics
import Accelerate

/// Generates high-contrast camera-style exposure clipping masks ("blinkies")
/// highlighting blown highlights (>99.5% luminance) in pure warning red and crushed shadows (<0.5%) in pure warning blue.
public enum ClippingEngine {
    /// Inspects the pixels of `cgImage` and returns an RGBA clipping mask `CGImage`,
    /// or `nil` if neither highlights nor shadows are clipped.
    public static func generateClippingMask(for cgImage: CGImage) -> CGImage? {
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0 && height > 0 else { return nil }

        // Bounding resolution for fast real-time mask generation (max 1920 dimension)
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
        var maskData = [UInt8](repeating: 0, count: h * bytesPerRow)

        let srcPtr = workBuf.data.assumingMemoryBound(to: UInt8.self)
        let srcRowBytes = workBuf.rowBytes
        var hasClipping = false

        for y in 0..<h {
            let rowSrc = srcPtr.advanced(by: y * srcRowBytes)
            let rowDst = y * bytesPerRow

            for x in 0..<w {
                let px = x * 4
                let r = rowSrc[px]
                let g = rowSrc[px + 1]
                let b = rowSrc[px + 2]

                let dst = rowDst + px

                if r >= 254 || g >= 254 || b >= 254 {
                    // Blown highlights: Warning Red (#FF0033)
                    maskData[dst] = 255
                    maskData[dst + 1] = 0
                    maskData[dst + 2] = 50
                    maskData[dst + 3] = 225
                    hasClipping = true
                } else if r <= 2 && g <= 2 && b <= 2 {
                    // Crushed shadows: Warning Blue (#0066FF)
                    maskData[dst] = 0
                    maskData[dst + 1] = 100
                    maskData[dst + 2] = 255
                    maskData[dst + 3] = 225
                    hasClipping = true
                }
            }
        }

        guard hasClipping else { return nil }

        guard let ctx = CGContext(
            data: &maskData,
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
