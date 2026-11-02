import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Represents a successfully decoded image along with its metadata and origin dimensions.
public struct DecodedImage: @unchecked Sendable {
    public let image: CGImage
    public let originalWidth: Int
    public let originalHeight: Int
    public let isDownscaled: Bool
    public let isRaw: Bool
    public let exif: ExifMetadata?

    public var aspectRatio: CGFloat {
        guard originalHeight > 0 else { return 1.0 }
        return CGFloat(originalWidth) / CGFloat(originalHeight)
    }

    public init(
        image: CGImage,
        originalWidth: Int,
        originalHeight: Int,
        isDownscaled: Bool,
        isRaw: Bool = false,
        exif: ExifMetadata? = nil
    ) {
        self.image = image
        self.originalWidth = originalWidth
        self.originalHeight = originalHeight
        self.isDownscaled = isDownscaled
        self.isRaw = isRaw
        self.exif = exif
    }
}

/// Thread-safe, high-performance image decoder wrapping ImageIO.
/// Performs memory-mapped reads and display-scaled thumbnail generation to ensure
/// high framerate directory traversal even with 50MP+ RAW and raster files.
public final class ImageDecoder: Sendable {
    public static let shared = ImageDecoder()

    public init() {}

    /// Decodes an image from disk at `url`, optionally downscaling to `maxBoundingPixelSize`.
    ///
    /// - Parameters:
    ///   - url: File URL of the image to decode.
    ///   - maxBoundingPixelSize: The maximum dimension (width or height) in device pixels.
    ///                           Pass `nil` or `0` to request full original sensor resolution.
    /// - Returns: `DecodedImage` containing the decoded CGImage and metadata.
    public func decode(
        at url: URL,
        maxBoundingPixelSize: Int? = nil
    ) throws -> DecodedImage {
        let isRawFile = SupportedFormats.isRaw(url: url)

        // 1. Create ImageSource from URL with memory-mapped hints
        let sourceOptions: [CFString: Any] = [
            kCGImageSourceShouldCache: false
        ]

        var imageSource: CGImageSource
        if let src = CGImageSourceCreateWithURL(url as CFURL, sourceOptions as CFDictionary) {
            imageSource = src
        } else {
            // Fallback: try loading file data directly with memory mapping
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
                throw NSError(domain: "ImageDecoder", code: 400, userInfo: [
                    NSLocalizedDescriptionKey: "Could not read file at \(url.path)"
                ])
            }
            guard let src = CGImageSourceCreateWithData(data as CFData, sourceOptions as CFDictionary) else {
                throw NSError(domain: "ImageDecoder", code: 400, userInfo: [
                    NSLocalizedDescriptionKey: "Unsupported or corrupt image at \(url.path)"
                ])
            }
            imageSource = src
        }

        // 3. Query image properties (dimensions, EXIF) without decoding full bitmap
        var originalWidth = 0
        var originalHeight = 0
        var parsedExif: ExifMetadata? = nil
        var headerOrientation = 1
        if let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any] {
            let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
            let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
            headerOrientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1

            // Orientations 5, 6, 7, 8 swap width & height
            if [5, 6, 7, 8].contains(headerOrientation) {
                originalWidth = height
                originalHeight = width
            } else {
                originalWidth = width
                originalHeight = height
            }

            parsedExif = ExifMetadata(from: properties)
        }

        // Camera Profile extraction on background worker thread (avoids main-thread disk read / stalling)
        if parsedExif?.pictureControl == nil, let extracted = CameraProfileEngine.extractCameraProfile(from: url) {
            parsedExif = parsedExif?.withPictureControl(extracted)
        }

        // Sidecar orientation override for RAW files (which aren't modified in place)
        var effectiveOrientation = headerOrientation
        if isRawFile, let sidecarMeta = XmpSidecarManager.readMetadata(for: url), let sOrient = sidecarMeta.orientation {
            effectiveOrientation = sOrient
            if [5, 6, 7, 8].contains(sOrient) {
                let maxDim = max(originalWidth, originalHeight)
                let minDim = min(originalWidth, originalHeight)
                originalWidth = minDim
                originalHeight = maxDim
            }
        }

        let maxOriginalDim = max(originalWidth, originalHeight)
        let targetBoundingSize = maxBoundingPixelSize ?? 4096

        // Determine if downscaling is applicable
        let shouldDownscale = maxOriginalDim > targetBoundingSize && targetBoundingSize > 0

        // 3b. FAST EMBEDDED PREVIEW EXTRACTION FOR RAW-ONLY SHOOTERS
        // When browsing standalone RAW files (shouldDownscale == true), extract the camera-generated
        // embedded JPEG preview in sub-5ms, completely bypassing costly 150-300ms sensor demosaicing.
        // Full raw demosaicing is deferred until the user initiates 100% 1:1 Pixel Peep (Z).
        if isRawFile && shouldDownscale {
            let embeddedOptions: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageIfAbsent: false,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: targetBoundingSize,
                kCGImageSourceShouldCacheImmediately: true
            ]
            let sourceCount = CGImageSourceGetCount(imageSource)
            for idx in 0..<sourceCount {
                if let embeddedThumb = CGImageSourceCreateThumbnailAtIndex(imageSource, idx, embeddedOptions as CFDictionary) {
                    let thumbMaxDim = max(embeddedThumb.width, embeddedThumb.height)
                    let requiredMinDim = min(maxOriginalDim, targetBoundingSize)
                    if thumbMaxDim >= requiredMinDim {
                        let orientedThumb = Self.applyOrientationDelta(
                            image: embeddedThumb,
                            from: headerOrientation,
                            to: effectiveOrientation
                        )
                        return DecodedImage(
                            image: orientedThumb,
                            originalWidth: originalWidth > 0 ? originalWidth : orientedThumb.width,
                            originalHeight: originalHeight > 0 ? originalHeight : orientedThumb.height,
                            isDownscaled: true,
                            isRaw: true,
                            exif: parsedExif
                        )
                    }
                }
            }
        }

        // 4. Configure ImageIO Thumbnail options
        // Using thumbnail creation with kCGImageSourceCreateThumbnailWithTransform handles
        // EXIF orientation automatically and leverages IDCT/Wavelet downscaling in decoders.
        var thumbOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true, // Auto-rotate with EXIF!
            kCGImageSourceShouldCacheImmediately: true       // Force decode on worker thread!
        ]

        if shouldDownscale {
            thumbOptions[kCGImageSourceThumbnailMaxPixelSize] = targetBoundingSize
        } else if maxOriginalDim > 0 {
            // Keep original max dimension if smaller than screen
            thumbOptions[kCGImageSourceThumbnailMaxPixelSize] = maxOriginalDim
        }

        // Decode directly via ImageIO thumbnail pipeline
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, thumbOptions as CFDictionary) else {
            // Fallback: try direct image decode if thumbnail creation fails
            let fallbackOptions: [CFString: Any] = [
                kCGImageSourceShouldCacheImmediately: true
            ]
            if let directImage = CGImageSourceCreateImageAtIndex(imageSource, 0, fallbackOptions as CFDictionary) {
                let orientedDirect = Self.applyOrientationDelta(
                    image: directImage,
                    from: headerOrientation,
                    to: effectiveOrientation
                )
                return DecodedImage(
                    image: orientedDirect,
                    originalWidth: originalWidth > 0 ? originalWidth : orientedDirect.width,
                    originalHeight: originalHeight > 0 ? originalHeight : orientedDirect.height,
                    isDownscaled: false,
                    isRaw: isRawFile,
                    exif: parsedExif
                )
            }
            throw NSError(domain: "ImageDecoder", code: 422, userInfo: [
                NSLocalizedDescriptionKey: "Failed to decode image at \(url.path)"
            ])
        }

        let orientedImage = Self.applyOrientationDelta(
            image: cgImage,
            from: headerOrientation,
            to: effectiveOrientation
        )

        return DecodedImage(
            image: orientedImage,
            originalWidth: originalWidth > 0 ? originalWidth : orientedImage.width,
            originalHeight: originalHeight > 0 ? originalHeight : orientedImage.height,
            isDownscaled: shouldDownscale,
            isRaw: isRawFile,
            exif: parsedExif
        )
    }

    // MARK: - Orientation Helpers

    private static func applyOrientationDelta(image: CGImage, from headerOrient: Int, to effectiveOrient: Int) -> CGImage {
        guard headerOrient != effectiveOrient else { return image }
        let degFrom = degreesFromOrientation(headerOrient)
        let degTo = degreesFromOrientation(effectiveOrient)
        let deltaDeg = (degTo - degFrom + 360) % 360
        guard deltaDeg != 0 else { return image }
        return rotateCGImage(image, degreesCW: deltaDeg)
    }

    private static func degreesFromOrientation(_ orient: Int) -> Int {
        switch orient {
        case 6: return 90
        case 3: return 180
        case 8: return 270
        default: return 0
        }
    }

    private static func rotateCGImage(_ image: CGImage, degreesCW: Int) -> CGImage {
        let w = image.width
        let h = image.height
        let colorSpace = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = image.bitmapInfo.rawValue

        let outW: Int
        let outH: Int
        let transform: CGAffineTransform

        switch degreesCW {
        case 90:
            outW = h
            outH = w
            transform = CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: CGFloat(w))
        case 180:
            outW = w
            outH = h
            transform = CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: CGFloat(w), ty: CGFloat(h))
        case 270:
            outW = h
            outH = w
            transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: CGFloat(h), ty: 0)
        default:
            return image
        }

        guard let ctx = CGContext(
            data: nil,
            width: outW,
            height: outH,
            bitsPerComponent: image.bitsPerComponent,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return image }

        ctx.concatenate(transform)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? image
    }
}
