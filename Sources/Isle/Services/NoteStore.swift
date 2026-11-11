import AppKit
import Observation

/// The Shelf's scratchpad: one plain-text note in ~/Library/Application Support/Isle/note.txt.
/// Saved half a second after typing stops, and right away when the note leaves the screen or
/// Isle quits, so nothing typed is lost.
@Observable
final class NoteStore {
    static let shared = NoteStore()

    var text: String {
        didSet {
            guard text != oldValue else { return }
            dirty = true
            scheduleSave()
        }
    }
    /// Set by `isle note`: the note view focuses its editor once it's on screen.
    var focusRequested = false

    @ObservationIgnored private let url: URL
    @ObservationIgnored private var dirty = false
    @ObservationIgnored private var saveWork: DispatchWorkItem?

    static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Isle/note.txt")
    }

    init() {
        url = Self.fileURL
        text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                               object: nil, queue: .main) { [weak self] _ in self?.save() }
    }

    /// Replace the whole text so ⌘Z brings the old one back. Edits made from code bypass the
    /// editor's own undo, so this registers its own step (and its redo) on the window's manager.
    func replace(with new: String, undoManager: UndoManager?) {
        let old = text
        guard old != new else { return }
        undoManager?.registerUndo(withTarget: self) { $0.replace(with: old, undoManager: undoManager) }
        text = new
    }

    func save() {
        saveWork?.cancel(); saveWork = nil
        guard dirty else { return }
        dirty = false
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.save() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }
}
