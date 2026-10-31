import Foundation

/// Layout modes for multi-image burst and sequence comparison.
/// 1-UP: Single edge-to-edge view.
/// 2-UP: Dual side-by-side split comparison.
/// 4-UP: 2×2 quad comparison.
public enum MultiUpMode: Int, CaseIterable, Sendable {
    case single = 1
    case twoUp = 2
    case fourUp = 4

    public var next: MultiUpMode {
        switch self {
        case .single: return .twoUp
        case .twoUp: return .fourUp
        case .fourUp: return .single
        }
    }
}
