import Foundation

public enum CullingAction: Sendable {
    case rating(itemID: String, rawIndex: Int, previous: Int, new: Int)
    case pick(itemID: String, rawIndex: Int, previous: PickStatus, new: PickStatus)
    case color(itemID: String, rawIndex: Int, previous: ColorLabel, new: ColorLabel)
    case rotate(itemID: String, rawIndex: Int, direction: RotationDirection)
    case delete(item: SlideItem, rawIndex: Int, previousMeta: CullingMetadata?, trashedRecords: [TrashedFileRecord])
}

@MainActor
public final class CullingUndoManager {
    public static let shared = CullingUndoManager()

    private var undoStack: [CullingAction] = []
    private var redoStack: [CullingAction] = []
    private let maxHistoryCount = 100

    public init() {}

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    public func record(_ action: CullingAction) {
        undoStack.append(action)
        if undoStack.count > maxHistoryCount {
            undoStack.removeFirst()
        }
        redoStack.removeAll()
    }

    public func popUndo() -> CullingAction? {
        guard let action = undoStack.popLast() else { return nil }
        redoStack.append(action)
        return action
    }

    public func popRedo() -> CullingAction? {
        guard let action = redoStack.popLast() else { return nil }
        undoStack.append(action)
        return action
    }

    public func clear() {
        undoStack.removeAll()
        redoStack.removeAll()
    }
}
