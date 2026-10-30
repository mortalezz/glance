import Foundation
import CoreGraphics
import Vision

public struct DetectedFace: Sendable {
    /// Normalized bounding box in Vision coordinates ((0,0) at bottom-left, (1,1) at top-right)
    public let boundingBox: CGRect
    /// Normalized target eye center point ((0,0) at bottom-left, (1,1) at top-right)
    public let eyeCenter: CGPoint
    public let leftEye: CGPoint?
    public let rightEye: CGPoint?
    public let confidence: Float

    public init(
        boundingBox: CGRect,
        eyeCenter: CGPoint,
        leftEye: CGPoint? = nil,
        rightEye: CGPoint? = nil,
        confidence: Float = 1.0
    ) {
        self.boundingBox = boundingBox
        self.eyeCenter = eyeCenter
        self.leftEye = leftEye
        self.rightEye = rightEye
        self.confidence = confidence
    }
}

/// Hardware-accelerated offline face and eye landmark detector powered by Apple Vision & Neural Engine.
public final class FaceDetectionEngine: @unchecked Sendable {
    public static let shared = FaceDetectionEngine()

    /// In-memory LRU cache of detected faces by file path / cache key
    private let cache = NSCache<NSString, NSArray>()

    public init() {
        cache.countLimit = 150
    }

    /// Detects faces and precise eye landmark coordinates in a CGImage.
    /// Fast and non-blocking: executes on background queue with Apple Neural Engine acceleration.
    public func detectFaces(in cgImage: CGImage, cacheKey: String? = nil) async -> [DetectedFace] {
        if let key = cacheKey as NSString?, let cached = cache.object(forKey: key) as? [DetectedFaceWrapper] {
            return cached.map { $0.face }
        }

        return await withCheckedContinuation { continuation in
            let request = VNDetectFaceLandmarksRequest { [weak self] request, error in
                guard let self = self else {
                    continuation.resume(returning: [])
                    return
                }
                guard error == nil, let observations = request.results as? [VNFaceObservation] else {
                    continuation.resume(returning: [])
                    return
                }

                var faces: [DetectedFace] = []
                for obs in observations {
                    let box = obs.boundingBox
                    var leftEyeCenter: CGPoint? = nil
                    var rightEyeCenter: CGPoint? = nil

                    if let landmarks = obs.landmarks {
                        if let leftEye = landmarks.leftEye, leftEye.pointCount > 0 {
                            let pts = leftEye.normalizedPoints
                            let count = CGFloat(leftEye.pointCount)
                            let avgX = pts.reduce(0) { $0 + $1.x } / count
                            let avgY = pts.reduce(0) { $0 + $1.y } / count
                            leftEyeCenter = CGPoint(
                                x: box.origin.x + avgX * box.width,
                                y: box.origin.y + avgY * box.height
                            )
                        }

                        if let rightEye = landmarks.rightEye, rightEye.pointCount > 0 {
                            let pts = rightEye.normalizedPoints
                            let count = CGFloat(rightEye.pointCount)
                            let avgX = pts.reduce(0) { $0 + $1.x } / count
                            let avgY = pts.reduce(0) { $0 + $1.y } / count
                            rightEyeCenter = CGPoint(
                                x: box.origin.x + avgX * box.width,
                                y: box.origin.y + avgY * box.height
                            )
                        }
                    }

                    // Determine the best target eye focus point:
                    // If both eyes visible, midpoint is optimal for portrait framing;
                    // otherwise, use whichever eye is detected, or upper 65% of face bounding box.
                    let targetEye: CGPoint
                    if let l = leftEyeCenter, let r = rightEyeCenter {
                        targetEye = CGPoint(x: (l.x + r.x) / 2.0, y: (l.y + r.y) / 2.0)
                    } else if let l = leftEyeCenter {
                        targetEye = l
                    } else if let r = rightEyeCenter {
                        targetEye = r
                    } else {
                        targetEye = CGPoint(x: box.midX, y: box.origin.y + box.height * 0.65)
                    }

                    faces.append(DetectedFace(
                        boundingBox: box,
                        eyeCenter: targetEye,
                        leftEye: leftEyeCenter,
                        rightEye: rightEyeCenter,
                        confidence: obs.confidence
                    ))
                }

                // Sort faces by prominence: largest face area first (primary portrait subject)
                faces.sort { ($0.boundingBox.width * $0.boundingBox.height) > ($1.boundingBox.width * $1.boundingBox.height) }

                if let key = cacheKey as NSString? {
                    let wrapped = faces.map { DetectedFaceWrapper(face: $0) }
                    self.cache.setObject(wrapped as NSArray, forKey: key)
                }

                continuation.resume(returning: faces)
            }

            request.preferBackgroundProcessing = true
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(returning: [])
            }
        }
    }

    /// Synchronously checks if faces are already cached for a given path
    public func cachedFaces(for cacheKey: String) -> [DetectedFace]? {
        if let cached = cache.object(forKey: cacheKey as NSString) as? [DetectedFaceWrapper] {
            return cached.map { $0.face }
        }
        return nil
    }

    /// Clears the in-memory face cache
    public func clearCache() {
        cache.removeAllObjects()
    }
}

private final class DetectedFaceWrapper: NSObject {
    let face: DetectedFace
    init(face: DetectedFace) { self.face = face }
}
