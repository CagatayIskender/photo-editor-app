import Foundation

/// Undo and redo for an `EditDocument`, kept as a list of snapshots.
///
/// Documents are small value types, so whole snapshots are simpler and safer
/// than inverse operations. Continuous gestures (a slider drag, a pinch) call
/// `beginTransaction()` when they start and `commit` when they end, which
/// records one undo step for the whole gesture.
public struct EditHistory: Equatable, Sendable {
    public static let defaultLimit = 100

    public private(set) var snapshots: [EditDocument]
    public private(set) var cursor: Int
    public let limit: Int
    private var transactionBase: EditDocument?

    public init(initial: EditDocument, limit: Int = EditHistory.defaultLimit) {
        self.snapshots = [initial]
        self.cursor = 0
        self.limit = max(2, limit)
    }

    /// The document as it is now, including any change in progress.
    public var current: EditDocument { snapshots[cursor] }

    public var canUndo: Bool { cursor > 0 && transactionBase == nil }
    public var canRedo: Bool { cursor < snapshots.count - 1 && transactionBase == nil }
    public var isInTransaction: Bool { transactionBase != nil }

    /// Records a finished change as one undo step. Does nothing if the
    /// document did not actually change.
    public mutating func commit(_ document: EditDocument) {
        if transactionBase != nil {
            endTransaction(with: document)
            return
        }
        guard document != current else { return }
        push(document)
    }

    /// Starts a continuous change. Call `update` while it runs and `commit` at the end.
    public mutating func beginTransaction() {
        guard transactionBase == nil else { return }
        transactionBase = current
    }

    /// Shows an in-progress value without creating an undo step.
    public mutating func update(_ document: EditDocument) {
        if transactionBase == nil { beginTransaction() }
        snapshots[cursor] = document
    }

    /// Abandons a continuous change and restores the document from before it.
    public mutating func cancelTransaction() {
        guard let base = transactionBase else { return }
        snapshots[cursor] = base
        transactionBase = nil
    }

    private mutating func endTransaction(with document: EditDocument) {
        guard let base = transactionBase else { return }
        transactionBase = nil
        snapshots[cursor] = base
        guard document != base else { return }
        push(document)
    }

    private mutating func push(_ document: EditDocument) {
        if cursor < snapshots.count - 1 {
            snapshots.removeSubrange((cursor + 1)...)
        }
        snapshots.append(document)
        if snapshots.count > limit {
            snapshots.removeFirst(snapshots.count - limit)
        }
        cursor = snapshots.count - 1
    }

    @discardableResult
    public mutating func undo() -> EditDocument? {
        guard canUndo else { return nil }
        cursor -= 1
        return current
    }

    @discardableResult
    public mutating func redo() -> EditDocument? {
        guard canRedo else { return nil }
        cursor += 1
        return current
    }

    public static func == (lhs: EditHistory, rhs: EditHistory) -> Bool {
        lhs.snapshots == rhs.snapshots && lhs.cursor == rhs.cursor && lhs.limit == rhs.limit
    }
}
