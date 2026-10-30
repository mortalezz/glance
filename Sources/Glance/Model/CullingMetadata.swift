import Foundation

public enum PickStatus: Int, Sendable, Codable {
    case unflagged = 0
    case pick = 1
    case reject = -1

    public var title: String {
        switch self {
        case .unflagged: return "Unflagged"
        case .pick: return "Pick (Keeper)"
        case .reject: return "Reject"
        }
    }
}

public enum ColorLabel: Int, Sendable, Codable {
    case none = 0
    case red = 6
    case yellow = 7
    case green = 8
    case blue = 9

    public var title: String {
        switch self {
        case .none: return "None"
        case .red: return "Red"
        case .yellow: return "Yellow"
        case .green: return "Green"
        case .blue: return "Blue"
        }
    }
}

public struct CullingMetadata: Sendable, Codable, Equatable {
    public var rating: Int // 0..5 stars
    public var pick: PickStatus
    public var color: ColorLabel
    public var orientation: Int? // EXIF Orientation 1..8

    public init(
        rating: Int = 0,
        pick: PickStatus = .unflagged,
        color: ColorLabel = .none,
        orientation: Int? = nil
    ) {
        self.rating = max(0, min(5, rating))
        self.pick = pick
        self.color = color
        self.orientation = orientation
    }
}

public enum CullingFilter: Equatable, Sendable {
    case all
    case picksOnly
    case hideRejects
    case rejectsOnly
    case unratedOnly
    case minRating(Int)

    public var title: String {
        switch self {
        case .all: return "All Files"
        case .picksOnly: return "Picks Only (P)"
        case .hideRejects: return "Hide Rejects"
        case .rejectsOnly: return "Rejects Only (X)"
        case .unratedOnly: return "Unrated Only"
        case .minRating(let n): return "\(n)+ Stars"
        }
    }

    public func matches(meta: CullingMetadata) -> Bool {
        switch self {
        case .all:
            return true
        case .picksOnly:
            return meta.pick == .pick
        case .hideRejects:
            return meta.pick != .reject
        case .rejectsOnly:
            return meta.pick == .reject
        case .unratedOnly:
            return meta.rating == 0 && meta.pick == .unflagged
        case .minRating(let n):
            return meta.rating >= n
        }
    }
}
