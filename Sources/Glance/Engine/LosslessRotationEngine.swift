import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

public enum RotationDirection: Sendable {
    case clockwise          // 90° CW ("]")
    case counterClockwise   // 90° CCW ("[")
}

/// High-performance lossless rotation engine that rotates photos in 90-degree increments
/// by rewriting EXIF orientation headers or syncing Adobe XMP sidecars without re-compressing pixels.
public enum LosslessRotationEngine {
    /// Computes the next EXIF orientation (1..8) when rotating 90° in the specified direction.
    public static func nextOrientation(current: Int, direction: RotationDirection) -> Int {
        let curr = (1...8).contains(current) ? current : 1
        switch direction {
        case .clockwise:
            switch curr {
            case 1: return 6
            case 6: return 3
            case 3: return 8
            case 8: return 1
            case 2: return 7
            case 7: return 4
            case 4: return 5
            case 5: return 2
            default: return 6
            }
        case .counterClockwise:
            switch curr {
            case 1: return 8
            case 8: return 3
            case 3: return 6
            case 6: return 1
            case 2: return 5
            case 5: return 4
            case 4: return 7
            case 7: return 2
            default: return 8
            }
        }
    }

    /// Reads the current EXIF orientation for a given file (checking XMP sidecar first for RAW files).
    public static func currentOrientation(for fileURL: URL) -> Int {
        if let sidecar = XmpSidecarManager.readMetadata(for: fileURL), let sOrient = sidecar.orientation {
            return sOrient
        }
        guard let src = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else {
            return 1
        }
        return (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
    }

    /// Losslessly rotates an image file or paired RAW+JPEG stack.
    ///
    /// - Parameters:
    ///   - item: The `SlideItem` to rotate.
    ///   - direction: The rotation direction (`clockwise` or `counterClockwise`).
    /// - Returns: The new EXIF orientation value (1..8).
    @discardableResult
    public static func rotate(
        item: SlideItem,
        direction: RotationDirection
    ) throws -> Int {
        let curr = currentOrientation(for: item.url)
        let newOrientation = nextOrientation(current: curr, direction: direction)

        let ext = item.url.pathExtension.lowercased()
        let isRaw = SupportedFormats.rawExtensions.contains(ext)

        // 1. If it's a standard compressed image (JPEG, HEIC, PNG, TIFF)
        if !isRaw {
            try rotateLosslessImageFile(fileURL: item.url, newOrientation: newOrientation)
        }

        // 2. If it's a stacked pair with a companion JPEG, rotate the companion losslessly
        if item.isStacked, let comp = item.companionURL, comp.path != item.url.path {
            let compExt = comp.pathExtension.lowercased()
            if !SupportedFormats.rawExtensions.contains(compExt) {
                try? rotateLosslessImageFile(fileURL: comp, newOrientation: newOrientation)
            }
        }

        // 3. For RAW files or when an XMP sidecar exists, write tiff:Orientation to the XMP sidecar
        var sidecarTargets: [URL] = []
        if let raw = item.rawURL {
            sidecarTargets.append(raw)
        }
        if item.isStacked, let comp = item.companionURL, comp.path != item.url.path {
            sidecarTargets.append(comp)
        }
        if sidecarTargets.isEmpty {
            sidecarTargets.append(item.url)
        }

        for targetURL in sidecarTargets {
            let sidecarURL = XmpSidecarManager.targetSidecarURL(for: targetURL)
            var meta = XmpSidecarManager.read(from: sidecarURL)
            meta.orientation = newOrientation
            try? XmpSidecarManager.save(metadata: meta, for: targetURL)
        }

        return newOrientation
    }

    /// Rewrites the EXIF orientation tag in-place without decoding or re-compressing image bitstream.
    private static func rotateLosslessImageFile(fileURL: URL, newOrientation: Int) throws {
        guard let src = CGImageSourceCreateWithURL(fileURL as CFURL, nil) else {
            throw NSError(domain: "LosslessRotationEngine", code: 400, userInfo: [
                NSLocalizedDescriptionKey: "Failed to open image source for \(fileURL.lastPathComponent)"
            ])
        }

        let ext = fileURL.pathExtension.lowercased()
        let utType: UTType = {
            if ext == "heic" { return .heic }
            if ext == "png" { return .png }
            if ext == "tiff" || ext == "tif" { return .tiff }
            return .jpeg
        }()

        let tempURL = fileURL.deletingLastPathComponent().appendingPathComponent(".\(fileURL.lastPathComponent).tmp.\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        guard let dest = CGImageDestinationCreateWithURL(tempURL as CFURL, utType.identifier as CFString, 1, nil) else {
            throw NSError(domain: "LosslessRotationEngine", code: 401, userInfo: [
                NSLocalizedDescriptionKey: "Failed to create image destination for \(fileURL.lastPathComponent)"
            ])
        }

        let copyOptions: [CFString: Any] = [
            kCGImageDestinationOrientation: newOrientation
        ]

        var error: Unmanaged<CFError>?
        guard CGImageDestinationCopyImageSource(dest, src, copyOptions as CFDictionary, &error) else {
            if let cfErr = error?.takeRetainedValue() {
                throw cfErr as Error
            } else {
                throw NSError(domain: "LosslessRotationEngine", code: 402, userInfo: nil)
            }
        }

        _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tempURL)
    }
}
