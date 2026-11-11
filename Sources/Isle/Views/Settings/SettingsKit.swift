import AppKit
import Observation
import SwiftUI

// MARK: - Navigation

/// One page in the settings sidebar.
enum SettingsPage: String, CaseIterable, Identifiable, Hashable {
    case general, activities, hud, agents, integrations, home, shelf, quiet, permissions, about

    var id: String { rawValue }

    /// Sidebar groups, in order; a gap separates them, as in System Settings.
    static let groups: [[SettingsPage]] = [
        [.general, .activities, .hud],
        [.agents, .integrations],
        [.home, .shelf, .quiet],
        [.permissions],
    ]

    var title: String {
        switch self {
        case .general: return "General"
        case .activities: return "Live Activities"
        case .hud: return "Volume & Brightness"
        case .agents: return "Agents"
        case .integrations: return "Hooks & Scripts"
        case .home: return "Home"
        case .shelf: return "Shelf"
        case .quiet: return "Quiet Mode"
        case .permissions: return "Privacy & Permissions"
        case .about: return "About Isle"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape.fill"
        case .activities: return "capsule.fill"
        case .hud: return "speaker.wave.2.fill"
        case .agents: return "sparkles"
        case .integrations: return "terminal.fill"
        case .home: return "house.fill"
        case .shelf: return "tray.full.fill"
        case .quiet: return "moon.fill"
        case .permissions: return "hand.raised.fill"
        case .about: return "info.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .general: return .gray
        case .activities: return .blue
        case .hud: return .pink
        case .agents: return .purple
        case .integrations: return Color(white: 0.28)
        case .home: return .orange
        case .shelf: return Color(red: 0.93, green: 0.66, blue: 0.05)
        case .quiet: return .indigo
        case .permissions: return .blue
        case .about: return .gray
        }
    }

    /// One line under the page title.
    var summary: String {
        switch self {
        case .general: return "Where the island appears, how it opens and whether Isle starts with your Mac."
        case .activities: return "What the closed notch shows while something is going on."
        case .hud: return "Volume and brightness changes, shown in the island instead of the middle of your screen."
        case .agents: return "Coding agents in the Agents tab: banners, approvals, replies and what each one shows."
        case .integrations: return "Exact, instant status from Claude Code and your terminal, and a way for any script to report itself."
        case .home: return "Weather, world clocks, your calendar, the timer and the camera mirror."
        case .shelf: return "Files you park on the notch, your clipboard history, a note and finished downloads."
        case .quiet: return "Hold back banners and sounds while you focus, and catch up when it ends."
        case .permissions: return "Every permission Isle uses, why, and everything it reads, writes or sends."
        case .about: return "Version, shell commands and links."
        }
    }
}

/// Shared between the settings window and whoever opens it (the island, the shell command):
/// the page on screen, the search text and a setting to scroll to and flash.
@Observable
final class SettingsNavigator {
    private(set) var page: SettingsPage = .general
    var search = ""
    /// Anchor of a setting to scroll to and highlight once its page is on screen.
    var highlight: String?
    private var backStack: [SettingsPage] = []
    private var forwardStack: [SettingsPage] = []

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    func show(_ page: SettingsPage, highlight: String? = nil) {
        if page != self.page {
            backStack.append(self.page)
            forwardStack.removeAll()
            self.page = page
        }
        self.highlight = highlight
    }

    func back() {
        guard let previous = backStack.popLast() else { return }
        forwardStack.append(page)
        page = previous
        highlight = nil
    }

    func forward() {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(page)
        page = next
        highlight = nil
    }
}

// MARK: - Search index

/// A searchable setting: its page, the anchor of its row and words people might type.
struct SettingsEntry: Identifiable, Hashable {
    let page: SettingsPage
    let anchor: String
    let title: String
    let keywords: String
    var id: String { "\(page.rawValue).\(anchor)" }

    func matches(_ terms: [String]) -> Bool {
        let haystack = "\(title) \(keywords) \(page.title)".lowercased()
        return terms.allSatisfy { haystack.contains($0) }
    }
}

enum SettingsIndex {
    static func search(_ text: String) -> [SettingsEntry] {
        let terms = text.lowercased().split(separator: " ").map(String.init)
        guard !terms.isEmpty else { return [] }
        return entries.filter { $0.matches(terms) }
    }

    private static func e(_ page: SettingsPage, _ anchor: String, _ title: String, _ keywords: String = "") -> SettingsEntry {
        SettingsEntry(page: page, anchor: anchor, title: title, keywords: keywords)
    }

    static let entries: [SettingsEntry] = [
        e(.general, "screen", "Show island on", "display monitor screen notch external"),
        e(.general, "pill", "Pill on displays without a notch", "external monitor display"),
        e(.general, "hover", "Hover delay", "open speed mouse pointer"),
        e(.general, "haptics", "Haptic feedback", "trackpad force touch vibration"),
        e(.general, "gestures", "Gestures", "swipe drag hover click"),
        e(.general, "login", "Launch at login", "startup start boot login items"),

        e(.activities, "music", "Now Playing", "spotify music song album artwork"),
        e(.activities, "agents", "Running agents", "claude codex live activity"),
        e(.activities, "battery", "Charging & low battery", "power battery plug"),
        e(.activities, "bluetooth", "Bluetooth devices", "airpods headphones keyboard mouse"),
        e(.activities, "meetings", "Meeting reminders", "calendar event call zoom meet"),
        e(.activities, "capture", "Microphone & camera in use", "mic recording privacy indicator dot"),

        e(.hud, "volume", "Show volume changes", "sound hud speaker"),
        e(.hud, "replace", "Replace the system HUD", "brightness media keys overlay accessibility"),

        e(.agents, "banners", "Banner when an agent finishes", "notification done needs you"),
        e(.agents, "sound", "Sound with banners", "audio chime"),
        e(.agents, "nudges", "Waiting reminders", "nudge waiting pulse away summary"),
        e(.agents, "approvals", "Approve tool calls", "permission allow deny claude code"),
        e(.agents, "replies", "Reply to questions", "answer iterm terminal paste accessibility"),
        e(.agents, "diffs", "Uncommitted changes", "git diff lines added removed"),
        e(.agents, "usage", "Context & token usage", "tokens cost context window meter"),
        e(.agents, "github", "Checks, pull requests & deploys", "github ci pr gh vercel netlify preview ship"),
        e(.agents, "background", "Background agents", "codex vscode idle"),
        e(.agents, "devservers", "Dev servers", "localhost ports server"),
        e(.agents, "devwarn", "Warn when a dev server stops", "crash server stopped"),

        e(.integrations, "claude", "Claude Code hooks", "install hooks settings.json instant status"),
        e(.integrations, "commands", "Banner when a long command finishes", "terminal zsh shell command"),
        e(.integrations, "zsh", "zsh hook", "zshrc shell install terminal"),
        e(.integrations, "custom", "Other agents & scripts", "curl api custom hook report"),

        e(.home, "weather", "Weather", "temperature city forecast open-meteo"),
        e(.home, "clocks", "World clocks", "time zone teammates"),
        e(.home, "calendar", "Calendar", "events meetings access"),
        e(.home, "timer", "Timer", "pomodoro countdown break"),
        e(.home, "mirror", "Camera mirror", "camera webcam video call"),

        e(.shelf, "items", "Shelf", "files clear airdrop"),
        e(.shelf, "clipboard", "Clipboard history", "copy paste"),
        e(.shelf, "note", "Note", "scratchpad text"),
        e(.shelf, "downloads", "Downloads", "download progress browser"),

        e(.quiet, "quiet", "Quiet mode", "focus do not disturb moon"),
        e(.quiet, "exceptions", "Still show approvals & meetings", "exceptions allow"),
        e(.quiet, "meetings", "Turn on during meetings", "calendar automatic"),
        e(.quiet, "shortcuts", "Run a Shortcut", "shortcuts focus automation"),

        e(.permissions, "accessibility", "Accessibility", "permission privacy trusted"),
        e(.permissions, "automation", "Automation", "apple events spotify music iterm terminal permission"),
        e(.permissions, "calendar", "Calendar access", "permission privacy"),
        e(.permissions, "bluetooth", "Bluetooth access", "permission privacy"),
        e(.permissions, "camera", "Camera access", "permission privacy webcam"),
        e(.permissions, "downloads", "Downloads folder access", "files folders permission privacy"),
        e(.permissions, "files", "Files Isle changes", "settings.json zshrc note"),
        e(.permissions, "network", "Network", "internet server port privacy data"),
        e(.permissions, "local", "Stays on this Mac", "privacy data clipboard transcripts"),

        e(.about, "version", "Version", "update about"),
        e(.about, "cli", "Shell commands", "isle cli raycast"),
        e(.about, "quit", "Quit Isle", "exit close"),
    ]
}

// MARK: - Building blocks

/// A rounded, filled square around an SF Symbol: the icon style of System Settings.
struct SettingsIcon: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 22

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
            .fill(color.gradient)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.52, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
            }
            .frame(width: size, height: size)
            .shadow(color: .black.opacity(0.15), radius: 0.6, y: 0.5)
    }
}

/// Isle's mark, drawn (the app ships without an icon file): the island floating at the top of
/// a deep blue tile.
struct IsleMark: View {
    var size: CGFloat = 38

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
            .fill(LinearGradient(colors: [Color(red: 0.26, green: 0.42, blue: 0.98), Color(red: 0.31, green: 0.16, blue: 0.72)],
                                 startPoint: .top, endPoint: .bottom))
            .overlay(alignment: .top) {
                Capsule()
                    .fill(.black)
                    .frame(width: size * 0.5, height: size * 0.17)
                    .overlay(alignment: .trailing) {
                        Circle().fill(Color.green).frame(width: size * 0.06).padding(.trailing, size * 0.05)
                    }
                    .padding(.top, size * 0.16)
            }
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                    .strokeBorder(.white.opacity(0.18), lineWidth: 0.5)
            }
            .frame(width: size, height: size)
            .shadow(color: .black.opacity(0.18), radius: size * 0.04, y: size * 0.02)
    }
}

/// Icon, title and an optional explanation under it: the label of most rows.
struct SettingLabel: View {
    let title: String
    var subtitle: String?
    var symbol: String?
    var color: Color = .gray

    var body: some View {
        HStack(spacing: 10) {
            if let symbol { SettingsIcon(symbol: symbol, color: color) }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let subtitle {
                    Text(.init(subtitle))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// A switch row with an icon and an explanation.
struct SettingToggle: View {
    let title: String
    var subtitle: String?
    var symbol: String?
    var color: Color = .gray
    @Binding var isOn: Bool

    init(_ title: String, subtitle: String? = nil, symbol: String? = nil, color: Color = .gray, isOn: Binding<Bool>) {
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.color = color
        _isOn = isOn
    }

    var body: some View {
        Toggle(isOn: $isOn) { SettingLabel(title: title, subtitle: subtitle, symbol: symbol, color: color) }
    }
}

/// A small coloured capsule: "Allowed", "Installed", "Off"…
struct StatusBadge: View {
    let text: String
    let color: Color
    var symbol: String?

    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).font(.system(size: 9, weight: .bold)) }
            Text(text).font(.caption.weight(.medium))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 7)
        .padding(.vertical, 2.5)
        .background(Capsule().fill(color.opacity(0.14)))
        .fixedSize()
    }
}

/// An inline note inside a section, with a symbol: hints, warnings, errors.
struct SettingNote: View {
    let text: String
    var symbol = "info.circle"
    var color: Color = .secondary

    init(_ text: String, symbol: String = "info.circle", color: Color = .secondary) {
        self.text = text
        self.symbol = symbol
        self.color = color
    }

    var body: some View {
        Label {
            Text(.init(text)).foregroundStyle(color == .secondary ? .secondary : .primary)
        } icon: {
            Image(systemName: symbol).foregroundStyle(color)
        }
        .font(.caption)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// The centred icon, title and summary card at the top of every page.
struct SettingsPageHeader: View {
    let page: SettingsPage
    var accessory: AnyView?

    var body: some View {
        VStack(spacing: 7) {
            SettingsIcon(symbol: page.symbol, color: page.color, size: 54)
                .padding(.bottom, 3)
            Text(page.title).font(.title2.weight(.semibold))
            Text(page.summary)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
                .fixedSize(horizontal: false, vertical: true)
            if let accessory { accessory.padding(.top, 4) }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
    }
}

/// A page: the header card, then grouped sections. Scrolls to and flashes the searched-for
/// setting (rows mark themselves with `.settingAnchor`).
struct SettingsPageForm<Content: View>: View {
    let page: SettingsPage
    var accessory: AnyView?
    @ViewBuilder var content: Content
    @Environment(SettingsNavigator.self) private var nav

    var body: some View {
        ScrollViewReader { proxy in
            Form {
                Section { SettingsPageHeader(page: page, accessory: accessory) }
                content
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .onAppear { reveal(proxy) }
            .onChange(of: nav.highlight) { reveal(proxy) }
        }
    }

    private func reveal(_ proxy: ScrollViewProxy) {
        guard let id = nav.highlight else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            withAnimation(.easeInOut(duration: 0.35)) { proxy.scrollTo(id, anchor: .center) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
            if nav.highlight == id { withAnimation(.easeOut(duration: 0.5)) { nav.highlight = nil } }
        }
    }
}

private struct SettingAnchor: ViewModifier {
    let id: String
    @Environment(SettingsNavigator.self) private var nav

    func body(content: Content) -> some View {
        content
            .id(id)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.accentColor.opacity(nav.highlight == id ? 0.2 : 0))
                    .padding(.horizontal, -6)
                    .padding(.vertical, -4)
            }
    }
}

extension View {
    /// Marks a row as the target of a search result, so the page can scroll to it.
    func settingAnchor(_ id: String) -> some View { modifier(SettingAnchor(id: id)) }
}

/// A row that takes you to another page (and setting), like "Hooks & Scripts ›".
struct SettingsLink: View {
    let title: String
    let page: SettingsPage
    var anchor: String?
    @Environment(SettingsNavigator.self) private var nav

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { nav.show(page, highlight: anchor) }
        } label: {
            HStack(spacing: 3) {
                Text(title)
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
            }
        }
        .buttonStyle(.link)
    }
}

enum SystemSettingsPane: String {
    case accessibility = "Privacy_Accessibility"
    case automation = "Privacy_Automation"
    case calendars = "Privacy_Calendars"
    case bluetooth = "Privacy_Bluetooth"
    case camera = "Privacy_Camera"
    case files = "Privacy_FilesAndFolders"
    case loginItems = "LoginItems"

    func open() {
        let url = self == .loginItems
            ? "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"
            : "x-apple.systempreferences:com.apple.preference.security?\(rawValue)"
        if let url = URL(string: url) { NSWorkspace.shared.open(url) }
    }
}

/// Reveals a file (or its folder, if the file isn't there yet) in Finder.
func revealInFinder(_ url: URL) {
    if FileManager.default.fileExists(atPath: url.path) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    } else {
        NSWorkspace.shared.open(url.deletingLastPathComponent())
    }
}

extension URL {
    /// The path with the home folder written as `~`.
    var tildePath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}
