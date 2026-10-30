import Foundation
import CoreGraphics
@preconcurrency import Vision

/// Structured result of aesthetic evaluation, composition quality, and facial capture analysis.
public struct AestheticScoreResult: Sendable, Equatable {
    /// Normalized integral aesthetic score on a human-readable 1.0 to 10.0 scale (e.g. 8.8)
    public let score: Float

    /// Formatted string representation for UI pills (e.g. "8.8")
    public var formattedScore: String {
        String(format: "%.1f", score)
    }

    /// Raw machine-learned aesthetic score from Apple Vision in [-1.0, 1.0] range
    public let rawAestheticScore: Float?

    /// True if Vision flags the photo as an accidental shot, receipt, screenshot, or utility capture
    public let isUtility: Bool

    /// Highest face capture quality score [0.0, 1.0] if faces were detected in the frame
    public let faceQuality: Float?

    /// Normalized high-frequency sharpness score [0.0, 1.0]
    public let sharpnessScore: Float

    /// Whether this shot is the relative winner in a 2-UP split matchup
    public var isWinner: Bool

    /// Score advantage margin over opponent (e.g. +1.4)
    public var deltaToOpponent: Float?

    public init(
        score: Float,
        rawAestheticScore: Float? = nil,
        isUtility: Bool = false,
        faceQuality: Float? = nil,
        sharpnessScore: Float = 0.5,
        isWinner: Bool = false,
        deltaToOpponent: Float? = nil
    ) {
        self.score = min(10.0, max(1.0, score))
        self.rawAestheticScore = rawAestheticScore
        self.isUtility = isUtility
        self.faceQuality = faceQuality
        self.sharpnessScore = sharpnessScore
        self.isWinner = isWinner
        self.deltaToOpponent = deltaToOpponent
    }

    /// Evaluates a 2-UP matchup between Champion and Challenger and assigns winner flags and deltas
    public static func compareMatchup(left: AestheticScoreResult, right: AestheticScoreResult) -> (left: AestheticScoreResult, right: AestheticScoreResult) {
        var l = left
        var r = right
        let diff = l.score - r.score

        // A margin of >= 0.3 represents a perceptible quality gap
        if diff >= 0.3 {
            l.isWinner = true
            l.deltaToOpponent = diff
            r.isWinner = false
            r.deltaToOpponent = -diff
        } else if diff <= -0.3 {
            r.isWinner = true
            r.deltaToOpponent = -diff
            l.isWinner = false
            l.deltaToOpponent = diff
        } else {
            // Close call: neither is marked as runaway winner
            l.isWinner = false
            r.isWinner = false
            l.deltaToOpponent = diff
            r.deltaToOpponent = -diff
        }
        return (l, r)
    }
}

private final class AestheticScoreWrapper: NSObject {
    let result: AestheticScoreResult
    init(result: AestheticScoreResult) {
        self.result = result
    }
}

/// Hardware-accelerated image aesthetic and photographic quality scoring engine powered by Apple Vision & Neural Engine.
public final class AestheticsEngine: @unchecked Sendable {
    public static let shared = AestheticsEngine()

    /// In-memory LRU cache of computed aesthetic scores by cache key
    private let cache = NSCache<NSString, AestheticScoreWrapper>()

    public init() {
        cache.countLimit = 250
    }

    /// Synchronous LRU cache check for zero-latency retrieval during folder traversal.
    public func cachedScore(for cacheKey: String?) -> AestheticScoreResult? {
        guard let key = cacheKey as NSString? else { return nil }
        return cache.object(forKey: key)?.result
    }

    /// Computes an integral aesthetic score for an image.
    /// Fast and non-blocking: dispatches to background queue utilizing Apple Neural Engine.
    public func computeScore(for cgImage: CGImage, cacheKey: String? = nil) async -> AestheticScoreResult {
        if let key = cacheKey as NSString?, let cached = cache.object(forKey: key) {
            return cached.result
        }

        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else {
            return AestheticScoreResult(score: 5.0)
        }

        // Measure edge sharpness from image dimensions and high-frequency content
        let sharpness = computeSharpness(for: cgImage)

        let result: AestheticScoreResult
        if #available(macOS 15.0, *) {
            result = await computeWithVisionAesthetics(for: cgImage, sharpness: sharpness)
        } else {
            result = await computeLegacyScore(for: cgImage, sharpness: sharpness)
        }

        if let key = cacheKey as NSString? {
            cache.setObject(AestheticScoreWrapper(result: result), forKey: key)
        }

        return result
    }

    @available(macOS 15.0, *)
    private func computeWithVisionAesthetics(for cgImage: CGImage, sharpness: Float) async -> AestheticScoreResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let aestheticsReq = VNCalculateImageAestheticsScoresRequest()
                let faceReq = VNDetectFaceCaptureQualityRequest()
                let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

                var rawAesthetic: Float? = nil
                var isUtil: Bool = false
                var faceQuality: Float? = nil

                do {
                    try handler.perform([aestheticsReq, faceReq])

                    if let aesObs = aestheticsReq.results?.first {
                        rawAesthetic = aesObs.overallScore
                        isUtil = aesObs.isUtility
                    }

                    if let faceResults = faceReq.results, !faceResults.isEmpty {
                        let qualities = faceResults.compactMap { $0.faceCaptureQuality }
                        if !qualities.isEmpty {
                            faceQuality = qualities.max()
                        }
                    }
                } catch {
                    // Vision execution failed; fallback gracefully
                }

                // Map raw aesthetic [-1.0, 1.0] to [1.0, 10.0]
                let baseAesthetic: Float
                if let raw = rawAesthetic {
                    baseAesthetic = min(10.0, max(1.0, (raw + 1.0) / 2.0 * 9.0 + 1.0))
                } else {
                    baseAesthetic = min(10.0, max(1.0, sharpness * 9.0 + 1.0))
                }

                // Combine with face quality if available
                var finalScore: Float
                if let fq = faceQuality {
                    let scaledFQ = min(10.0, max(1.0, fq * 9.0 + 1.0))
                    // Portraits: 55% scene aesthetics + 45% face capture quality
                    finalScore = 0.55 * baseAesthetic + 0.45 * scaledFQ
                } else {
                    finalScore = baseAesthetic
                }

                // Penalize utility or failed photos
                if isUtil {
                    finalScore = max(1.0, finalScore - 3.5)
                }

                let scoreObj = AestheticScoreResult(
                    score: finalScore,
                    rawAestheticScore: rawAesthetic,
                    isUtility: isUtil,
                    faceQuality: faceQuality,
                    sharpnessScore: sharpness
                )
                continuation.resume(returning: scoreObj)
            }
        }
    }

    private func computeLegacyScore(for cgImage: CGImage, sharpness: Float) async -> AestheticScoreResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let faceReq = VNDetectFaceCaptureQualityRequest()
                let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

                var faceQuality: Float? = nil
                do {
                    try handler.perform([faceReq])
                    if let faceResults = faceReq.results, !faceResults.isEmpty {
                        let qualities = faceResults.compactMap { $0.faceCaptureQuality }
                        if !qualities.isEmpty {
                            faceQuality = qualities.max()
                        }
                    }
                } catch {}

                let baseScore = min(10.0, max(1.0, sharpness * 9.0 + 1.0))
                var finalScore = baseScore
                if let fq = faceQuality {
                    let scaledFQ = min(10.0, max(1.0, fq * 9.0 + 1.0))
                    finalScore = 0.50 * baseScore + 0.50 * scaledFQ
                }

                let scoreObj = AestheticScoreResult(
                    score: finalScore,
                    rawAestheticScore: nil,
                    isUtility: false,
                    faceQuality: faceQuality,
                    sharpnessScore: sharpness
                )
                continuation.resume(returning: scoreObj)
            }
        }
    }

    /// Fast subsampled luminance sharpness metric based on gradient energy
    private func computeSharpness(for cgImage: CGImage) -> Float {
        let sampleW = min(128, cgImage.width)
        let sampleH = min(128, cgImage.height)
        guard sampleW > 4, sampleH > 4 else { return 0.5 }

        let colorSpace = CGColorSpaceCreateDeviceGray()
        var rawData = [UInt8](repeating: 0, count: sampleW * sampleH)

        guard let ctx = CGContext(
            data: &rawData,
            width: sampleW,
            height: sampleH,
            bitsPerComponent: 8,
            bytesPerRow: sampleW,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            return 0.5
        }

        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: sampleW, height: sampleH))

        var totalGradient: Double = 0
        var count = 0

        for y in 1..<(sampleH - 1) {
            let rowOffset = y * sampleW
            let prevRow = (y - 1) * sampleW
            let nextRow = (y + 1) * sampleW

            for x in 1..<(sampleW - 1) {
                let dx = Double(rawData[rowOffset + x + 1]) - Double(rawData[rowOffset + x - 1])
                let dy = Double(rawData[nextRow + x]) - Double(rawData[prevRow + x])
                totalGradient += (dx * dx + dy * dy)
                count += 1
            }
        }

        let meanEnergy = count > 0 ? (totalGradient / Double(count)) : 0.0
        // Typical gradient energy ranges from 0 to 8000; map smoothly with sqrt
        let norm = Float(min(1.0, sqrt(meanEnergy) / 60.0))
        return norm
    }
}
