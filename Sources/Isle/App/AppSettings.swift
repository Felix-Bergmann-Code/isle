import Foundation
import Observation

enum ScreenMode: String, CaseIterable, Identifiable {
    case automatic, builtIn, primary
    var id: String { rawValue }
    var label: String {
        switch self {
        case .automatic: return "Automatic (prefer the notch)"
        case .builtIn: return "Built-in display"
        case .primary: return "Primary display (with menu bar)"
        }
    }
}

/// User preferences, persisted in UserDefaults.
@Observable
final class AppSettings {
    static let shared = AppSettings()

    @ObservationIgnored private let d = UserDefaults.standard
    @ObservationIgnored var onScreenChange: (() -> Void)?
    @ObservationIgnored var onHUDChange: (() -> Void)?
    @ObservationIgnored var onBluetoothChange: (() -> Void)?
    @ObservationIgnored var onTimerChange: (() -> Void)?
    @ObservationIgnored var onDownloadsChange: (() -> Void)?
    @ObservationIgnored var onCaptureChange: (() -> Void)?
    @ObservationIgnored var onClipboardChange: (() -> Void)?

    var screenMode: ScreenMode { didSet { d.set(screenMode.rawValue, forKey: "screenMode"); onScreenChange?() } }
    var hoverDelay: Double { didSet { d.set(hoverDelay, forKey: "hoverDelay") } }
    var haptics: Bool { didSet { d.set(haptics, forKey: "haptics") } }
    var showPillOnNonNotch: Bool { didSet { d.set(showPillOnNonNotch, forKey: "showPillOnNonNotch") } }

    var showMusicActivity: Bool { didSet { d.set(showMusicActivity, forKey: "showMusicActivity") } }
    var showAgentActivity: Bool { didSet { d.set(showAgentActivity, forKey: "showAgentActivity") } }
    var agentBanners: Bool { didSet { d.set(agentBanners, forKey: "agentBanners") } }
    var agentSound: Bool { didSet { d.set(agentSound, forKey: "agentSound") } }
    /// Waiting nudges: 3-min pulse, 5/20-min reminder banners, away summary.
    var waitingNudges: Bool { didSet { d.set(waitingNudges, forKey: "waitingNudges") } }
    var agentApprovals: Bool { didSet { d.set(agentApprovals, forKey: "agentApprovals") } }
    var agentReplies: Bool { didSet { d.set(agentReplies, forKey: "agentReplies") } }
    var showBackgroundAgents: Bool { didSet { d.set(showBackgroundAgents, forKey: "showBackgroundAgents") } }
    var showBatteryActivity: Bool { didSet { d.set(showBatteryActivity, forKey: "showBatteryActivity") } }
    var showBluetoothActivity: Bool { didSet { d.set(showBluetoothActivity, forKey: "showBluetoothActivity"); onBluetoothChange?() } }
    var meetingReminders: Bool { didSet { d.set(meetingReminders, forKey: "meetingReminders") } }
    var showDevServers: Bool { didSet { d.set(showDevServers, forKey: "showDevServers") } }
    var showAgentDiffs: Bool { didSet { d.set(showAgentDiffs, forKey: "showAgentDiffs") } }
    var showUsageMeter: Bool { didSet { d.set(showUsageMeter, forKey: "showUsageMeter") } }
    var warnDevServerStops: Bool { didSet { d.set(warnDevServerStops, forKey: "warnDevServerStops") } }
    var commandBanners: Bool { didSet { d.set(commandBanners, forKey: "commandBanners") } }
    /// Seconds a terminal command must run before its finish is worth a banner.
    var commandThreshold: Double { didSet { d.set(commandThreshold, forKey: "commandThreshold") } }
    var showWeather: Bool { didSet { d.set(showWeather, forKey: "showWeather") } }
    var showWorldClocks: Bool { didSet { d.set(showWorldClocks, forKey: "showWorldClocks") } }
    var showCaptureIndicator: Bool { didSet { d.set(showCaptureIndicator, forKey: "showCaptureIndicator"); onCaptureChange?() } }
    var showShipStatus: Bool { didSet { d.set(showShipStatus, forKey: "showShipStatus") } }

    var showVolumeHUD: Bool { didSet { d.set(showVolumeHUD, forKey: "showVolumeHUD") } }
    var replaceSystemHUD: Bool { didSet { d.set(replaceSystemHUD, forKey: "replaceSystemHUD"); onHUDChange?() } }
    var cameraMirror: Bool { didSet { d.set(cameraMirror, forKey: "cameraMirror") } }

    var timerEnabled: Bool { didSet { d.set(timerEnabled, forKey: "timerEnabled"); onTimerChange?() } }
    var timerSound: Bool { didSet { d.set(timerSound, forKey: "timerSound") } }
    var timerPomodoro: Bool { didSet { d.set(timerPomodoro, forKey: "timerPomodoro") } }
    var showDownloads: Bool { didSet { d.set(showDownloads, forKey: "showDownloads"); onDownloadsChange?() } }
    var downloadsToShelf: Bool { didSet { d.set(downloadsToShelf, forKey: "downloadsToShelf") } }

    /// Quiet mode (see QuietMode): the master switch, then its exceptions and automations.
    var quietMode: Bool { didSet { d.set(quietMode, forKey: "quietMode") } }
    var quietAllowApprovals: Bool { didSet { d.set(quietAllowApprovals, forKey: "quietAllowApprovals") } }
    var quietAllowMeetings: Bool { didSet { d.set(quietAllowMeetings, forKey: "quietAllowMeetings") } }
    var quietDuringMeetings: Bool { didSet { d.set(quietDuringMeetings, forKey: "quietDuringMeetings") } }
    var quietStartShortcut: String { didSet { d.set(quietStartShortcut, forKey: "quietStartShortcut") } }
    var quietEndShortcut: String { didSet { d.set(quietEndShortcut, forKey: "quietEndShortcut") } }

    var clipboardHistory: Bool { didSet { d.set(clipboardHistory, forKey: "clipboardHistory"); onClipboardChange?() } }

    /// Scratchpad: a plain-text Note mode on the Shelf.
    var scratchpadNote: Bool { didSet { d.set(scratchpadNote, forKey: "scratchpadNote") } }

    init() {
        d.register(defaults: [
            "screenMode": ScreenMode.automatic.rawValue,
            "hoverDelay": 0.045,
            "haptics": true,
            "showPillOnNonNotch": true,
            "showMusicActivity": true,
            "showAgentActivity": true,
            "agentBanners": true,
            "agentSound": false,
            "waitingNudges": true,
            "agentApprovals": true,
            "agentReplies": true,
            "showBackgroundAgents": false,
            "showBatteryActivity": true,
            "showBluetoothActivity": true,
            "meetingReminders": true,
            "showDevServers": true,
            "showAgentDiffs": true,
            "showUsageMeter": true,
            "warnDevServerStops": true,
            "commandBanners": true,
            "commandThreshold": 30.0,
            "showWeather": true,
            "showWorldClocks": true,
            "showCaptureIndicator": true,
            "showShipStatus": true,
            "showVolumeHUD": true,
            "replaceSystemHUD": false,
            "timerEnabled": true,
            "timerSound": true,
            "timerPomodoro": false,
            "showDownloads": true,
            "downloadsToShelf": true,
            "cameraMirror": true,
            "quietMode": true,
            "quietAllowApprovals": true,
            "quietAllowMeetings": true,
            "quietDuringMeetings": false,
            "quietStartShortcut": "",
            "quietEndShortcut": "",
            "clipboardHistory": true,
            "scratchpadNote": true,
        ])
        screenMode = ScreenMode(rawValue: d.string(forKey: "screenMode") ?? "") ?? .automatic
        hoverDelay = d.double(forKey: "hoverDelay")
        haptics = d.bool(forKey: "haptics")
        showPillOnNonNotch = d.bool(forKey: "showPillOnNonNotch")
        showMusicActivity = d.bool(forKey: "showMusicActivity")
        showAgentActivity = d.bool(forKey: "showAgentActivity")
        agentBanners = d.bool(forKey: "agentBanners")
        agentSound = d.bool(forKey: "agentSound")
        waitingNudges = d.bool(forKey: "waitingNudges")
        agentApprovals = d.bool(forKey: "agentApprovals")
        agentReplies = d.bool(forKey: "agentReplies")
        showBackgroundAgents = d.bool(forKey: "showBackgroundAgents")
        showBatteryActivity = d.bool(forKey: "showBatteryActivity")
        showBluetoothActivity = d.bool(forKey: "showBluetoothActivity")
        meetingReminders = d.bool(forKey: "meetingReminders")
        showDevServers = d.bool(forKey: "showDevServers")
        showAgentDiffs = d.bool(forKey: "showAgentDiffs")
        showUsageMeter = d.bool(forKey: "showUsageMeter")
        warnDevServerStops = d.bool(forKey: "warnDevServerStops")
        commandBanners = d.bool(forKey: "commandBanners")
        commandThreshold = d.double(forKey: "commandThreshold")
        showWeather = d.bool(forKey: "showWeather")
        showWorldClocks = d.bool(forKey: "showWorldClocks")
        showCaptureIndicator = d.bool(forKey: "showCaptureIndicator")
        showShipStatus = d.bool(forKey: "showShipStatus")
        showVolumeHUD = d.bool(forKey: "showVolumeHUD")
        replaceSystemHUD = d.bool(forKey: "replaceSystemHUD")
        timerEnabled = d.bool(forKey: "timerEnabled")
        timerSound = d.bool(forKey: "timerSound")
        timerPomodoro = d.bool(forKey: "timerPomodoro")
        showDownloads = d.bool(forKey: "showDownloads")
        downloadsToShelf = d.bool(forKey: "downloadsToShelf")
        cameraMirror = d.bool(forKey: "cameraMirror")
        quietMode = d.bool(forKey: "quietMode")
        quietAllowApprovals = d.bool(forKey: "quietAllowApprovals")
        quietAllowMeetings = d.bool(forKey: "quietAllowMeetings")
        quietDuringMeetings = d.bool(forKey: "quietDuringMeetings")
        quietStartShortcut = d.string(forKey: "quietStartShortcut") ?? ""
        quietEndShortcut = d.string(forKey: "quietEndShortcut") ?? ""
        clipboardHistory = d.bool(forKey: "clipboardHistory")
        scratchpadNote = d.bool(forKey: "scratchpadNote")
    }
}
