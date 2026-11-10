import AppKit
import QuickLookThumbnailing
import Observation
import UniformTypeIdentifiers

struct ShelfItem: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    var name: String { url.lastPathComponent }
}

/// Temporary file shelf: drag files onto the notch, drag them back out later.
@Observable
final class ShelfStore {
    var items: [ShelfItem] = []
    var thumbnails: [URL: NSImage] = [:]

    @ObservationIgnored private let key = "shelfPaths"

    init() {
        let paths = Demo.isEnabled ? [] : UserDefaults.standard.stringArray(forKey: key) ?? []
        items = paths.map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .map { ShelfItem(url: $0) }
        items.forEach { thumbnail(for: $0.url) }
    }

    func add(urls: [URL]) {
        var added = 0
        for url in urls where !items.contains(where: { $0.url == url }) {
            items.append(ShelfItem(url: url))
            thumbnail(for: url)
            added += 1
        }
        if added > 0 { save() }
    }

    /// Loads file URLs out of drag providers. Calls back on main with the URLs.
    static func loadURLs(from providers: [NSItemProvider], completion: @escaping ([URL]) -> Void) {
        let group = DispatchGroup()
        var urls: [URL] = []
        let lock = NSLock()
        for p in providers where p.canLoadObject(ofClass: URL.self) {
            group.enter()
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                if let url, url.isFileURL { lock.lock(); urls.append(url); lock.unlock() }
                group.leave()
            }
        }
        group.notify(queue: .main) { completion(urls) }
    }

    func remove(_ item: ShelfItem) {
        items.removeAll { $0.id == item.id }
        thumbnails[item.url] = nil
        save()
    }

    func clear() {
        items.removeAll()
        thumbnails.removeAll()
        save()
    }

    func open(_ item: ShelfItem) { NSWorkspace.shared.open(item.url) }
    func reveal(_ item: ShelfItem) { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }

    static func airDrop(_ urls: [URL]) {
        guard !urls.isEmpty, let service = NSSharingService(named: .sendViaAirDrop) else { return }
        NSApp.activate(ignoringOtherApps: true)
        if service.canPerform(withItems: urls) { service.perform(withItems: urls) }
    }

    private func save() {
        guard !Demo.isEnabled else { return }
        UserDefaults.standard.set(items.map(\.url.path), forKey: key)
    }

    private func thumbnail(for url: URL) {
        thumbnails[url] = NSWorkspace.shared.icon(forFile: url.path)
        let req = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 96, height: 96), scale: 2,
                                               representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { [weak self] rep, _ in
            guard let img = rep?.nsImage else { return }
            DispatchQueue.main.async { self?.thumbnails[url] = img }
        }
    }
}
