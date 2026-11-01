import Foundation
import CoreGraphics
import ImageIO

/// High-performance offline camera autofocus point and subject tracking parser.
/// Decodes MakerNotes binary structures across Sony, Nikon, Fujifilm, and Canon
/// to extract normalized `(x, y, width, height)` viewfinder focus coordinates.
public final class FocusPointEngine: Sendable {
    public static let shared = FocusPointEngine()

    public init() {}

    /// Extracts all active camera autofocus points and subject tracking boxes.
    ///
    /// - Parameters:
    ///   - properties: ImageIO dictionary from `CGImageSourceCopyPropertiesAtIndex`.
    ///   - imageWidth: Pixel width of the image.
    ///   - imageHeight: Pixel height of the image.
    ///   - detectedFaces: Optional detected portrait faces for Eye/Face tracking box alignment.
    /// - Returns: An array of `AFPointData` reticles positioned in normalized `[0.0, 1.0]` image space.
    public func extractAFPoints(
        from properties: [CFString: Any],
        imageWidth: Int,
        imageHeight: Int,
        detectedFaces: [DetectedFace] = []
    ) -> [AFPointData] {
        var points: [AFPointData] = []

        let W = max(1, CGFloat(imageWidth))
        let H = max(1, CGFloat(imageHeight))

        // 1. Sony MakerNotes (FocusLocation tag 0x2027)
        if let sony = (properties["{MakerSony}" as CFString] as? [CFString: Any]) ??
                      nil {
            if let sonyPoints = parseSonyAF(sony: sony, width: W, height: H) {
                points.append(contentsOf: sonyPoints)
            }
        }

        // 2. Nikon MakerNotes (AFInfo2 tag 0x00B7 / AFPoints)
        if let nikon = properties[kCGImagePropertyMakerNikonDictionary] as? [CFString: Any] {
            if let nikonPoints = parseNikonAF(nikon: nikon, width: W, height: H) {
                points.append(contentsOf: nikonPoints)
            }
        }

        // 3. Fujifilm MakerNotes (FocusPixel tag 0x1023 / FocusPoint)
        if let fuji = (properties["{MakerFuji}" as CFString] as? [CFString: Any]) ??
                     nil {
            if let fujiPoints = parseFujiAF(fuji: fuji, width: W, height: H) {
                points.append(contentsOf: fujiPoints)
            }
        }

        // 4. Canon MakerNotes (AFInfo / AFArea rectangles)
        if let canon = properties[kCGImagePropertyMakerCanonDictionary] as? [CFString: Any] {
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
                    isPrimary: (i == 0)
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

        // 6. Center Point Fallback (Single Center AF Reticle if no MakerNotes or faces found)
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

    // MARK: - Brand-Specific MakerNotes Parsers

    /// Parses Sony `FocusLocation` (tag `0x2027`) and AF area coordinates.
    private func parseSonyAF(sony: [CFString: Any], width: CGFloat, height: CGFloat) -> [AFPointData]? {
        // Tag 0x2027 or "FocusLocation"
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

    /// Parses Nikon `AFInfo2` (tag `0x00B7`) phase-detect & tracking box coordinates.
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
                    return [AFPointData(rectNormalized: r, status: .locked, label: "Nikon 3D Tracking")]
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
