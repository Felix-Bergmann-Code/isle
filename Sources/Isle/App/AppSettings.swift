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

    var screenMode: ScreenMode { didSet { d.set(screenMode.rawValue, forKey: "screenMode"); onScreenChange?() } }
    var hoverDelay: Double { didSet { d.set(hoverDelay, forKey: "hoverDelay") } }
    var haptics: Bool { didSet { d.set(haptics, forKey: "haptics") } }
    var showPillOnNonNotch: Bool { didSet { d.set(showPillOnNonNotch, forKey: "showPillOnNonNotch") } }

    var showMusicActivity: Bool { didSet { d.set(showMusicActivity, forKey: "showMusicActivity") } }
    var showAgentActivity: Bool { didSet { d.set(showAgentActivity, forKey: "showAgentActivity") } }
    var agentBanners: Bool { didSet { d.set(agentBanners, forKey: "agentBanners") } }
    var agentSound: Bool { didSet { d.set(agentSound, forKey: "agentSound") } }
    var agentApprovals: Bool { didSet { d.set(agentApprovals, forKey: "agentApprovals") } }
    var showBackgroundAgents: Bool { didSet { d.set(showBackgroundAgents, forKey: "showBackgroundAgents") } }
    var showBatteryActivity: Bool { didSet { d.set(showBatteryActivity, forKey: "showBatteryActivity") } }
    var showBluetoothActivity: Bool { didSet { d.set(showBluetoothActivity, forKey: "showBluetoothActivity"); onBluetoothChange?() } }
    var meetingReminders: Bool { didSet { d.set(meetingReminders, forKey: "meetingReminders") } }
    var showDevServers: Bool { didSet { d.set(showDevServers, forKey: "showDevServers") } }

    var showVolumeHUD: Bool { didSet { d.set(showVolumeHUD, forKey: "showVolumeHUD") } }
    var replaceSystemHUD: Bool { didSet { d.set(replaceSystemHUD, forKey: "replaceSystemHUD"); onHUDChange?() } }

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
            "agentApprovals": true,
            "showBackgroundAgents": false,
            "showBatteryActivity": true,
            "showBluetoothActivity": true,
            "meetingReminders": true,
            "showDevServers": true,
            "showVolumeHUD": true,
            "replaceSystemHUD": false,
        ])
        screenMode = ScreenMode(rawValue: d.string(forKey: "screenMode") ?? "") ?? .automatic
        hoverDelay = d.double(forKey: "hoverDelay")
        haptics = d.bool(forKey: "haptics")
        showPillOnNonNotch = d.bool(forKey: "showPillOnNonNotch")
        showMusicActivity = d.bool(forKey: "showMusicActivity")
        showAgentActivity = d.bool(forKey: "showAgentActivity")
        agentBanners = d.bool(forKey: "agentBanners")
        agentSound = d.bool(forKey: "agentSound")
        agentApprovals = d.bool(forKey: "agentApprovals")
        showBackgroundAgents = d.bool(forKey: "showBackgroundAgents")
        showBatteryActivity = d.bool(forKey: "showBatteryActivity")
        showBluetoothActivity = d.bool(forKey: "showBluetoothActivity")
        meetingReminders = d.bool(forKey: "meetingReminders")
        showDevServers = d.bool(forKey: "showDevServers")
        showVolumeHUD = d.bool(forKey: "showVolumeHUD")
        replaceSystemHUD = d.bool(forKey: "replaceSystemHUD")
    }
}
