import Foundation
import CoreGraphics
@preconcurrency import Vision

/// Visual scene relationship between two candidate photos in comparison or traversal.
public struct SceneComparisonResult: Sendable, Equatable {
    /// True if the two photos belong to the same scene or burst group
    public let isSameScene: Bool

    /// Normalized visual feature print distance (0.0 = identical, 1.0+ = completely different)
    public let visualDistance: Float

    /// Confidence or closeness metric (1.0 = identical framing, 0.0 = completely dissimilar)
    public var similarity: Float {
        max(0.0, min(1.0, 1.0 - visualDistance))
    }

    /// Time interval difference in seconds if EXIF timestamps were available
    public let timeDelta: TimeInterval?

    /// Formatted status description for UI pills (e.g. "BURST (Δ 0.2s)" or "SAME SCENE")
    public var statusDescription: String {
        if let dt = timeDelta, dt < 3.0 && visualDistance < 0.38 {
            return String(format: "BURST (Δ %.1fs)", dt)
        } else if isSameScene {
            return "SAME SCENE"
        } else {
            return "NEW SCENE"
        }
    }

    public init(isSameScene: Bool, visualDistance: Float, timeDelta: TimeInterval? = nil) {
        self.isSameScene = isSameScene
        self.visualDistance = visualDistance
        self.timeDelta = timeDelta
    }
}

private final class FeaturePrintWrapper: NSObject {
    let observation: VNFeaturePrintObservation
    init(observation: VNFeaturePrintObservation) {
        self.observation = observation
    }
}

/// Hardware-accelerated Apple Neural Engine (ANE) visual scene and burst detection engine.
/// Computes high-dimensional visual feature prints (embeddings) via Vision framework
/// and determines whether consecutive photos share the same scene, subject, lighting, and framing.
public final class SceneDetectionEngine: @unchecked Sendable {
    public static let shared = SceneDetectionEngine()

    /// In-memory LRU cache of computed feature prints by cache key / file path
    private let cache = NSCache<NSString, FeaturePrintWrapper>()

    public init() {
        cache.countLimit = 300
    }

    /// Synchronous LRU cache check for feature print
    public func cachedFeaturePrint(for cacheKey: String?) -> VNFeaturePrintObservation? {
        guard let key = cacheKey as NSString? else { return nil }
        return cache.object(forKey: key)?.observation
    }

    /// Generates or retrieves the ANE visual feature print for an image.
    /// Fast and non-blocking: dispatches to background queue utilizing Apple Neural Engine (~3-7ms).
    public func computeFeaturePrint(for cgImage: CGImage, cacheKey: String? = nil) async -> VNFeaturePrintObservation? {
        if let key = cacheKey as NSString?, let cached = cache.object(forKey: key) {
            return cached.observation
        }

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let request = VNGenerateImageFeaturePrintRequest()
                let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
                do {
                    try handler.perform([request])
                    if let printObs = request.results?.first as? VNFeaturePrintObservation {
                        if let key = cacheKey as NSString? {
                            self.cache.setObject(FeaturePrintWrapper(observation: printObs), forKey: key)
                        }
                        continuation.resume(returning: printObs)
                        return
                    }
                } catch {
                    // Vision execution failed; resume nil
                }
                continuation.resume(returning: nil)
            }
        }
    }

    /// Evaluates visual similarity and burst relationship between two photos.
    /// Distance < 0.50 with time delta < 60s classifies as the same scene/burst.
    public func compareScenes(
        imageA: CGImage,
        keyA: String?,
        imageB: CGImage,
        keyB: String?,
        timeDelta: TimeInterval? = nil
    ) async -> SceneComparisonResult {
        async let p1 = computeFeaturePrint(for: imageA, cacheKey: keyA)
        async let p2 = computeFeaturePrint(for: imageB, cacheKey: keyB)
        let (obs1, obs2) = await (p1, p2)

        guard let print1 = obs1, let print2 = obs2 else {
            // Fallback to timeDelta heuristic if feature prints unavailable
            let fallbackSame = (timeDelta != nil && timeDelta! <= 3.0)
            return SceneComparisonResult(isSameScene: fallbackSame, visualDistance: fallbackSame ? 0.25 : 0.85, timeDelta: timeDelta)
        }

        var distance: Float = 1.0
        do {
            try print1.computeDistance(&distance, to: print2)
        } catch {
            distance = 1.0
        }

        // Scene boundary decision:
        // distance < 0.38: Tight high-speed burst (same subject/framing)
        // distance < 0.50: Same scene/setup (with timeDelta <= 60s or unrecorded)
        // distance >= 0.50: Different scene/pivot
        let isSame: Bool
        if distance < 0.38 {
            isSame = true
        } else if distance < 0.50 {
            if let dt = timeDelta {
                isSame = dt <= 60.0
            } else {
                isSame = true
            }
        } else {
            isSame = false
        }

        return SceneComparisonResult(isSameScene: isSame, visualDistance: distance, timeDelta: timeDelta)
    }
}
