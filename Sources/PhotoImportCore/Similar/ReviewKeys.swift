import Foundation

public enum ReviewKey: Equatable, Sendable {
    case left, right, space, escape, toggle
}

public enum ReviewAction: Equatable, Sendable {
    case none
    case previousGroup
    case nextGroup
    case openPreview
    case closePreview
    case showPhoto(Int)
    case toggleCurrent
}

/// Keyboard rules for the review screen. With the large preview open, ← → step through the photos in the
/// group (stopping at the ends); with it closed they move between groups.
public enum ReviewKeys {
    public static func action(for key: ReviewKey, previewIndex: Int?, photoCount: Int) -> ReviewAction {
        guard let i = previewIndex else {
            switch key {
            case .left: return .previousGroup
            case .right: return .nextGroup
            case .space: return photoCount > 0 ? .openPreview : .none
            case .escape, .toggle: return .none
            }
        }
        switch key {
        case .left: return i > 0 ? .showPhoto(i - 1) : .none
        case .right: return i + 1 < photoCount ? .showPhoto(i + 1) : .none
        case .space, .escape: return .closePreview
        case .toggle: return .toggleCurrent
        }
    }
}
