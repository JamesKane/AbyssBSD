// Undo — decided (PHASE10.md P10.5, §6.3).
//
// **Per window, held rather than owned.** A window holds an `UndoStack`; it is
// not one. Jaguar's answer was per *document* (`NSUndoManager` on the
// document, the window asking its document), and this desktop has no document
// model yet — the Finder has none at all. Holding the stack in its own object
// means Phase 15's document-based applications move it to the document without
// changing a single `Command`.
//
// **Undo is a command like any other.** `edit.undo` and `edit.redo` are verbs
// in the application's model, so a script can undo too, and the Edit menu's
// two items are *derived* from the top of the stack: their titles ("Undo Move
// to Trash") and their enablement. A verb that changes something either pushes
// the inverse here or does not; there is no third way, and the reviewer of a
// verb can see which it did.
//
// **An undo can fail**, because the world moved: the folder is no longer
// empty, the original name was taken. It is then `refused` with the reason,
// through the same result path as any verb, and stays on the stack — the
// person can put things right and try again.

/// One reversible change.
public struct UndoEntry {
    /// What the menu calls it, without the verb: "Move to Trash".
    public let name: String
    public let undo: () -> CommandResult
    public let redo: () -> CommandResult
    public init(_ name: String, undo: @escaping () -> CommandResult,
                redo: @escaping () -> CommandResult) {
        self.name = name; self.undo = undo; self.redo = redo
    }
}

public final class UndoStack {
    private var done: [UndoEntry] = []
    private var undone: [UndoEntry] = []
    /// How much is remembered. Undo is for the last few things, not a journal.
    public let limit: Int
    /// Called whenever what the Edit menu should say may have changed.
    public var onChange: () -> Void = {}

    public init(limit: Int = 100) { self.limit = limit }

    /// Something changed and can be reversed. Anything undone and not yet
    /// redone is forgotten: a new change starts a new future.
    public func push(_ e: UndoEntry) {
        done.append(e)
        if done.count > limit { done.removeFirst(done.count - limit) }
        undone.removeAll()
        onChange()
    }

    public var canUndo: Bool { !done.isEmpty }
    public var canRedo: Bool { !undone.isEmpty }

    /// "Undo Move to Trash", or plain "Undo" with nothing to undo.
    public var undoTitle: String { done.last.map { "Undo \($0.name)" } ?? "Undo" }
    public var redoTitle: String { undone.last.map { "Redo \($0.name)" } ?? "Redo" }

    public var undoEnablement: Enablement {
        canUndo ? .enabled : .disabled("there is nothing to undo")
    }
    public var redoEnablement: Enablement {
        canRedo ? .enabled : .disabled("there is nothing to redo")
    }

    @discardableResult
    public func undo() -> CommandResult {
        guard let e = done.last else { return .refused("there is nothing to undo") }
        let r = e.undo()
        if case .ok = r {
            done.removeLast()
            undone.append(e)
            onChange()
        }
        return r
    }

    @discardableResult
    public func redo() -> CommandResult {
        guard let e = undone.last else { return .refused("there is nothing to redo") }
        let r = e.redo()
        if case .ok = r {
            undone.removeLast()
            done.append(e)
            onChange()
        }
        return r
    }
}
