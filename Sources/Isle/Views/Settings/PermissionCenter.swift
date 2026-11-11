import AppKit
import AVFoundation
import CoreBluetooth
import CoreServices
import EventKit
import Observation
import ServiceManagement
import SwiftUI

/// A macOS privacy permission Isle can use.
enum Permission: String, CaseIterable, Identifiable {
    case accessibility, automation, calendar, bluetooth, camera, downloads

    var id: String { rawValue }

    var title: String {
        switch self {
        case .accessibility: return "Accessibility"
        case .automation: return "Automation"
        case .calendar: return "Calendar"
        case .bluetooth: return "Bluetooth"
        case .camera: return "Camera"
        case .downloads: return "Downloads Folder"
        }
    }

    var symbol: String {
        switch self {
        case .accessibility: return "accessibility"
        case .automation: return "gearshape.2.fill"
        case .calendar: return "calendar"
        case .bluetooth: return "dot.radiowaves.left.and.right"
        case .camera: return "camera.fill"
        case .downloads: return "arrow.down.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .accessibility: return .blue
        case .automation: return Color(white: 0.45)
        case .calendar: return .red
        case .bluetooth: return .blue
        case .camera: return .green
        case .downloads: return .cyan
        }
    }

    /// One line in the collapsed row.
    var purpose: String {
        switch self {
        case .accessibility: return "Media keys and pasting replies"
        case .automation: return "Spotify, Music, iTerm2 and Terminal"
        case .calendar: return "Your meetings on Home and reminders"
        case .bluetooth: return "Banners when AirPods and other devices connect"
        case .camera: return "The mirror before video calls"
        case .downloads: return "Download progress and finished files"
        }
    }

    var does: String {
        switch self {
        case .accessibility:
            return "Catches the volume and brightness keys so only the island's HUD appears, and presses ⌘V and Return to paste your reply into Terminal or the Claude app."
        case .automation:
            return "Asks Spotify and Music what's playing and sends play, pause and skip. Types your reply into the iTerm2 session that runs the agent, or brings the right Terminal tab forward."
        case .calendar:
            return "Reads today's and tomorrow's events to show them on Home, remind you 5 minutes before a meeting and find the video call link."
        case .bluetooth:
            return "Notices when a device such as AirPods, a keyboard or a mouse connects or disconnects, and shows its name."
        case .camera:
            return "Shows a live mirror so you can check how you look before joining a call. The camera runs only while the mirror is on screen."
        case .downloads:
            return "Reads the names and sizes of files at the top level of ~/Downloads to show progress, and puts finished files on the Shelf."
        }
    }

    var never: String {
        switch self {
        case .accessibility: return "Never reads what you type or what's on your screen. Only the media keys are intercepted."
        case .automation: return "Controls no other apps, and talks to Terminal or iTerm2 only when you send a reply."
        case .calendar: return "Never creates, changes or uploads events."
        case .bluetooth: return "Doesn't scan for, pair with or connect to devices."
        case .camera: return "Nothing is recorded, saved or sent anywhere."
        case .downloads: return "Doesn't open, move or upload your files."
        }
    }

    var pane: SystemSettingsPane {
        switch self {
        case .accessibility: return .accessibility
        case .automation: return .automation
        case .calendar: return .calendars
        case .bluetooth: return .bluetooth
        case .camera: return .camera
        case .downloads: return .files
        }
    }

    /// Where it lives in System Settings, for the "turn it off" hint.
    var settingsPath: String {
        switch self {
        case .downloads: return "Privacy & Security → Files & Folders → Isle"
        default: return "Privacy & Security → \(title)"
        }
    }
}

/// What the system says about a permission.
enum PermissionStatus: Equatable {
    case granted, denied, notDetermined
    /// Not checked, because checking would show the prompt (Downloads, while its feature is off).
    case unchecked
}

/// An app Isle sends Apple Events to.
struct AutomationTarget: Identifiable {
    let bundleID: String
    let name: String
    let purpose: String
    var id: String { bundleID }

    static let all = [
        AutomationTarget(bundleID: "com.spotify.client", name: "Spotify", purpose: "Now Playing, artwork and controls"),
        AutomationTarget(bundleID: "com.apple.Music", name: "Music", purpose: "Now Playing and controls"),
        AutomationTarget(bundleID: "com.googlecode.iterm2", name: "iTerm2", purpose: "Types replies into the agent's session"),
        AutomationTarget(bundleID: "com.apple.Terminal", name: "Terminal", purpose: "Brings the agent's tab forward for a reply"),
    ]

    var isReplyTarget: Bool { bundleID == "com.googlecode.iterm2" || bundleID == "com.apple.Terminal" }

    var appURL: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) }
}

enum AutomationStatus: Equatable {
    case granted, denied, notDetermined, notRunning, notInstalled, unknown
}

/// A feature that needs a permission, and whether it's switched on.
struct PermissionUse: Identifiable {
    let title: String
    let isOn: Bool
    let page: SettingsPage
    let anchor: String
    var id: String { title }
}

/// How a permission's state reads in the UI.
struct PermissionBadge {
    let text: String
    let color: Color
    let symbol: String
    /// Something the person turned on can't work until they act.
    let needsAttention: Bool
}

/// Live state of every permission and of the files Isle changes, re-read while the settings
/// window is on screen. Nothing here ever shows a prompt unless one of the `request` calls is used.
@Observable
final class PermissionCenter {
    static let shared = PermissionCenter()

    private(set) var accessibility = false
    private(set) var calendar: PermissionStatus = .notDetermined
    private(set) var calendarWriteOnly = false
    private(set) var bluetooth: PermissionStatus = .notDetermined
    private(set) var camera: PermissionStatus = .notDetermined
    private(set) var downloads: PermissionStatus = .unchecked
    private(set) var automation: [String: AutomationStatus] = [:]
    private(set) var claudeHooks = ClaudeHookInstaller.isInstalled
    private(set) var zshHook = ShellHookInstaller.isInstalled
    private(set) var loginItem = SMAppService.mainApp.status
    private(set) var serverListening = true

    @ObservationIgnored private let queue = DispatchQueue(label: "isle.permissions", qos: .utility)
    @ObservationIgnored private var bluetoothRequester: CBCentralManager?
    @ObservationIgnored private var busy = false

    /// Cheap checks right away, file and Apple Event checks off the main thread.
    func refresh(env: AppEnvironment) {
        set(\.accessibility, AXIsProcessTrusted())
        let cal = EKEventStore.authorizationStatus(for: .event)
        set(\.calendarWriteOnly, cal == .writeOnly)
        set(\.calendar, cal == .fullAccess ? .granted : cal == .notDetermined ? .notDetermined : .denied)
        set(\.bluetooth, Self.map(CBManager.authorization))
        set(\.camera, Self.map(AVCaptureDevice.authorizationStatus(for: .video)))
        set(\.loginItem, SMAppService.mainApp.status)
        set(\.serverListening, env.hooks.isListening || Demo.isEnabled)

        guard !busy else { return }
        busy = true
        let checkDownloads = env.settings.showDownloads
        queue.async { [weak self] in
            let downloads = checkDownloads ? Self.downloadsStatus() : .unchecked
            var automation: [String: AutomationStatus] = [:]
            for t in AutomationTarget.all { automation[t.bundleID] = Self.automationStatus(t.bundleID, ask: false) }
            let claude = ClaudeHookInstaller.isInstalled
            let zsh = ShellHookInstaller.isInstalled
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = false
                self.set(\.downloads, downloads)
                self.set(\.automation, automation)
                self.set(\.claudeHooks, claude)
                self.set(\.zshHook, zsh)
            }
        }
    }

    /// Assigns only on change, so observers don't redraw every poll.
    private func set<T: Equatable>(_ key: ReferenceWritableKeyPath<PermissionCenter, T>, _ value: T) {
        if self[keyPath: key] != value { self[keyPath: key] = value }
    }

    func status(_ p: Permission) -> PermissionStatus {
        switch p {
        case .accessibility: return accessibility ? .granted : .notDetermined
        case .calendar: return calendar
        case .bluetooth: return bluetooth
        case .camera: return camera
        case .downloads: return downloads
        case .automation:
            let installed = AutomationTarget.all.compactMap { t -> AutomationStatus? in
                let s = automation[t.bundleID] ?? .unknown
                return s == .notInstalled ? nil : s
            }
            if installed.contains(.denied) { return .denied }
            if !installed.isEmpty, installed.allSatisfy({ $0 == .granted }) { return .granted }
            return installed.contains(.granted) ? .granted : .notDetermined
        }
    }

    func uses(_ p: Permission, _ s: AppSettings) -> [PermissionUse] {
        switch p {
        case .accessibility:
            return [
                PermissionUse(title: "Replace the system volume & brightness HUD", isOn: s.replaceSystemHUD, page: .hud, anchor: "replace"),
                PermissionUse(title: "Paste replies to agents for you", isOn: s.agentReplies, page: .agents, anchor: "replies"),
            ]
        case .automation:
            return [
                PermissionUse(title: "Now Playing and player controls", isOn: true, page: .activities, anchor: "music"),
                PermissionUse(title: "Reply to agents in iTerm2 and Terminal", isOn: s.agentReplies, page: .agents, anchor: "replies"),
            ]
        case .calendar:
            return [
                PermissionUse(title: "Calendar on Home", isOn: true, page: .home, anchor: "calendar"),
                PermissionUse(title: "Meeting reminders", isOn: s.meetingReminders, page: .activities, anchor: "meetings"),
                PermissionUse(title: "Quiet mode during meetings", isOn: s.quietMode && s.quietDuringMeetings, page: .quiet, anchor: "meetings"),
                PermissionUse(title: "Camera mirror before calls", isOn: s.cameraMirror, page: .home, anchor: "mirror"),
            ]
        case .bluetooth:
            return [PermissionUse(title: "Bluetooth device banners", isOn: s.showBluetoothActivity, page: .activities, anchor: "bluetooth")]
        case .camera:
            return [PermissionUse(title: "Camera mirror", isOn: s.cameraMirror, page: .home, anchor: "mirror")]
        case .downloads:
            return [
                PermissionUse(title: "Download progress in the notch", isOn: s.showDownloads, page: .shelf, anchor: "downloads"),
                PermissionUse(title: "Finished downloads on the Shelf", isOn: s.showDownloads && s.downloadsToShelf, page: .shelf, anchor: "downloads"),
            ]
        }
    }

    func badge(_ p: Permission, _ s: AppSettings) -> PermissionBadge {
        let needed = uses(p, s).contains { $0.isOn }
        switch status(p) {
        case .granted:
            return PermissionBadge(text: "Allowed", color: .green, symbol: "checkmark.circle.fill", needsAttention: false)
        case .denied:
            if p == .calendar, calendarWriteOnly {
                return PermissionBadge(text: "Add only", color: needed ? .orange : .secondary, symbol: "exclamationmark.triangle.fill", needsAttention: needed)
            }
            return needed
                ? PermissionBadge(text: "Denied", color: .red, symbol: "xmark.circle.fill", needsAttention: true)
                : PermissionBadge(text: "Not allowed", color: .secondary, symbol: "minus.circle.fill", needsAttention: false)
        case .notDetermined:
            if p == .accessibility {
                return needed
                    ? PermissionBadge(text: "Needed", color: .orange, symbol: "exclamationmark.triangle.fill", needsAttention: true)
                    : PermissionBadge(text: "Not needed", color: .secondary, symbol: "minus.circle.fill", needsAttention: false)
            }
            return needed
                ? PermissionBadge(text: "Asked when used", color: .blue, symbol: "clock.fill", needsAttention: false)
                : PermissionBadge(text: "Not asked", color: .secondary, symbol: "minus.circle.fill", needsAttention: false)
        case .unchecked:
            return PermissionBadge(text: "Not in use", color: .secondary, symbol: "minus.circle.fill", needsAttention: false)
        }
    }

    func attentionCount(_ s: AppSettings) -> Int {
        Permission.allCases.filter { badge($0, s).needsAttention }.count
    }

    // MARK: Requests (these may show the system prompt)

    func request(_ p: Permission, env: AppEnvironment) {
        switch p {
        case .accessibility:
            MediaKeyTap.requestTrust()
            p.pane.open()
        case .calendar:
            if calendar == .notDetermined { env.calendar.requestAccess() } else { p.pane.open() }
        case .bluetooth:
            if bluetooth == .notDetermined {
                // Creating a central manager is what asks; it's released after the next refresh.
                bluetoothRequester = CBCentralManager(delegate: nil, queue: .main)
            } else { p.pane.open() }
        case .camera:
            if camera == .notDetermined {
                AVCaptureDevice.requestAccess(for: .video) { [weak self] _ in
                    DispatchQueue.main.async { self?.refresh(env: env) }
                }
            } else { p.pane.open() }
        case .downloads:
            if downloads != .granted {
                queue.async { _ = Self.downloadsStatus() }
            }
            if downloads == .denied { p.pane.open() }
        case .automation:
            p.pane.open()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.refresh(env: env) }
    }

    /// Shows the "Isle wants to control …" prompt; only possible while the app runs.
    func requestAutomation(_ target: AutomationTarget, env: AppEnvironment) {
        queue.async { [weak self] in
            _ = Self.automationStatus(target.bundleID, ask: true)
            DispatchQueue.main.async { self?.refresh(env: env) }
        }
    }

    // MARK: System checks

    private static func map(_ a: CBManagerAuthorization) -> PermissionStatus {
        switch a {
        case .allowedAlways: return .granted
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }

    private static func map(_ a: AVAuthorizationStatus) -> PermissionStatus {
        switch a {
        case .authorized: return .granted
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }

    /// Listing the folder is the only way to know; it prompts if macOS hasn't asked yet, so this
    /// runs only while the Downloads feature (which asks anyway) is on, or on request.
    private static func downloadsStatus() -> PermissionStatus {
        let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        guard let dir = opendir(folder.path) else {
            return errno == EPERM || errno == EACCES ? .denied : .unchecked
        }
        closedir(dir)
        return .granted
    }

    /// Asks TCC whether Isle may send Apple Events to the app. Blocks (and, with `ask`, shows
    /// the prompt), so never on the main thread. A target that isn't running can't be checked.
    private static func automationStatus(_ bundleID: String, ask: Bool) -> AutomationStatus {
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil else { return .notInstalled }
        var target = AEAddressDesc()
        let created = bundleID.withCString { AECreateDesc(DescType(typeApplicationBundleID), $0, strlen($0), &target) }
        guard created == noErr else { return .unknown }
        defer { AEDisposeDesc(&target) }
        switch AEDeterminePermissionToAutomateTarget(&target, AEEventClass(typeWildCard), AEEventID(typeWildCard), ask) {
        case noErr: return .granted
        case -1743: return .denied        // errAEEventNotPermitted
        case -1744: return .notDetermined // errAEEventWouldRequireUserConsent
        case -600: return .notRunning     // procNotFound
        default: return .unknown
        }
    }
}
