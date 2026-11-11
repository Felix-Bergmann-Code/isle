import AppKit
import SwiftUI

/// Downloads in the island: a ring with the percentage (or the size so far, when the browser
/// doesn't say how big the file is) beside the notch while anything downloads, then a banner
/// with the file's icon, and the file waiting on the Shelf to be dragged out.
extension AppEnvironment {
    static let downloadTint = Color(red: 0.25, green: 0.6, blue: 1.0)

    func startDownloads() {
        downloads.onProgress = { [weak self] p in self?.showDownloads(p) }
        downloads.onFinish = { [weak self] url, size in self?.downloadFinished(url, size: size) }
        if settings.showDownloads { downloads.start() }
        settings.onDownloadsChange = { [weak self] in
            guard let self else { return }
            if self.settings.showDownloads {
                self.downloads.start()
            } else {
                self.downloads.stop()
                self.vm.clearLive("download")
            }
        }
    }

    private func showDownloads(_ p: DownloadsWatcher.Progress?) {
        guard let p, settings.showDownloads else { vm.clearLive("download"); return }
        // Rounded to what's shown, so an unchanged "68%" doesn't redraw the closed island.
        var progress: Double?
        var text: String
        if let f = p.fraction {
            let percent = min(99, Int(f * 100))
            progress = Double(percent) / 100
            text = "\(percent)%"
        } else {
            text = Self.shortSize(p.bytes)
        }
        if p.count > 1 { text = "\(p.count) · \(text)" }
        vm.setLive(LiveItem(id: "download", priority: 40, icon: "arrow.down", tint: Self.downloadTint,
                            progress: progress, text: text, tab: settings.downloadsToShelf ? .shelf : nil))
    }

    private func downloadFinished(_ url: URL, size: Int64) {
        guard settings.showDownloads else { return }
        let toShelf = settings.downloadsToShelf
        if toShelf { shelf.add(urls: [url]) }  // add(urls:) skips files already there
        let size = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
        vm.notify(Notice(icon: "arrow.down", tint: Self.downloadTint, image: NSWorkspace.shared.icon(forFile: url.path),
                         title: Self.middleTruncated(url.lastPathComponent), subtitle: "Downloaded · \(size)",
                         tab: toShelf ? .shelf : nil), duration: 5)
    }

    /// "24 MB", "1.2 GB": whole units below a gigabyte so the compact text stays short and steady.
    private static func shortSize(_ bytes: Int64) -> String {
        let b = Double(bytes)
        if b < 1e6 { return "\(max(1, Int(b / 1e3))) KB" }
        if b < 1e9 { return "\(Int(b / 1e6)) MB" }
        return "\((b / 1e9).formatted(.number.precision(.fractionLength(1)))) GB"
    }

    /// The banner title is one line; cut long names in the middle so the extension stays visible.
    private static func middleTruncated(_ name: String, limit: Int = 40) -> String {
        guard name.count > limit else { return name }
        let tail = limit / 3
        return "\(name.prefix(limit - tail - 1))…\(name.suffix(tail))"
    }
}
