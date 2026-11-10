import AppKit
import SwiftUI
import Observation

enum MediaSource: String {
    case spotify, music
    var bundleID: String { self == .spotify ? "com.spotify.client" : "com.apple.Music" }
    var appName: String { self == .spotify ? "Spotify" : "Music" }
    var appIcon: NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}

struct NowPlaying: Equatable {
    var source: MediaSource
    var title: String
    var artist: String
    var album: String
    var duration: Double
    var position: Double
    var positionDate: Date
    var isPlaying: Bool
    var trackID: String

    func elapsed(at date: Date = Date()) -> Double {
        guard duration > 0 else { return 0 }
        let p = isPlaying ? position + date.timeIntervalSince(positionDate) : position
        return min(max(0, p), duration)
    }
}

/// Now Playing for Spotify and Apple Music.
/// Track changes arrive via distributed notifications (no polling); artwork,
/// position and controls go through AppleScript on a background queue.
@Observable
final class MediaService: NSObject {
    var now: NowPlaying?
    var artwork: NSImage?
    var accent: Color = Color(white: 0.85)

    @ObservationIgnored private var artworkTrackID: String?
    @ObservationIgnored private let scriptQueue = DispatchQueue(label: "isle.applescript", qos: .userInitiated)
    @ObservationIgnored private var syncTimer: Timer?
    @ObservationIgnored private var syncClients = 0

    func start() {
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(self, selector: #selector(spotifyChanged(_:)),
                        name: NSNotification.Name("com.spotify.client.PlaybackStateChanged"),
                        object: nil, suspensionBehavior: .deliverImmediately)
        dnc.addObserver(self, selector: #selector(musicChanged(_:)),
                        name: NSNotification.Name("com.apple.Music.playerInfo"),
                        object: nil, suspensionBehavior: .deliverImmediately)

        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let self, let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            if app.bundleIdentifier == self.now?.source.bundleID {
                self.now = nil
                self.artwork = nil
                self.artworkTrackID = nil
            }
        }
        ws.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            if app.bundleIdentifier == MediaSource.spotify.bundleID {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self?.sync(.spotify) }
            } else if app.bundleIdentifier == MediaSource.music.bundleID {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self?.sync(.music) }
            }
        }

        if isRunning(.spotify) { sync(.spotify) }
        if isRunning(.music) { sync(.music) }
    }

    // MARK: Notifications

    @objc private func spotifyChanged(_ n: Notification) {
        let info = n.userInfo ?? [:]
        let state = (info["Player State"] as? String) ?? ""
        if state == "Stopped" {
            if now?.source == .spotify { now = nil; artwork = nil; artworkTrackID = nil }
            return
        }
        let trackID = (info["Track ID"] as? String) ?? ""
        let np = NowPlaying(
            source: .spotify,
            title: (info["Name"] as? String) ?? "",
            artist: (info["Artist"] as? String) ?? "",
            album: (info["Album"] as? String) ?? "",
            duration: ((info["Duration"] as? NSNumber)?.doubleValue ?? 0) / 1000,
            position: (info["Playback Position"] as? NSNumber)?.doubleValue ?? 0,
            positionDate: Date(),
            isPlaying: state == "Playing",
            trackID: trackID
        )
        apply(np)
    }

    @objc private func musicChanged(_ n: Notification) {
        let info = n.userInfo ?? [:]
        let state = (info["Player State"] as? String) ?? ""
        if state == "Stopped" {
            if now?.source == .music { now = nil; artwork = nil; artworkTrackID = nil }
            return
        }
        let trackID = (info["PersistentID"] as? NSNumber)?.stringValue ?? (info["Name"] as? String ?? "")
        var np = NowPlaying(
            source: .music,
            title: (info["Name"] as? String) ?? "",
            artist: (info["Artist"] as? String) ?? "",
            album: (info["Album"] as? String) ?? "",
            duration: ((info["Total Time"] as? NSNumber)?.doubleValue ?? 0) / 1000,
            position: now?.trackID == trackID ? (now?.elapsed() ?? 0) : 0,
            positionDate: Date(),
            isPlaying: state == "Playing",
            trackID: trackID
        )
        if now?.trackID != trackID { np.position = 0 }
        apply(np)
        syncPosition() // Music doesn't include the position in its notification
    }

    private func apply(_ np: NowPlaying) {
        // A paused source shouldn't steal focus from one that's playing.
        if let cur = now, cur.source != np.source, cur.isPlaying, !np.isPlaying { return }
        now = np
        if artworkTrackID != np.trackID { fetchArtwork(for: np) }
    }

    // MARK: Sync

    func sync(_ source: MediaSource) {
        guard isRunning(source) else { return }
        let script: String
        switch source {
        case .spotify:
            script = """
            tell application "Spotify"
                set st to (player state as string)
                if st is "stopped" then return {st}
                set t to current track
                return {st, (name of t), (artist of t), (album of t), (duration of t), (player position), (id of t)}
            end tell
            """
        case .music:
            script = """
            tell application "Music"
                set st to (player state as string)
                if st is "stopped" then return {st}
                set t to current track
                return {st, (name of t), (artist of t), (album of t), ((duration of t) * 1000), (player position), (persistent ID of t)}
            end tell
            """
        }
        run(script) { [weak self] d in
            guard let self, let d, d.numberOfItems >= 1 else { return }
            let state = (d.atIndex(1)?.stringValue ?? "").lowercased()
            guard state != "stopped", d.numberOfItems >= 7 else { return }
            let np = NowPlaying(
                source: source,
                title: d.atIndex(2)?.stringValue ?? "",
                artist: d.atIndex(3)?.stringValue ?? "",
                album: d.atIndex(4)?.stringValue ?? "",
                duration: (d.atIndex(5)?.doubleValue ?? 0) / 1000,
                position: d.atIndex(6)?.doubleValue ?? 0,
                positionDate: Date(),
                isPlaying: state == "playing",
                trackID: d.atIndex(7)?.stringValue ?? ""
            )
            self.apply(np)
        }
    }

    func syncPosition() {
        guard let np = now, isRunning(np.source) else { return }
        run("tell application \"\(np.source.appName)\" to return player position") { [weak self] d in
            guard let self, let p = d?.doubleValue, var cur = self.now, cur.trackID == np.trackID else { return }
            if abs(cur.elapsed() - p) > 0.6 {
                cur.position = p
                cur.positionDate = Date()
                self.now = cur
            }
        }
    }

    /// Ref-counted position re-sync while a player UI is visible.
    func beginLiveUpdates() {
        syncClients += 1
        guard syncClients == 1 else { return }
        syncPosition()
        syncTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            guard let self, self.now?.isPlaying == true else { return }
            self.syncPosition()
        }
    }

    func endLiveUpdates() {
        syncClients = max(0, syncClients - 1)
        if syncClients == 0 { syncTimer?.invalidate(); syncTimer = nil }
    }

    // MARK: Controls

    func togglePlayPause() {
        guard var np = now else { return }
        np.position = np.elapsed()
        np.positionDate = Date()
        np.isPlaying.toggle()
        now = np
        run("tell application \"\(np.source.appName)\" to playpause")
    }

    func next() { command("next track") }
    func previous() { command("previous track") }

    func seek(to seconds: Double) {
        guard var np = now else { return }
        np.position = seconds
        np.positionDate = Date()
        now = np
        run("tell application \"\(np.source.appName)\" to set player position to \(String(format: "%.2f", seconds))")
    }

    private func command(_ cmd: String) {
        guard let np = now else { return }
        run("tell application \"\(np.source.appName)\" to \(cmd)") { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { self?.sync(np.source) }
        }
    }

    func launch(_ source: MediaSource) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: source.bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    func activateSource() {
        guard let np = now else { return }
        NSRunningApplication.runningApplications(withBundleIdentifier: np.source.bundleID).first?.activate()
    }

    // MARK: Artwork

    private func fetchArtwork(for np: NowPlaying) {
        artworkTrackID = np.trackID
        let tid = np.trackID
        switch np.source {
        case .spotify:
            run("tell application \"Spotify\" to return artwork url of current track") { [weak self] d in
                guard let s = d?.stringValue, let url = URL(string: s) else { return }
                URLSession.shared.dataTask(with: url) { data, _, _ in
                    guard let data, let img = NSImage(data: data) else { return }
                    DispatchQueue.main.async { self?.setArtwork(img, for: tid) }
                }.resume()
            }
        case .music:
            run("tell application \"Music\" to return raw data of artwork 1 of current track") { [weak self] d in
                guard let data = d?.data, let img = NSImage(data: data) else {
                    self?.setArtwork(nil, for: tid)
                    return
                }
                self?.setArtwork(img, for: tid)
            }
        }
    }

    private func setArtwork(_ image: NSImage?, for trackID: String) {
        guard artworkTrackID == trackID else { return }
        withAnimation(.easeInOut(duration: 0.35)) {
            artwork = image
            if let image, let c = image.vibrantAverageColor() { accent = Color(nsColor: c) }
            else { accent = Color(white: 0.85) }
        }
    }

    // MARK: Helpers

    private func isRunning(_ source: MediaSource) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: source.bundleID).isEmpty
    }

    private func run(_ source: String, completion: ((NSAppleEventDescriptor?) -> Void)? = nil) {
        scriptQueue.async {
            var error: NSDictionary?
            let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
            DispatchQueue.main.async { completion?(error == nil ? result : nil) }
        }
    }
}

extension NSImage {
    /// Average colour of the image, pushed to be bright/saturated enough to
    /// read as an accent on black.
    func vibrantAverageColor() -> NSColor? {
        guard let cg = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let side = 8
        var px = [UInt8](repeating: 0, count: side * side * 4)
        guard let ctx = CGContext(data: &px, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
        // Weight saturated pixels higher so a white border doesn't wash it out.
        var r = 0.0, g = 0.0, b = 0.0, wsum = 0.0
        for i in stride(from: 0, to: px.count, by: 4) {
            let pr = Double(px[i]) / 255, pg = Double(px[i + 1]) / 255, pb = Double(px[i + 2]) / 255
            let mx = max(pr, pg, pb), mn = min(pr, pg, pb)
            let w = 0.15 + (mx - mn) * 2
            r += pr * w; g += pg * w; b += pb * w; wsum += w
        }
        guard wsum > 0 else { return nil }
        let c = NSColor(deviceRed: r / wsum, green: g / wsum, blue: b / wsum, alpha: 1)
        var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
        c.getHue(&h, saturation: &s, brightness: &v, alpha: &a)
        return NSColor(hue: h, saturation: min(1, s * 1.25), brightness: max(0.72, min(1, v * 1.2)), alpha: 1)
    }
}
