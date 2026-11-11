import AppKit
import Combine
import SwiftUI

/// The settings window: a System Settings–style sidebar (search, then one page per area) and
/// the selected page beside it.
struct SettingsView: View {
    let env: AppEnvironment
    @Bindable var nav: SettingsNavigator
    private let poll = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    static let windowID = NSUserInterfaceItemIdentifier("isle.settings")

    var body: some View {
        NavigationSplitView {
            SettingsSidebar(env: env)
                .navigationSplitViewColumnWidth(min: 240, ideal: 250, max: 300)
        } detail: {
            page
                .id(nav.page)
                .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .windowBackgroundColor))
        }
        .toolbar(removing: .sidebarToggle)
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                ControlGroup {
                    Button { nav.back() } label: { Image(systemName: "chevron.left") }
                        .disabled(!nav.canGoBack)
                        .help("Back")
                    Button { nav.forward() } label: { Image(systemName: "chevron.right") }
                        .disabled(!nav.canGoForward)
                        .help("Forward")
                }
                .controlGroupStyle(.navigation)
            }
        }
        .navigationTitle(nav.page.title)
        .environment(nav)
        .frame(minWidth: 780, minHeight: 540)
        .onAppear { PermissionCenter.shared.refresh(env: env) }
        .onReceive(poll) { _ in
            // The view outlives a closed window; only re-check while it can be seen.
            guard NSApp.windows.contains(where: { $0.identifier == Self.windowID && $0.isVisible && $0.occlusionState.contains(.visible) })
            else { return }
            PermissionCenter.shared.refresh(env: env)
        }
    }

    @ViewBuilder
    private var page: some View {
        switch nav.page {
        case .general: GeneralPage(env: env)
        case .activities: ActivitiesPage(env: env)
        case .hud: HUDPage(env: env)
        case .agents: AgentsPage(env: env)
        case .integrations: IntegrationsPage(env: env)
        case .home: HomePage(env: env)
        case .shelf: ShelfPage(env: env)
        case .quiet: QuietPage(env: env)
        case .permissions: PermissionsPage(env: env)
        case .about: AboutPage(env: env)
        }
    }
}

// MARK: - Sidebar

private struct SettingsSidebar: View {
    let env: AppEnvironment
    @Environment(SettingsNavigator.self) private var nav
    @FocusState private var searchFocused: Bool

    var body: some View {
        @Bindable var nav = nav
        VStack(spacing: 0) {
            SearchField(text: $nav.search, focused: $searchFocused)
                .padding(.horizontal, 10)
                .padding(.bottom, 6)

            if nav.search.trimmingCharacters(in: .whitespaces).isEmpty {
                pageList
            } else {
                SearchResults(query: nav.search)
            }
        }
        .background {
            // ⌘F focuses the search field, Esc clears it.
            Button("") { searchFocused = true }.keyboardShortcut("f").hidden()
        }
        .onAppear {
            // AppKit focuses the first text field of a new window; start on the page list instead.
            DispatchQueue.main.async { searchFocused = false }
        }
    }

    private var selection: Binding<SettingsPage?> {
        Binding(get: { nav.page }, set: { if let p = $0 { nav.show(p) } })
    }

    private var pageList: some View {
        List(selection: selection) {
            Section {
                IdentityRow().tag(SettingsPage.about)
            }
            ForEach(Array(SettingsPage.groups.enumerated()), id: \.offset) { _, group in
                Section {
                    ForEach(group) { page in
                        SidebarRow(page: page, env: env).tag(page)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }
}

private struct SidebarRow: View {
    let page: SettingsPage
    let env: AppEnvironment

    var body: some View {
        HStack(spacing: 8) {
            Label {
                Text(page.title)
            } icon: {
                SettingsIcon(symbol: page.symbol, color: page.color, size: 20)
            }
            Spacer(minLength: 4)
            trailing
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch page {
        case .permissions:
            let count = PermissionCenter.shared.attentionCount(AppSettings.shared)
            if count > 0 {
                Text("\(count)")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(minWidth: 18, minHeight: 18)
                    .background(Circle().fill(.orange))
                    .help("\(count) need your attention")
            }
        case .integrations:
            if !PermissionCenter.shared.claudeHooks {
                Circle().fill(.orange).frame(width: 7, height: 7)
                    .help("Claude Code hooks aren't installed")
            }
        case .agents:
            let n = env.agents.visibleSessions.count
            if n > 0 {
                Text("\(n)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        default:
            EmptyView()
        }
    }
}

/// The card at the top of the sidebar, like the account card in System Settings.
private struct IdentityRow: View {
    var body: some View {
        HStack(spacing: 10) {
            IsleMark(size: 36)
            VStack(alignment: .leading, spacing: 1) {
                Text("Isle").font(.headline)
                Text("Version \(AboutPage.version)").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct SearchField: View {
    @Binding var text: String
    var focused: FocusState<Bool>.Binding

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("Search", text: $text)
                .textFieldStyle(.plain)
                .focused(focused)
                .onExitCommand { text = "" }
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.07)))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(focused.wrappedValue ? 0.6 : 0), lineWidth: 1.5)
        )
    }
}

private struct SearchResults: View {
    let query: String
    @Environment(SettingsNavigator.self) private var nav
    @State private var selected: SettingsEntry.ID?

    var body: some View {
        let results = SettingsIndex.search(query)
        if results.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 22)).foregroundStyle(.tertiary)
                Text("No Results for “\(query)”").font(.callout.weight(.medium)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(SettingsPage.allCases) { page in
                    let hits = results.filter { $0.page == page }
                    if !hits.isEmpty {
                        Section(page.title) {
                            ForEach(hits) { entry in
                                Button {
                                    selected = entry.id
                                    withAnimation(.easeInOut(duration: 0.2)) { nav.show(entry.page, highlight: entry.anchor) }
                                } label: {
                                    Label {
                                        Text(entry.title).foregroundStyle(selected == entry.id ? Color.white : Color.primary)
                                    } icon: {
                                        SettingsIcon(symbol: page.symbol, color: page.color, size: 18)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .listRowBackground(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(Color.accentColor.opacity(selected == entry.id ? 0.85 : 0))
                                        .padding(.horizontal, 10)
                                )
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
        }
    }
}
