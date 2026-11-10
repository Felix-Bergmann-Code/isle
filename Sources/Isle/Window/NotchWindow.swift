import AppKit
import SwiftUI

/// Borderless, transparent, non-activating panel that sits above the menu bar.
final class NotchPanel: NSPanel {
    init(frame: NSRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isMovable = false
        hidesOnDeactivate = false
        ignoresMouseEvents = true
        acceptsMouseMovedEvents = true
        isReleasedWhenClosed = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
    var isBuiltIn: Bool { CGDisplayIsBuiltin(displayID) != 0 }
    var hasNotch: Bool { safeAreaInsets.top > 0 }

    var notchGeometry: NotchGeometry {
        var g = NotchGeometry()
        g.screenFrame = frame
        if hasNotch, let l = auxiliaryTopLeftArea, let r = auxiliaryTopRightArea {
            g.hasNotch = true
            g.notchWidth = frame.width - l.width - r.width
            g.notchHeight = safeAreaInsets.top
        } else {
            let menuBar = frame.maxY - visibleFrame.maxY
            g.hasNotch = false
            g.notchWidth = 196
            g.notchHeight = menuBar > 12 ? menuBar : 25
        }
        return g
    }
}

/// Positions the panel, tracks the pointer (hover / file drags / swipes) and
/// toggles click-through so the island never blocks the menu bar.
final class NotchWindowManager {
    private let env: AppEnvironment
    private var panel: NotchPanel?
    private var monitors: [Any] = []
    private var openWork: DispatchWorkItem?
    private var closeWork: DispatchWorkItem?
    private var dragChangeCount = NSPasteboard(name: .drag).changeCount
    private var isDraggingFile = false
    private var scrollAccum: CGFloat = 0
    private var scrollConsumed = false
    private var screenObserver: Any?

    private let windowSize = CGSize(width: 820, height: 320)

    init(env: AppEnvironment) { self.env = env }

    func start() {
        let panel = NotchPanel(frame: NSRect(origin: .zero, size: windowSize))
        let host = FirstMouseHostingView(rootView: IslandRootView(env: env))
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: windowSize)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        self.panel = panel
        reposition()
        panel.orderFrontRegardless()

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self?.reposition() }
        }
        env.settings.onScreenChange = { [weak self] in self?.reposition() }
        installMonitors()

        // Scriptable control, e.g. from a shell alias or Raycast:
        //   "open", "open:agents", "toggle", "close"
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("io.github.felix-bergmann-code.isle.command"), object: nil, queue: .main
        ) { [weak self] n in
            self?.perform(command: (n.object as? String) ?? "toggle")
        }
    }

    func perform(command: String) {
        let parts = command.split(separator: ":").map(String.init)
        let tab = parts.count > 1 ? IslandTab(rawValue: parts[1]) : nil
        switch parts.first {
        case "snapshot":
            // Debug: write the island's current rendering to a PNG (snapshot:/path/file.png)
            guard parts.count > 1, let view = panel?.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: parts[1]))
        case "dump":
            // Debug: write detected agents as text (dump:/path/file.txt)
            guard parts.count > 1 else { return }
            let lines = env.agents.sessions.map {
                "\($0.pid)\t\($0.kind.rawValue)\t\($0.phase.rawValue)\t\($0.source)\t\($0.project)\t\($0.title ?? "-")\t\($0.detail)"
            }
            try? lines.joined(separator: "\n").write(toFile: parts[1], atomically: true, encoding: .utf8)
        case "close": env.vm.close(); panel?.ignoresMouseEvents = true
        case "toggle" where env.vm.isOpen: env.vm.close(); panel?.ignoresMouseEvents = true
        default:
            panel?.ignoresMouseEvents = false
            env.vm.open(tab: tab)
        }
    }

    private func targetScreen() -> NSScreen? {
        let screens = NSScreen.screens
        switch env.settings.screenMode {
        case .automatic: return screens.first(where: { $0.hasNotch }) ?? screens.first
        case .builtIn: return screens.first(where: { $0.isBuiltIn }) ?? screens.first
        case .primary: return screens.first
        }
    }

    func reposition() {
        guard let panel, let screen = targetScreen() else { return }
        env.vm.geometry = screen.notchGeometry
        let f = screen.frame
        panel.setFrame(NSRect(x: f.midX - windowSize.width / 2, y: f.maxY - windowSize.height,
                              width: windowSize.width, height: windowSize.height), display: true)
        panel.orderFrontRegardless()
    }

    // MARK: Pointer tracking

    private func installMonitors() {
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .leftMouseDown, .leftMouseUp]
        if let g = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] e in self?.handle(e) }) {
            monitors.append(g)
        }
        if let l = NSEvent.addLocalMonitorForEvents(matching: mask.union(.scrollWheel), handler: { [weak self] e in
            if e.type == .scrollWheel { self?.handleScroll(e) } else { self?.handle(e) }
            return e
        }) {
            monitors.append(l)
        }
    }

    private func handle(_ e: NSEvent) {
        switch e.type {
        case .leftMouseDown:
            dragChangeCount = NSPasteboard(name: .drag).changeCount
            isDraggingFile = false
            // Clicking the closed island opens it immediately.
            if !env.vm.isOpen, hotRect().contains(NSEvent.mouseLocation) { openNow() }
        case .leftMouseDragged:
            if !isDraggingFile, NSPasteboard(name: .drag).changeCount != dragChangeCount {
                isDraggingFile = true
            }
        case .leftMouseUp:
            isDraggingFile = false
        default: break
        }
        updateHover(NSEvent.mouseLocation)
    }

    private func hotRect() -> CGRect {
        let layout = env.currentLayout()
        let g = env.vm.geometry
        let f = g.screenFrame
        var w = layout.width
        var h = layout.height
        if layout.mode != .open {
            w = max(w, g.notchWidth + 24)
            h = max(h, g.notchHeight)
        }
        var r = CGRect(x: f.midX - w / 2, y: f.maxY - h, width: w, height: h)
        r = layout.mode == .open ? r.insetBy(dx: -10, dy: -12) : r.insetBy(dx: -4, dy: -3)
        r.size.height += 20 // include the very top edge of the screen
        return r
    }

    private func dragRect() -> CGRect {
        hotRect().insetBy(dx: -70, dy: -50)
    }

    private func updateHover(_ p: CGPoint) {
        guard let panel else { return }
        let vm = env.vm
        let inside = isDraggingFile ? dragRect().contains(p) || hotRect().contains(p) : hotRect().contains(p)

        if inside {
            closeWork?.cancel(); closeWork = nil
            if panel.ignoresMouseEvents { panel.ignoresMouseEvents = false }
            if !vm.isHovering, !vm.isOpen { withAnimation(Anim.micro) { vm.isHovering = true } }
            if !vm.isOpen, openWork == nil {
                let delay = isDraggingFile ? 0 : env.settings.hoverDelay
                let work = DispatchWorkItem { [weak self] in
                    self?.openWork = nil
                    self?.openNow()
                }
                openWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
            }
        } else {
            openWork?.cancel(); openWork = nil
            if vm.isHovering, !vm.isOpen { withAnimation(Anim.micro) { vm.isHovering = false } }
            if vm.isOpen, closeWork == nil {
                let work = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.closeWork = nil
                    self.env.vm.close()
                    self.panel?.ignoresMouseEvents = true
                }
                closeWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: work)
            } else if !vm.isOpen, !panel.ignoresMouseEvents {
                panel.ignoresMouseEvents = true
            }
        }
    }

    private func openNow() {
        openWork?.cancel(); openWork = nil
        guard !env.vm.isOpen else { return }
        panel?.ignoresMouseEvents = false
        env.vm.open(tab: isDraggingFile ? .shelf : nil)
        if env.settings.haptics {
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        }
    }

    // MARK: Swipes

    private func handleScroll(_ e: NSEvent) {
        guard env.vm.isOpen, e.momentumPhase.isEmpty else { return }
        if e.phase.contains(.began) { scrollAccum = 0; scrollConsumed = false }
        if e.phase.contains(.ended) || e.phase.contains(.cancelled) { scrollAccum = 0; scrollConsumed = false; return }
        guard !scrollConsumed, abs(e.scrollingDeltaX) > abs(e.scrollingDeltaY) * 1.3 else { return }
        scrollAccum += e.scrollingDeltaX
        if abs(scrollAccum) > 46 {
            env.vm.cycleTab(scrollAccum < 0 ? 1 : -1)
            scrollConsumed = true
            if env.settings.haptics {
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            }
        }
    }
}
