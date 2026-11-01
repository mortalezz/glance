import Foundation
import CoreGraphics
import ImageIO

/// High-performance offline camera autofocus point and subject tracking parser.
/// Decodes standardized ImageIO {ExifAux} AFInfo and MakerNotes binary structures across
/// Sony, Nikon, Fujifilm, Canon, Leica, and Olympus to extract normalized
/// `(x, y, width, height)` viewfinder focus coordinates.
public final class FocusPointEngine: Sendable {
    public static let shared = FocusPointEngine()

    public init() {}

    /// Extracts all active camera autofocus points and subject tracking boxes.
    ///
    /// - Parameters:
    ///   - properties: ImageIO dictionary from `CGImageSourceCopyPropertiesAtIndex`.
    ///   - imageWidth: Pixel width of the image.
    ///   - imageHeight: Pixel height of the image.
    ///   - url: Optional file URL for reading binary camera MakerNotes (e.g. Nikon NEF).
    ///   - headerData: Optional raw header bytes for direct MakerNote inspection (unit tests).
    ///   - detectedFaces: Optional detected portrait faces for Eye/Face tracking box alignment.
    /// - Returns: An array of `AFPointData` reticles positioned in normalized `[0.0, 1.0]` image space.
    public func extractAFPoints(
        from properties: [CFString: Any],
        imageWidth: Int,
        imageHeight: Int,
        url: URL? = nil,
        headerData: Data? = nil,
        detectedFaces: [DetectedFace] = []
    ) -> [AFPointData] {
        var points: [AFPointData] = []

        let W = max(1, CGFloat(imageWidth))
        let H = max(1, CGFloat(imageHeight))

        // 0. Standardized ImageIO ExifAux AF Information (Fujifilm, Nikon, Sony, Canon, Leica)
        if let aux = (properties["{ExifAux}" as CFString] as? [CFString: Any]) ??
                     (properties[kCGImagePropertyExifAuxDictionary] as? [CFString: Any]) {
            if let auxPoints = parseExifAuxAF(aux: aux, width: W, height: H) {
                points.append(contentsOf: auxPoints)
            }
        }

        // 1. Sony MakerNotes (FocusLocation tag 0x2027)
        if points.isEmpty, let sony = properties["{MakerSony}" as CFString] as? [CFString: Any] {
            if let sonyPoints = parseSonyAF(sony: sony, width: W, height: H) {
                points.append(contentsOf: sonyPoints)
            }
        }

        // 2. Nikon MakerNotes in properties (AFInfo2 tag 0x00B7 / AFPoints)
        if points.isEmpty, let nikon = properties[kCGImagePropertyMakerNikonDictionary] as? [CFString: Any] {
            if let nikonPoints = parseNikonAF(nikon: nikon, width: W, height: H) {
                points.append(contentsOf: nikonPoints)
            }
        }

        // 2b. Direct Nikon MakerNote Binary Inspection (for RAW files where ImageIO omits binary AFInfo2)
        if points.isEmpty {
            let rawData: Data?
            if let headerData = headerData {
                rawData = headerData
            } else if let url = url,
                      ["nef", "nrw"].contains(url.pathExtension.lowercased()) ||
                      properties[kCGImagePropertyMakerNikonDictionary] != nil {
                if let handle = try? FileHandle(forReadingFrom: url) {
                    rawData = try? handle.read(upToCount: 131072)
                    try? handle.close()
                } else {
                    rawData = nil
                }
            } else {
                rawData = nil
            }

            if let data = rawData, let nikonPoints = parseNikonMakerNoteData(data: data, width: W, height: H) {
                points.append(contentsOf: nikonPoints)
            }
        }

        // 3. Fujifilm MakerNotes (FocusPixel tag 0x1023 / FocusPoint)
        if points.isEmpty, let fuji = properties["{MakerFuji}" as CFString] as? [CFString: Any] {
            if let fujiPoints = parseFujiAF(fuji: fuji, width: W, height: H) {
                points.append(contentsOf: fujiPoints)
            }
        }

        // 4. Canon MakerNotes (AFInfo / AFArea rectangles)
        if points.isEmpty, let canon = properties[kCGImagePropertyMakerCanonDictionary] as? [CFString: Any] {
            if let canonPoints = parseCanonAF(canon: canon, width: W, height: H) {
                points.append(contentsOf: canonPoints)
            }
        }

        // 5. Subject & Eye Tracking Box Integration (Cyan Viewfinder Brackets)
        if !detectedFaces.isEmpty {
            for (i, face) in detectedFaces.prefix(4).enumerated() {
                // Face Tracking Viewfinder Reticle (Cyan)
                // Convert Apple Vision coordinate (origin bottom-left) to Image coordinate (origin top-left)
                let faceRect = CGRect(
                    x: face.boundingBox.minX,
                    y: 1.0 - face.boundingBox.maxY,
                    width: face.boundingBox.width,
                    height: face.boundingBox.height
                )
                points.append(AFPointData(
                    rectNormalized: clamp(rect: faceRect),
                    status: .subjectTrack,
                    label: (detectedFaces.count > 1) ? "Eye AF #\(i + 1)" : "Eye AF",
                    isPrimary: (i == 0 && points.isEmpty)
                ))

                // Exact Eye Focus Lock Reticle (Emerald) if eyes are detected
                if face.leftEye != nil || face.rightEye != nil {
                    let eyeBoxDim: CGFloat = min(0.07, max(0.04, face.boundingBox.width * 0.35))
                    let eyeX = max(0.0, min(1.0 - eyeBoxDim, face.eyeCenter.x - eyeBoxDim / 2.0))
                    let eyeY = max(0.0, min(1.0 - eyeBoxDim, (1.0 - face.eyeCenter.y) - eyeBoxDim / 2.0))
                    let eyeRect = CGRect(x: eyeX, y: eyeY, width: eyeBoxDim, height: eyeBoxDim)

                    points.append(AFPointData(
                        rectNormalized: eyeRect,
                        status: .locked,
                        label: "Eye Lock",
                        isPrimary: (i == 0)
                    ))
                }
            }
        }

        // 6. Center Point Fallback (Single Center AF Reticle if no hardware AF or faces found)
        if points.isEmpty {
            let defaultDim: CGFloat = 0.06
            let centerRect = CGRect(
                x: 0.5 - defaultDim / 2.0,
                y: 0.5 - defaultDim / 2.0,
                width: defaultDim,
                height: defaultDim
            )
            points.append(AFPointData(
                rectNormalized: centerRect,
                status: .unconfirmed,
                label: "Center AF",
                isPrimary: true
            ))
        }

        return points
    }

    // MARK: - Standardized ImageIO ExifAux Parser

    /// Parses Apple ImageIO standardized `{ExifAux}` `AFInfo` array.
    private func parseExifAuxAF(aux: [CFString: Any], width: CGFloat, height: CGFloat) -> [AFPointData]? {
        guard let afInfo = (aux["AFInfo" as CFString] as? [Any]) ??
                          (aux["AFPoints" as CFString] as? [Any]),
              !afInfo.isEmpty else {
            return nil
        }

        var results: [AFPointData] = []
        let modeNum = aux["FocusMode" as CFString] as? NSNumber
        let defaultLabel: String
        if let mode = modeNum?.intValue {
            if mode == 2 {
                defaultLabel = "AF-C Lock"
            } else if mode == 3 {
                defaultLabel = "MF Point"
            } else {
                defaultLabel = "AF Lock"
            }
        } else {
            defaultLabel = "AF Lock"
        }

        var idx = 0
        while idx + 4 <= afInfo.count {
            guard let rawX = parseDouble(afInfo[idx]),
                  let rawY = parseDouble(afInfo[idx + 1]),
                  let rawW = parseDouble(afInfo[idx + 2]),
                  let rawH = parseDouble(afInfo[idx + 3]),
                  rawW > 0, rawH > 0 else {
                idx += 1
                continue
            }

            var status: AFPointData.Status = .locked
            var stride = 4

            if idx + 4 < afInfo.count {
                let flagItem = afInfo[idx + 4]
                let flagStr = String(describing: flagItem).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if Double(flagStr) == nil {
                    // Non-numeric flag token (e.g. "f", "t", "focus")
                    stride = 5
                    if flagStr == "f" || flagStr == "t" || flagStr == "focus" {
                        status = .locked
                    } else {
                        status = .unconfirmed
                    }
                } else if afInfo.count % 5 == 0 && (afInfo.count % 4 != 0) {
                    stride = 5
                    if let num = parseDouble(flagItem), num == 1.0 {
                        status = .locked
                    }
                }
            }

            let isPixelSpace = (rawX > 1.0 || rawY > 1.0 || rawW > 1.0 || rawH > 1.0)
            let normX = isPixelSpace ? (rawX / width) : rawX
            let normY = isPixelSpace ? (rawY / height) : rawY
            let normW = isPixelSpace ? (rawW / width) : rawW
            let normH = isPixelSpace ? (rawH / height) : rawH

            let rect = clamp(rect: CGRect(x: normX, y: normY, width: normW, height: normH))

            // Deduplicate overlapping or duplicate AF entries
            let alreadyExists = results.contains { existing in
                abs(existing.rectNormalized.origin.x - rect.origin.x) < 0.001 &&
                abs(existing.rectNormalized.origin.y - rect.origin.y) < 0.001 &&
                abs(existing.rectNormalized.width - rect.width) < 0.001 &&
                abs(existing.rectNormalized.height - rect.height) < 0.001
            }

            if !alreadyExists {
                results.append(AFPointData(
                    rectNormalized: rect,
                    status: status,
                    label: defaultLabel,
                    isPrimary: results.isEmpty
                ))
            }

            idx += stride
        }

        return results.isEmpty ? nil : results
    }

    private func parseDouble(_ value: Any) -> Double? {
        if let num = value as? NSNumber {
            return num.doubleValue
        }
        let str = String(describing: value).trimmingCharacters(in: .whitespacesAndNewlines)
        return Double(str)
    }

    // MARK: - Brand-Specific MakerNotes Parsers

    /// Parses Sony `FocusLocation` (tag `0x2027`) and AF area coordinates.
    private func parseSonyAF(sony: [CFString: Any], width: CGFloat, height: CGFloat) -> [AFPointData]? {
        if let loc = (sony["FocusLocation" as CFString] as? [NSNumber]) ??
                     (sony["0x2027" as CFString] as? [NSNumber]) {
            if loc.count >= 4 {
                let x = CGFloat(loc[0].doubleValue) / width
                let y = CGFloat(loc[1].doubleValue) / height
                let w = CGFloat(loc[2].doubleValue) / width
                let h = CGFloat(loc[3].doubleValue) / height
                let r = clamp(rect: CGRect(x: x, y: y, width: max(0.04, w), height: max(0.04, h)))
                return [AFPointData(rectNormalized: r, status: .locked, label: "Sony AF-C Lock")]
            } else if loc.count >= 2 {
                let cx = CGFloat(loc[0].doubleValue) / width
                let cy = CGFloat(loc[1].doubleValue) / height
                let dim: CGFloat = 0.06
                let r = clamp(rect: CGRect(x: cx - dim / 2, y: cy - dim / 2, width: dim, height: dim))
                return [AFPointData(rectNormalized: r, status: .locked, label: "Sony AF Point")]
            }
        }
        return nil
    }

    /// Parses Nikon `AFInfo2` (tag `0x00B7`) from dictionary if available.
    private func parseNikonAF(nikon: [CFString: Any], width: CGFloat, height: CGFloat) -> [AFPointData]? {
        if let af2 = nikon["AFInfo2" as CFString] as? [CFString: Any] {
            if let coords = (af2["AFArea" as CFString] as? [NSNumber]) ??
                            (af2["AFPoints" as CFString] as? [NSNumber]) {
                if coords.count >= 4 {
                    let x = CGFloat(coords[0].doubleValue) / width
                    let y = CGFloat(coords[1].doubleValue) / height
                    let w = CGFloat(coords[2].doubleValue) / width
                    let h = CGFloat(coords[3].doubleValue) / height
                    let r = clamp(rect: CGRect(x: x, y: y, width: max(0.04, w), height: max(0.04, h)))
                    return [AFPointData(rectNormalized: r, status: .locked, label: "Nikon AF Lock")]
                }
            }
        } else if let coords = (nikon["AFPosition" as CFString] as? [NSNumber]) ??
                               (nikon["FocusPosition" as CFString] as? [NSNumber]) {
            if coords.count >= 2 {
                let cx = CGFloat(coords[0].doubleValue) / width
                let cy = CGFloat(coords[1].doubleValue) / height
                let dim: CGFloat = 0.06
                let r = clamp(rect: CGRect(x: cx - dim / 2, y: cy - dim / 2, width: dim, height: dim))
                return [AFPointData(rectNormalized: r, status: .locked, label: "Nikon Primary AF")]
            }
        }
        return nil
    }

    /// Direct binary parser for Nikon MakerNote `AFInfo2` (tag `0x00B7`) from file header bytes.
    public func parseNikonMakerNoteData(data: Data, width: CGFloat, height: CGFloat) -> [AFPointData]? {
        let nikonMagic = "Nikon".data(using: .ascii)!
        guard let r = data.range(of: nikonMagic) else { return nil }
        let tiffBase = r.lowerBound + 10
        guard tiffBase + 8 <= data.count else { return nil }

        let isLittleEndian = (data[tiffBase] == 0x49) // "II" vs "MM"
        func readU16(_ off: Int) -> UInt16? {
            let absOff = tiffBase + off
            guard absOff + 2 <= data.count else { return nil }
            let b0 = UInt16(data[absOff])
            let b1 = UInt16(data[absOff + 1])
            return isLittleEndian ? (b0 | (b1 << 8)) : ((b0 << 8) | b1)
        }
        func readU32(_ off: Int) -> UInt32? {
            let absOff = tiffBase + off
            guard absOff + 4 <= data.count else { return nil }
            let b0 = UInt32(data[absOff])
            let b1 = UInt32(data[absOff + 1])
            let b2 = UInt32(data[absOff + 2])
            let b3 = UInt32(data[absOff + 3])
            return isLittleEndian ? (b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)) : ((b0 << 24) | (b1 << 16) | (b2 << 8) | b3)
        }

        guard let ifdOff = readU32(4).map(Int.init),
              let numEntries = readU16(ifdOff).map(Int.init) else { return nil }

        var b7Offset: Int? = nil
        for i in 0..<min(numEntries, 120) {
            let entry = ifdOff + 2 + i * 12
            guard let tag = readU16(entry) else { break }
            if tag == 0x00B7 { // AFInfo2
                b7Offset = readU32(entry + 8).map(Int.init)
                break
            }
        }

        guard let b7 = b7Offset, tiffBase + b7 + 60 <= data.count else { return nil }
        let tagStart = tiffBase + b7

        func tagU16(_ off: Int) -> UInt16? {
            let absOff = tagStart + off
            guard absOff + 2 <= data.count else { return nil }
            let b0 = UInt16(data[absOff])
            let b1 = UInt16(data[absOff + 1])
            return isLittleEndian ? (b0 | (b1 << 8)) : ((b0 << 8) | b1)
        }

        let versionStr = String(data: data.subdata(in: tagStart..<min(tagStart + 4, data.count)), encoding: .ascii) ?? ""

        var imgW: CGFloat = width
        var imgH: CGFloat = height
        var centerX: CGFloat = 0
        var centerY: CGFloat = 0
        var boxW: CGFloat = 0
        var boxH: CGFloat = 0
        var inFocus = true

        if versionStr.hasPrefix("03") {
            // Expeed 6 (Z5, Z6, Z7, Z50, Zfc, D780)
            if let w = tagU16(0x2A), w > 0 { imgW = CGFloat(w) }
            if let h = tagU16(0x2C), h > 0 { imgH = CGFloat(h) }
            if let cx = tagU16(0x2E) { centerX = CGFloat(cx) }
            if let cy = tagU16(0x30) { centerY = CGFloat(cy) }
            if let bw = tagU16(0x32), bw > 0 { boxW = CGFloat(bw) }
            if let bh = tagU16(0x34), bh > 0 { boxH = CGFloat(bh) }
            if let foc = tagU16(0x36) { inFocus = (foc == 1) }
        } else if versionStr.hasPrefix("04") {
            // Expeed 7 (Z8, Z9, Z6 III, Zf)
            if let w = tagU16(0x3E), w > 0 { imgW = CGFloat(w) }
            if let h = tagU16(0x40), h > 0 { imgH = CGFloat(h) }
            if let cx = tagU16(0x42) { centerX = CGFloat(cx) }
            if let cy = tagU16(0x44) { centerY = CGFloat(cy) }
            if let bw = tagU16(0x46), bw > 0 { boxW = CGFloat(bw) }
            if let bh = tagU16(0x48), bh > 0 { boxH = CGFloat(bh) }
            if let foc = tagU16(0x4A) { inFocus = (foc == 1) }
        } else if versionStr.hasPrefix("01") {
            // Older DSLRs (D3, D4, D800, D810, D750, etc.)
            if let w = tagU16(0x10), w > 0 { imgW = CGFloat(w) }
            if let h = tagU16(0x12), h > 0 { imgH = CGFloat(h) }
            if let cx = tagU16(0x14) { centerX = CGFloat(cx) }
            if let cy = tagU16(0x16) { centerY = CGFloat(cy) }
            if let bw = tagU16(0x18), bw > 0 { boxW = CGFloat(bw) }
            if let bh = tagU16(0x1A), bh > 0 { boxH = CGFloat(bh) }
            if let foc = tagU16(0x1C) { inFocus = (foc == 1) }
        }

        guard centerX > 0, centerY > 0, imgW > 0, imgH > 0 else { return nil }

        let normW = (boxW > 0) ? (boxW / imgW) : 0.05
        let normH = (boxH > 0) ? (boxH / imgH) : 0.05
        let normCX = centerX / imgW
        let normCY = centerY / imgH

        let originX = max(0.0, min(1.0 - normW, normCX - normW / 2.0))
        let originY = max(0.0, min(1.0 - normH, normCY - normH / 2.0))

        let rect = clamp(rect: CGRect(x: originX, y: originY, width: normW, height: normH))
        return [AFPointData(
            rectNormalized: rect,
            status: inFocus ? .locked : .unconfirmed,
            label: inFocus ? "Nikon AF Lock" : "Nikon AF",
            isPrimary: true
        )]
    }

    /// Parses Fujifilm `FocusPixel` (tag `0x1023`) and AF area coordinates.
    private func parseFujiAF(fuji: [CFString: Any], width: CGFloat, height: CGFloat) -> [AFPointData]? {
        if let pixel = (fuji["FocusPixel" as CFString] as? [NSNumber]) ??
                       (fuji["FocusPoint" as CFString] as? [NSNumber]) {
            if pixel.count >= 2 {
                let cx = CGFloat(pixel[0].doubleValue) / width
                let cy = CGFloat(pixel[1].doubleValue) / height
                let dim: CGFloat = 0.06
                let r = clamp(rect: CGRect(x: cx - dim / 2, y: cy - dim / 2, width: dim, height: dim))
                return [AFPointData(rectNormalized: r, status: .locked, label: "Fujifilm AF Lock")]
            }
        } else if let area = fuji["AFInfo" as CFString] as? [NSNumber], area.count >= 4 {
            let x = CGFloat(area[0].doubleValue) / width
            let y = CGFloat(area[1].doubleValue) / height
            let w = CGFloat(area[2].doubleValue) / width
            let h = CGFloat(area[3].doubleValue) / height
            let r = clamp(rect: CGRect(x: x, y: y, width: max(0.04, w), height: max(0.04, h)))
            return [AFPointData(rectNormalized: r, status: .locked, label: "Fujifilm AF Area")]
        }
        return nil
    }

    /// Parses Canon `AFInfo` active AF area rectangles.
    private func parseCanonAF(canon: [CFString: Any], width: CGFloat, height: CGFloat) -> [AFPointData]? {
        if let afInfo = (canon["AFInfo" as CFString] as? [NSNumber]) ??
                        (canon["AFArea" as CFString] as? [NSNumber]) {
            if afInfo.count >= 4 {
                let x = CGFloat(afInfo[0].doubleValue) / width
                let y = CGFloat(afInfo[1].doubleValue) / height
                let w = CGFloat(afInfo[2].doubleValue) / width
                let h = CGFloat(afInfo[3].doubleValue) / height
                let r = clamp(rect: CGRect(x: x, y: y, width: max(0.04, w), height: max(0.04, h)))
                return [AFPointData(rectNormalized: r, status: .locked, label: "Canon Dual Pixel AF")]
            }
        }
        return nil
    }

    /// Clamps a normalized rectangle to stay within [0.0, 1.0].
    private func clamp(rect: CGRect) -> CGRect {
        let x = max(0.0, min(1.0, rect.origin.x))
        let y = max(0.0, min(1.0, rect.origin.y))
        let w = max(0.01, min(1.0 - x, rect.width))
        let h = max(0.01, min(1.0 - y, rect.height))
        return CGRect(x: x, y: y, width: w, height: h)
    }
}
