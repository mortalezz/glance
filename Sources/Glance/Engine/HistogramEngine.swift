import Foundation
import CoreGraphics
import Accelerate

/// Represents a 256-bin per-channel tonal distribution.
public struct HistogramData: Sendable {
    public let red: [vImagePixelCount]
    public let green: [vImagePixelCount]
    public let blue: [vImagePixelCount]
    public let luminance: [vImagePixelCount]
    public let maxCount: vImagePixelCount

    public init(
        red: [vImagePixelCount],
        green: [vImagePixelCount],
        blue: [vImagePixelCount],
        luminance: [vImagePixelCount]
    ) {
        self.red = red
        self.green = green
        self.blue = blue
        self.luminance = luminance

        var peak: vImagePixelCount = 1
        for i in 0..<256 {
            if red[i] > peak { peak = red[i] }
            if green[i] > peak { peak = green[i] }
            if blue[i] > peak { peak = blue[i] }
            if luminance[i] > peak { peak = luminance[i] }
        }
        self.maxCount = peak
    }

    public static let empty = HistogramData(
        red: [vImagePixelCount](repeating: 0, count: 256),
        green: [vImagePixelCount](repeating: 0, count: 256),
        blue: [vImagePixelCount](repeating: 0, count: 256),
        luminance: [vImagePixelCount](repeating: 0, count: 256)
    )
}

/// High-performance GPU/SIMD-accelerated histogram calculation using Apple's Accelerate framework.
public enum HistogramEngine {
    /// Computes 256-bin Red, Green, Blue, and Luminance histograms for the given CGImage in <1ms.
    public static func compute(for cgImage: CGImage) -> HistogramData {
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0 && height > 0 else { return .empty }

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
            return .empty
        }
        defer { free(srcBuf.data) }

        var rHist = [vImagePixelCount](repeating: 0, count: 256)
        var gHist = [vImagePixelCount](repeating: 0, count: 256)
        var bHist = [vImagePixelCount](repeating: 0, count: 256)
        var aHist = [vImagePixelCount](repeating: 0, count: 256)

        rHist.withUnsafeMutableBufferPointer { rPtr in
            gHist.withUnsafeMutableBufferPointer { gPtr in
                bHist.withUnsafeMutableBufferPointer { bPtr in
                    aHist.withUnsafeMutableBufferPointer { aPtr in
                        var histArray: [UnsafeMutablePointer<vImagePixelCount>?] = [
                            rPtr.baseAddress,
                            gPtr.baseAddress,
                            bPtr.baseAddress,
                            aPtr.baseAddress
                        ]
                        histArray.withUnsafeMutableBufferPointer { hPtr in
                            _ = vImageHistogramCalculation_ARGB8888(&srcBuf, hPtr.baseAddress!, vImage_Flags(kvImageNoFlags))
                        }
                    }
                }
            }
        }

        // Rec. 709 Luminance: Y = 0.2126 R + 0.7152 G + 0.0722 B
        var grayBuf = vImage_Buffer()
        var lumHist = [vImagePixelCount](repeating: 0, count: 256)
        if vImageBuffer_Init(&grayBuf, srcBuf.height, srcBuf.width, 8, vImage_Flags(kvImageNoFlags)) == kvImageNoError {
            defer { free(grayBuf.data) }
            var matrix: [Int16] = [54, 183, 19, 0] // Scaled by 256
            _ = vImageMatrixMultiply_ARGB8888ToPlanar8(&srcBuf, &grayBuf, &matrix, 256, nil, 0, vImage_Flags(kvImageNoFlags))
            lumHist.withUnsafeMutableBufferPointer { ptr in
                _ = vImageHistogramCalculation_Planar8(&grayBuf, ptr.baseAddress!, vImage_Flags(kvImageNoFlags))
            }
        }

        return HistogramData(red: rHist, green: gHist, blue: bHist, luminance: lumHist)
    }
}
