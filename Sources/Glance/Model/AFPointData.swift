import Foundation
import CoreGraphics

/// Represents a camera autofocus point or subject tracking boundary extracted
/// from camera MakerNotes or on-device subject verification.
public struct AFPointData: Sendable, Equatable {
    public enum Status: String, Sendable, Equatable {
        /// Emerald (#00E676) - Confirmed in-focus lock achieved
        case locked = "LOCKED"
        /// Cyan (#00E5FF) - Eye/Face/Subject tracking box locked
        case subjectTrack = "TRACKING"
        /// Amber (#FFB300) - Primary selected point or manual unconfirmed focus
        case unconfirmed = "MANUAL"
    }

    /// Normalized rectangle `(x, y, width, height)` within [0.0, 1.0] image space.
    public let rectNormalized: CGRect
    /// Hardware focus lock or tracking status.
    public let status: Status
    /// Semantic description (e.g. "AF-C Lock", "Eye AF", "Point 12/693").
    public let label: String?
    /// Whether this point is the primary point that determined final focus.
    public let isPrimary: Bool

    public init(
        rectNormalized: CGRect,
        status: Status = .locked,
        label: String? = nil,
        isPrimary: Bool = true
    ) {
        self.rectNormalized = rectNormalized
        self.status = status
        self.label = label
        self.isPrimary = isPrimary
    }
}
