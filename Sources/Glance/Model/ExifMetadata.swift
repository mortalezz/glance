import Foundation
import CoreGraphics
import ImageIO

/// Represents extracted EXIF and TIFF camera metadata for a photo.
public struct ExifMetadata: Sendable {
    public let cameraMake: String?
    public let cameraModel: String?
    public let lensModel: String?
    public let shutterSpeed: Double?
    public let aperture: Double?
    public let iso: Int?
    public let focalLength: Double?
    public let focalLength35mm: Int?
    public let exposureBias: Double?
    public let flashFired: Bool?
    public let dateTimeOriginal: String?
    public let pictureControl: String?

    public init(
        cameraMake: String? = nil,
        cameraModel: String? = nil,
        lensModel: String? = nil,
        shutterSpeed: Double? = nil,
        aperture: Double? = nil,
        iso: Int? = nil,
        focalLength: Double? = nil,
        focalLength35mm: Int? = nil,
        exposureBias: Double? = nil,
        flashFired: Bool? = nil,
        dateTimeOriginal: String? = nil,
        pictureControl: String? = nil
    ) {
        self.cameraMake = cameraMake
        self.cameraModel = cameraModel
        self.lensModel = lensModel
        self.shutterSpeed = shutterSpeed
        self.aperture = aperture
        self.iso = iso
        self.focalLength = focalLength
        self.focalLength35mm = focalLength35mm
        self.exposureBias = exposureBias
        self.flashFired = flashFired
        self.dateTimeOriginal = dateTimeOriginal
        self.pictureControl = pictureControl
    }

    /// Parses EXIF and TIFF dictionaries from standard ImageIO properties dictionary.
    public init(from properties: [CFString: Any]) {
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]

        // 1. Camera Make & Model
        let rawMake = (tiff?[kCGImagePropertyTIFFMake] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawModel = (tiff?[kCGImagePropertyTIFFModel] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

        self.cameraMake = rawMake
        self.cameraModel = rawModel

        // 2. Lens Model
        self.lensModel = (exif?[kCGImagePropertyExifLensModel] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

        // 3. Shutter Speed (Exposure Time)
        self.shutterSpeed = exif?[kCGImagePropertyExifExposureTime] as? Double

        // 4. Aperture (FNumber)
        self.aperture = exif?[kCGImagePropertyExifFNumber] as? Double

        // 5. ISO
        if let isoArray = exif?[kCGImagePropertyExifISOSpeedRatings] as? [Int], let first = isoArray.first {
            self.iso = first
        } else if let isoVal = exif?[kCGImagePropertyExifISOSpeedRatings] as? Int {
            self.iso = isoVal
        } else if let isoArrayNum = exif?[kCGImagePropertyExifISOSpeedRatings] as? [NSNumber], let first = isoArrayNum.first {
            self.iso = first.intValue
        } else {
            self.iso = nil
        }

        // 6. Focal Length
        self.focalLength = exif?[kCGImagePropertyExifFocalLength] as? Double
        self.focalLength35mm = exif?[kCGImagePropertyExifFocalLenIn35mmFilm] as? Int

        // 7. Exposure Bias
        self.exposureBias = exif?[kCGImagePropertyExifExposureBiasValue] as? Double

        // 8. Flash
        if let flashInt = exif?[kCGImagePropertyExifFlash] as? Int {
            self.flashFired = (flashInt & 1) != 0
        } else {
            self.flashFired = nil
        }

        // 9. Date Time Original
        self.dateTimeOriginal = exif?[kCGImagePropertyExifDateTimeOriginal] as? String

        // 10. Picture Control / Profile
        if let nikon = properties[kCGImagePropertyMakerNikonDictionary] as? [CFString: Any],
           let picCtrl = nikon["PictureControl" as CFString] as? String {
            self.pictureControl = picCtrl.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            self.pictureControl = nil
        }
    }

    // MARK: - Formatted Readouts

    public var formattedShutter: String? {
        guard let speed = shutterSpeed, speed > 0 else { return nil }
        if speed < 0.8 {
            let recip = round(1.0 / speed)
            return "1/\(Int(recip))s"
        } else if speed == floor(speed) {
            return "\(Int(speed))s"
        } else {
            return String(format: "%.1fs", speed)
        }
    }

    public var formattedAperture: String? {
        guard let f = aperture, f > 0 else { return nil }
        if f == floor(f) {
            return String(format: "ƒ/%.0f", f)
        } else {
            return String(format: "ƒ/%.1f", f)
        }
    }

    public var formattedIso: String? {
        guard let val = iso, val > 0 else { return nil }
        return "ISO \(val)"
    }

    public var formattedFocal: String? {
        guard let f = focalLength, f > 0 else { return nil }
        if f == floor(f) {
            return "\(Int(f))mm"
        } else {
            return String(format: "%.1fmm", f)
        }
    }

    public var formattedBias: String? {
        guard let b = exposureBias, abs(b) > 0.01 else { return nil }
        return String(format: "%+.1f EV", b)
    }

    public var formattedDate: String? {
        guard let raw = dateTimeOriginal else { return nil }
        let parser = DateFormatter()
        parser.dateFormat = "yyyy:MM:dd HH:mm:ss"
        if let date = parser.date(from: raw) {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            return formatter.string(from: date)
        }
        return raw
    }

    /// Clean one-line summary of exposure settings: "1/500s · ƒ/2.8 · ISO 400 · 85mm"
    public var exposureSummary: String {
        var parts: [String] = []
        if let s = formattedShutter { parts.append(s) }
        if let a = formattedAperture { parts.append(a) }
        if let i = formattedIso { parts.append(i) }
        if let f = formattedFocal { parts.append(f) }
        if let b = formattedBias { parts.append(b) }
        return parts.joined(separator: " · ")
    }

    /// Clean camera & lens line: "Sony ILCE-7RM5 · FE 85mm F1.4 GM"
    public var cameraAndLensSummary: String {
        var parts: [String] = []
        if let model = cameraModel {
            if let make = cameraMake, !model.lowercased().contains(make.lowercased()) {
                parts.append("\(make) \(model)")
            } else {
                parts.append(model)
            }
        } else if let make = cameraMake {
            parts.append(make)
        }

        if let lens = lensModel, !lens.isEmpty {
            parts.append(lens)
        }

        return parts.joined(separator: " · ")
    }
}
