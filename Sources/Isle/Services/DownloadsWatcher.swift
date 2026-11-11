import Foundation

/// Spots browser downloads in progress at the top level of ~/Downloads and notices when they finish.
///
/// Browsers write to a temp file next to the final one and rename it at the end:
///  - Safari: a `name.download` bundle holding `Info.plist` (with progress) and the partial file
///  - Chromium (Chrome, Edge, Brave, Arc, Vivaldi): `name.crdownload`, at first often
///    `Unconfirmed 123.crdownload`; the total size isn't on disk
///  - Firefox: `name.part`, plus a zero-byte placeholder `name`
///
/// Event-driven: a vnode source on the folder reports entries appearing, renaming and going
/// away. Writes into a file don't touch the folder, so while something is downloading a 1 s
/// ticker re-reads sizes. With nothing active there is no timer; a temp file that stopped
/// growing (paused, abandoned) gets a vnode source of its own and wakes the watcher if it grows.
final class DownloadsWatcher {
    struct Progress: Equatable {
        /// Downloads that are actually moving.
        var count: Int
        /// Bytes received so far, across all of them.
        var bytes: Int64
        /// Received / total over the downloads whose total is known; nil when none is.
        var fraction: Double?
    }

    /// On main, once per second while anything is downloading, and nil once nothing is.
    var onProgress: ((Progress?) -> Void)?
    /// On main, with the finished file and its size.
    var onFinish: ((URL, Int64) -> Void)?

    /// A temp file that hasn't grown for this long is treated as paused or abandoned.
    static let stallAfter: TimeInterval = 60

    private struct Temp {
        enum Kind { case safari, chromium, firefox }
        var kind: Kind
        /// Name the finished file gets, when the temp name tells (not for "Unconfirmed 123").
        var finalName: String?
        /// The file being written (inside the bundle for Safari).
        var data: String
        var bytes: Int64
        var total: Int64?
        var modified: Date
    }

    private let queue = DispatchQueue(label: "isle.downloads", qos: .utility)
    private let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
    private var running = false
    private var folderSource: DispatchSourceFileSystemObject?
    private var stallSources: [DispatchSourceFileSystemObject] = []
    private var ticker: DispatchSourceTimer?
    private var pendingScan: DispatchWorkItem?
    private var reopenAttempts = 0
    private var publishedActive = false

    /// Temp files in the last scan, by name.
    private var temps: [String: Temp] = [:]
    /// Every other visible entry in the last scan, to tell which files just appeared.
    private var files: Set<String> = []

    func start() {
        queue.async { [weak self] in
            guard let self, !self.running else { return }
            self.running = true
            self.reopenAttempts = 0
            self.openFolder()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self, self.running else { return }
            self.running = false
            self.folderSource?.cancel(); self.folderSource = nil
            self.pendingScan?.cancel(); self.pendingScan = nil
            self.stopTicker()
            self.disarmStallSources()
            self.temps = [:]
            self.files = []
            self.publishedActive = false
        }
    }

    // MARK: Folder

    private func openFolder() {
        guard running else { return }
        let fd = Darwin.open(folder.path, O_EVTONLY)
        guard fd >= 0 else {
            // Gone for a moment (renamed, recreated): try again a few times. Denied: give up.
            if errno == ENOENT { retryOpen() }
            return
        }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: queue)
        src.setEventHandler { [weak self, unowned src] in
            guard let self else { return }
            if src.data.contains(.rename) || src.data.contains(.delete) {
                // The fd now points at the old folder: watch whatever is at the path now.
                src.cancel()
                self.folderSource = nil
                self.reopenAttempts = 0
                self.retryOpen()
            } else {
                self.scheduleScan()
            }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        folderSource = src
        reopenAttempts = 0
        scan(publish: false)
    }

    private func retryOpen() {
        guard reopenAttempts < 6 else { return }
        let delay = pow(2, Double(reopenAttempts))
        reopenAttempts += 1
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.running, self.folderSource == nil else { return }
            self.openFolder()
        }
    }

    /// Browsers touch the folder several times in a row (create, rename, remove); scan once.
    private func scheduleScan() {
        pendingScan?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.scan(publish: false) }
        pendingScan = work
        queue.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    // MARK: Scan

    /// Re-reads the folder. Progress goes out only from the ticker (`publish`), so the closed
    /// island redraws at most once a second; "nothing active" goes out right away.
    private func scan(publish: Bool) {
        guard running, let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return }
        let now = Date()
        var newTemps: [String: Temp] = [:]
        var newFiles = Set<String>()
        for name in names where !name.hasPrefix(".") {
            if let t = temp(named: name) { newTemps[name] = t } else { newFiles.insert(name) }
        }

        // Temp files that went away: finished if their file is there now, else cancelled.
        let appeared = newFiles.subtracting(files)
        var claimed = Set<String>()
        var finished: [(URL, Int64)] = []
        for (name, t) in temps where newTemps[name] == nil {
            guard let (file, size) = resolve(t, files: newFiles, appeared: appeared, claimed: claimed, now: now) else { continue }
            claimed.insert(file)
            finished.append((folder.appendingPathComponent(file), size))
        }
        temps = newTemps
        files = newFiles

        let active = temps.values.filter { now.timeIntervalSince($0.modified) < Self.stallAfter }
        if active.isEmpty {
            stopTicker()
            armStallSources()
            if publishedActive {
                publishedActive = false
                DispatchQueue.main.async { [weak self] in self?.onProgress?(nil) }
            }
        } else {
            disarmStallSources()
            startTicker()
            if publish {
                publishedActive = true
                let progress = Self.progress(of: active)
                DispatchQueue.main.async { [weak self] in self?.onProgress?(progress) }
            }
        }
        if !finished.isEmpty {
            DispatchQueue.main.async { [weak self] in finished.forEach { self?.onFinish?($0.0, $0.1) } }
        }
    }

    private static func progress(of active: [Temp]) -> Progress {
        let known = active.compactMap { t in t.total.map { (min(t.bytes, $0), $0) } }
        let total = known.reduce(Int64(0)) { $0 + $1.1 }
        let fraction = total > 0 ? Double(known.reduce(Int64(0)) { $0 + $1.0 }) / Double(total) : nil
        return Progress(count: active.count, bytes: active.reduce(0) { $0 + $1.bytes }, fraction: fraction)
    }

    /// The finished file for a temp that went away: its own name if that's there and fresh,
    /// else (Chromium's "Unconfirmed 123", a name made unique) the newest file that just appeared.
    private func resolve(_ t: Temp, files: Set<String>, appeared: Set<String>, claimed: Set<String>, now: Date) -> (String, Int64)? {
        if let name = t.finalName, files.contains(name), !claimed.contains(name),
           let i = Self.info(folder.appendingPathComponent(name).path), !i.isDir, i.size > 0,
           appeared.contains(name) || now.timeIntervalSince(i.modified) < 120 {
            return (name, i.size)
        }
        return appeared.subtracting(claimed)
            .compactMap { n -> (String, Int64, Date)? in
                guard let i = Self.info(folder.appendingPathComponent(n).path), !i.isDir, i.size > 0 else { return nil }
                return (n, i.size, i.modified)
            }
            .max { $0.2 < $1.2 }
            .map { ($0.0, $0.1) }
    }

    private func temp(named name: String) -> Temp? {
        func base(_ ext: String) -> String? {
            let b = String(name.dropLast(ext.count))
            return b.isEmpty ? nil : b
        }
        let path = folder.appendingPathComponent(name).path
        guard let i = Self.info(path) else { return nil }
        if name.hasSuffix(".download") {
            guard i.isDir, let final = base(".download") else { return nil }
            return safari(bundle: path, finalName: final, modified: i.modified)
        }
        if name.hasSuffix(".crdownload") {
            guard !i.isDir, let final = base(".crdownload") else { return nil }
            return Temp(kind: .chromium, finalName: name.hasPrefix("Unconfirmed ") ? nil : final,
                        data: path, bytes: i.size, total: nil, modified: i.modified)
        }
        if name.hasSuffix(".part") {
            guard !i.isDir, let final = base(".part") else { return nil }
            return Temp(kind: .firefox, finalName: final, data: path, bytes: i.size, total: nil, modified: i.modified)
        }
        return nil
    }

    /// Safari keeps progress in the bundle's Info.plist, which it rewrites only now and then,
    /// so the size of the partial file inside wins when it's further along.
    private func safari(bundle: String, finalName: String, modified: Date) -> Temp {
        let plistPath = bundle + "/Info.plist"
        let plist = NSDictionary(contentsOfFile: plistPath)
        var bytes = (plist?["DownloadEntryProgressBytesSoFar"] as? NSNumber)?.int64Value ?? 0
        let total = (plist?["DownloadEntryProgressTotalToLoad"] as? NSNumber)?.int64Value ?? 0
        var data = bundle
        var latest = Self.info(plistPath)?.modified ?? modified
        var largest: Int64 = -1
        for n in (try? FileManager.default.contentsOfDirectory(atPath: bundle)) ?? []
        where n != "Info.plist" && !n.hasPrefix(".") {
            let p = bundle + "/" + n
            guard let i = Self.info(p), !i.isDir, i.size > largest else { continue }
            largest = i.size
            data = p
            latest = max(latest, i.modified)
        }
        bytes = max(bytes, largest)
        return Temp(kind: .safari, finalName: finalName, data: data, bytes: bytes,
                    total: total > 0 ? total : nil, modified: latest)
    }

    private static func info(_ path: String) -> (size: Int64, modified: Date, isDir: Bool)? {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        let m = st.st_mtimespec
        return (Int64(st.st_size), Date(timeIntervalSince1970: TimeInterval(m.tv_sec) + TimeInterval(m.tv_nsec) / 1e9),
                (st.st_mode & S_IFMT) == S_IFDIR)
    }

    // MARK: Ticker & stalled files

    private func startTicker() {
        guard ticker == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(150))
        t.setEventHandler { [weak self] in self?.scan(publish: true) }
        t.resume()
        ticker = t
    }

    private func stopTicker() {
        ticker?.cancel()
        ticker = nil
    }

    /// Everything left is stalled: instead of polling, wait for one of them to grow again.
    /// Re-armed on every scan in this state (scans then come only from folder events).
    private func armStallSources() {
        disarmStallSources()
        for t in temps.values.prefix(16) {
            let fd = Darwin.open(t.data, O_EVTONLY)
            guard fd >= 0 else { continue }
            let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend], queue: queue)
            src.setEventHandler { [weak self] in
                guard let self else { return }
                self.disarmStallSources()
                self.scan(publish: false)
            }
            src.setCancelHandler { close(fd) }
            src.resume()
            stallSources.append(src)
        }
    }

    private func disarmStallSources() {
        stallSources.forEach { $0.cancel() }
        stallSources = []
    }
}
