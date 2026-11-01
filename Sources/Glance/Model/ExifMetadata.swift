import Foundation
import CoreGraphics
import ImageIO

/// Represents extracted EXIF, TIFF, and MakerNotes camera metadata for a photo.
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

    // Expanded Photographer Metadata
    public let exposureProgramInt: Int?
    public let meteringModeInt: Int?
    public let whiteBalanceInt: Int?
    public let flashInt: Int?
    public let colorSpaceInt: Int?
    public let rawColorSpaceName: String?
    public let lensMake: String?
    public let lensSpecification: String?
    public let maxAperture: Double?
    public let software: String?
    public let bodySerialNumber: String?
    public let lensSerialNumber: String?
    public let shutterCount: Int?

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
        pictureControl: String? = nil,
        exposureProgramInt: Int? = nil,
        meteringModeInt: Int? = nil,
        whiteBalanceInt: Int? = nil,
        flashInt: Int? = nil,
        colorSpaceInt: Int? = nil,
        rawColorSpaceName: String? = nil,
        lensMake: String? = nil,
        lensSpecification: String? = nil,
        maxAperture: Double? = nil,
        software: String? = nil,
        bodySerialNumber: String? = nil,
        lensSerialNumber: String? = nil,
        shutterCount: Int? = nil
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
        self.exposureProgramInt = exposureProgramInt
        self.meteringModeInt = meteringModeInt
        self.whiteBalanceInt = whiteBalanceInt
        self.flashInt = flashInt
        self.colorSpaceInt = colorSpaceInt
        self.rawColorSpaceName = rawColorSpaceName
        self.lensMake = lensMake
        self.lensSpecification = lensSpecification
        self.maxAperture = maxAperture
        self.software = software
        self.bodySerialNumber = bodySerialNumber
        self.lensSerialNumber = lensSerialNumber
        self.shutterCount = shutterCount
    }

    /// Parses EXIF, TIFF, and MakerNotes dictionaries from ImageIO properties dictionary.
    public init(from properties: [CFString: Any]) {
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]

        // 1. Camera Make & Model
        let rawMake = (tiff?[kCGImagePropertyTIFFMake] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawModel = (tiff?[kCGImagePropertyTIFFModel] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

        self.cameraMake = rawMake
        self.cameraModel = rawModel

        // 2. Lens Model & Make
        self.lensModel = (exif?[kCGImagePropertyExifLensModel] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.lensMake = (exif?[kCGImagePropertyExifLensMake] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

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
        if let flashIntVal = exif?[kCGImagePropertyExifFlash] as? Int {
            self.flashInt = flashIntVal
            self.flashFired = (flashIntVal & 1) != 0
        } else if let flashNum = exif?[kCGImagePropertyExifFlash] as? NSNumber {
            let val = flashNum.intValue
            self.flashInt = val
            self.flashFired = (val & 1) != 0
        } else {
            self.flashInt = nil
            self.flashFired = nil
        }

        // 9. Date Time Original
        self.dateTimeOriginal = exif?[kCGImagePropertyExifDateTimeOriginal] as? String

        // 10. Picture Control / Film Simulation / Profile
        if let picStyle = properties["{PictureStyle}" as CFString] as? [CFString: Any],
           let sim = picStyle["FilmSimulation" as CFString] as? [Any],
           let firstStr = sim.first as? String {
            self.pictureControl = CameraProfileEngine.formatFujiSimulationName(firstStr)
        } else if let nikon = properties[kCGImagePropertyMakerNikonDictionary] as? [CFString: Any],
           let picCtrl = nikon["PictureControl" as CFString] as? String {
            self.pictureControl = picCtrl.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            self.pictureControl = nil
        }

        // 11. Exposure Program
        if let ep = exif?[kCGImagePropertyExifExposureProgram] as? Int {
            self.exposureProgramInt = ep
        } else if let epNum = exif?[kCGImagePropertyExifExposureProgram] as? NSNumber {
            self.exposureProgramInt = epNum.intValue
        } else {
            self.exposureProgramInt = nil
        }

        // 12. Metering Mode
        if let mm = exif?[kCGImagePropertyExifMeteringMode] as? Int {
            self.meteringModeInt = mm
        } else if let mmNum = exif?[kCGImagePropertyExifMeteringMode] as? NSNumber {
            self.meteringModeInt = mmNum.intValue
        } else {
            self.meteringModeInt = nil
        }

        // 13. White Balance
        if let wb = exif?[kCGImagePropertyExifWhiteBalance] as? Int {
            self.whiteBalanceInt = wb
        } else if let wbNum = exif?[kCGImagePropertyExifWhiteBalance] as? NSNumber {
            self.whiteBalanceInt = wbNum.intValue
        } else {
            self.whiteBalanceInt = nil
        }

        // 14. Color Space
        if let cs = exif?[kCGImagePropertyExifColorSpace] as? Int {
            self.colorSpaceInt = cs
        } else if let csNum = exif?[kCGImagePropertyExifColorSpace] as? NSNumber {
            self.colorSpaceInt = csNum.intValue
        } else {
            self.colorSpaceInt = nil
        }
        self.rawColorSpaceName = (properties[kCGImagePropertyProfileName] as? String)
            ?? (properties[kCGImagePropertyColorModel] as? String)

        // 15. Lens Specification & Max Aperture
        if let specArray = exif?[kCGImagePropertyExifLensSpecification] as? [Double], specArray.count >= 4 {
            let minF = specArray[0]
            let maxF = specArray[1]
            let minA = specArray[2]
            if minF == maxF {
                self.lensSpecification = String(format: "%.0fmm ƒ/%.1f", minF, minA)
            } else {
                self.lensSpecification = String(format: "%.0f–%.0fmm ƒ/%.1f", minF, maxF, minA)
            }
        } else if let specArray = exif?[kCGImagePropertyExifLensSpecification] as? [NSNumber], specArray.count >= 4 {
            let minF = specArray[0].doubleValue
            let maxF = specArray[1].doubleValue
            let minA = specArray[2].doubleValue
            if minF == maxF {
                self.lensSpecification = String(format: "%.0fmm ƒ/%.1f", minF, minA)
            } else {
                self.lensSpecification = String(format: "%.0f–%.0fmm ƒ/%.1f", minF, maxF, minA)
            }
        } else {
            self.lensSpecification = nil
        }

        self.maxAperture = exif?[kCGImagePropertyExifMaxApertureValue] as? Double

        // 16. Software / Firmware
        self.software = (tiff?[kCGImagePropertyTIFFSoftware] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

        // 17. Body & Lens Serial Numbers
        self.bodySerialNumber = (exif?[kCGImagePropertyExifBodySerialNumber] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.lensSerialNumber = (exif?[kCGImagePropertyExifLensSerialNumber] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

        // 18. Shutter Count (MakerNotes)
        var parsedShutterCount: Int? = nil
        if let nikon = properties[kCGImagePropertyMakerNikonDictionary] as? [CFString: Any] {
            if let sc = nikon["ShutterCount" as CFString] as? Int {
                parsedShutterCount = sc
            } else if let scNum = nikon["ShutterCount" as CFString] as? NSNumber {
                parsedShutterCount = scNum.intValue
            }
        }
        if parsedShutterCount == nil, let fuji = properties["{MakerFuji}" as CFString] as? [CFString: Any] {
            if let sc = fuji["ShutterCount" as CFString] as? Int {
                parsedShutterCount = sc
            }
        }
        if parsedShutterCount == nil, let canon = properties[kCGImagePropertyMakerCanonDictionary] as? [CFString: Any] {
            if let sc = canon["ImageCount" as CFString] as? Int {
                parsedShutterCount = sc
            }
        }
        if parsedShutterCount == nil, let sony = properties["{MakerSony}" as CFString] as? [CFString: Any] {
            if let sc = sony["ImageCount" as CFString] as? Int {
                parsedShutterCount = sc
            }
        }
        self.shutterCount = parsedShutterCount
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
        guard let b = exposureBias else { return nil }
        if abs(b) < 0.01 {
            return "0.0 EV"
        }
        return String(format: "%+.1f EV", b)
    }

    public var date: Date? {
        guard let raw = dateTimeOriginal else { return nil }
        let parser = DateFormatter()
        parser.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return parser.date(from: raw)
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

    public var formattedExposureProgram: String? {
        guard let p = exposureProgramInt else { return nil }
        switch p {
        case 1: return "Manual (M)"
        case 2: return "Program AE (P)"
        case 3: return "Aperture Priority (Av)"
        case 4: return "Shutter Priority (Tv)"
        case 5: return "Creative Program (DoF)"
        case 6: return "Action Program"
        case 7: return "Portrait Mode"
        case 8: return "Landscape Mode"
        default: return "Auto"
        }
    }

    public var formattedMeteringMode: String? {
        guard let m = meteringModeInt else { return nil }
        switch m {
        case 1: return "Average"
        case 2: return "Center-Weighted"
        case 3: return "Spot"
        case 4: return "Multi-Spot"
        case 5: return "Multi-Segment (Matrix)"
        case 6: return "Partial"
        default: return "Multi-Segment"
        }
    }

    public var formattedWhiteBalance: String? {
        guard let w = whiteBalanceInt else { return nil }
        switch w {
        case 0: return "Auto (AWB)"
        case 1: return "Manual / Custom"
        default: return "Auto"
        }
    }

    public var formattedFlash: String? {
        if let f = flashInt {
            let fired = (f & 1) != 0
            if !fired {
                return "Off (Did not fire)"
            }
            let mode = (f >> 3) & 0x3
            switch mode {
            case 1: return "Fired (Compulsory)"
            case 2: return "Fired (Auto)"
            case 3: return "Fired (Red-Eye)"
            default: return "Fired"
            }
        }
        if let fired = flashFired {
            return fired ? "Fired" : "Off (Did not fire)"
        }
        return nil
    }

    public var formattedColorSpace: String? {
        if let raw = rawColorSpaceName, !raw.isEmpty {
            if raw.localizedCaseInsensitiveContains("display p3") || raw.localizedCaseInsensitiveContains("p3") {
                return "Display P3"
            }
            if raw.localizedCaseInsensitiveContains("adobe rgb") {
                return "Adobe RGB (1998)"
            }
            if raw.localizedCaseInsensitiveContains("srgb") {
                return "sRGB"
            }
            return raw
        }
        if let cs = colorSpaceInt {
            switch cs {
            case 1: return "sRGB"
            case 2, 65535: return "Adobe RGB (1998)"
            default: return "sRGB"
            }
        }
        return nil
    }

    public var formattedFocalWithEquivalent: String? {
        guard let f = focalLength, f > 0 else { return nil }
        let focalStr = (f == floor(f)) ? "\(Int(f))mm" : String(format: "%.1fmm", f)
        if let eq = focalLength35mm, eq > 0, eq != Int(round(f)) {
            let crop = Double(eq) / f
            return "\(focalStr) (35mm eq: \(eq)mm · \(String(format: "%.1f", crop))×)"
        }
        return focalStr
    }

    public var formattedShutterCount: String? {
        guard let count = shutterCount, count > 0 else { return nil }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return (formatter.string(from: NSNumber(value: count)) ?? "\(count)") + " clicks"
    }

    /// Clean one-line summary of exposure settings: "1/500s · ƒ/2.8 · ISO 400 · 85mm"
    public var exposureSummary: String {
        var parts: [String] = []
        if let s = formattedShutter { parts.append(s) }
        if let a = formattedAperture { parts.append(a) }
        if let i = formattedIso { parts.append(i) }
        if let f = formattedFocal { parts.append(f) }
        if let b = formattedBias, b != "0.0 EV" { parts.append(b) }
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
