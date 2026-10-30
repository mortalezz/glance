import Foundation
import CoreGraphics
import Accelerate

/// Real-time camera EVF-style Focus Peaking Engine.
/// Computes 2nd-order spatial gradient Laplacian high-pass convolution via hardware-accelerated
/// `Accelerate.vImage` to detect in-focus high-contrast edges and overlays them in vibrant camera EVF neon green (#00FF50).
public enum FocusPeakingEngine {
    /// Bounding maximum dimension for instantaneous sub-10ms processing across multi-megapixel RAWs.
    private static let maxDimension: CGFloat = 1920.0

    /// Laplacian 3x3 high-pass edge-detection convolution kernel.
    private static let laplacianKernel: [Int16] = [
        -1, -1, -1,
        -1,  8, -1,
        -1, -1, -1
    ]

    /// Inspects `cgImage` and returns an RGBA focus peaking overlay mask `CGImage`
    /// highlighting sharp in-focus edges, or `nil` if no high-contrast edges are detected.
    public static func generatePeakingMask(for cgImage: CGImage, threshold: UInt8 = 30) -> CGImage? {
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0 && height > 0 else { return nil }

        // Bounding resolution for instant sub-10ms real-time mask generation
        let maxDim = max(width, height)
        let scale: CGFloat = CGFloat(maxDim) > maxDimension ? (maxDimension / CGFloat(maxDim)) : 1.0
        let targetW = max(1, Int(CGFloat(width) * scale))
        let targetH = max(1, Int(CGFloat(height) * scale))

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var format = vImage_CGImageFormat(
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            colorSpace: Unmanaged.passRetained(colorSpace),
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

        // Planar 8-bit luminance buffer
        var grayBuf = vImage_Buffer()
        guard vImageBuffer_Init(&grayBuf, vImagePixelCount(h), vImagePixelCount(w), 8, vImage_Flags(kvImageNoFlags)) == kvImageNoError else {
            return nil
        }
        defer { free(grayBuf.data) }

        // Rec. 709 Luminance: 0.2126 R + 0.7152 G + 0.0722 B (matrix coefficients [213, 715, 72, 0] / 1000)
        let matrix: [Int16] = [213, 715, 72, 0]
        vImageMatrixMultiply_ARGB8888ToPlanar8(&workBuf, &grayBuf, matrix, 1000, nil, 0, vImage_Flags(kvImageNoFlags))

        // Planar 8-bit edge buffer
        var edgeBuf = vImage_Buffer()
        guard vImageBuffer_Init(&edgeBuf, vImagePixelCount(h), vImagePixelCount(w), 8, vImage_Flags(kvImageNoFlags)) == kvImageNoError else {
            return nil
        }
        defer { free(edgeBuf.data) }

        // Apply 3x3 Laplacian edge convolution
        vImageConvolve_Planar8(
            &grayBuf,
            &edgeBuf,
            nil,
            0,
            0,
            laplacianKernel,
            3,
            3,
            1,
            0,
            vImage_Flags(kvImageEdgeExtend)
        )

        let bytesPerRow = w * 4
        var maskData = [UInt8](repeating: 0, count: h * bytesPerRow)

        let edgePtr = edgeBuf.data.assumingMemoryBound(to: UInt8.self)
        let edgeRowBytes = edgeBuf.rowBytes
        var hasEdges = false

        for y in 0..<h {
            let rowSrc = edgePtr.advanced(by: y * edgeRowBytes)
            let rowDst = y * bytesPerRow

            for x in 0..<w {
                let edgeVal = rowSrc[x]
                if edgeVal >= threshold {
                    let dst = rowDst + (x * 4)
                    // Camera EVF Neon Green (#00FF50) with high opacity
                    maskData[dst] = 0        // R
                    maskData[dst + 1] = 255  // G
                    maskData[dst + 2] = 80   // B
                    maskData[dst + 3] = 255  // A
                    hasEdges = true
                }
            }
        }

        guard hasEdges else { return nil }

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
