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

    /// The panel only takes the keyboard while an open island shows a text field
    /// (see `IslandViewModel.wantsKeyboard`); otherwise clicks never steal focus.
    var keyPolicy: () -> Bool = { false }
    override var canBecomeKey: Bool { keyPolicy() }
    override var canBecomeMain: Bool { false }

    /// Become key before the click is dispatched, so the click that takes the keyboard also
    /// lands in the text field (a text view ignores the click that only makes its window key).
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, !isKeyWindow, canBecomeKey { makeKey() }
        super.sendEvent(event)
    }

    /// Isle has no main menu, so nothing maps the standard edit shortcuts to text fields.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let action: Selector?
        switch (flags, event.charactersIgnoringModifiers?.lowercased()) {
        case (.command, "x"): action = #selector(NSText.cut(_:))
        case (.command, "c"): action = #selector(NSText.copy(_:))
        case (.command, "v"): action = #selector(NSText.paste(_:))
        case (.command, "a"): action = #selector(NSResponder.selectAll(_:))
        case (.command, "z"): action = Selector(("undo:"))
        case ([.command, .shift], "z"): action = Selector(("redo:"))
        default: action = nil
        }
        if let action, NSApp.sendAction(action, to: nil, from: self) { return true }
        return super.performKeyEquivalent(with: event)
    }
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
    private var pinnedOpen = false
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
        panel.keyPolicy = { [weak env] in (env?.vm.isOpen ?? false) && (env?.vm.wantsKeyboard ?? false) }
        env.closeIsland = { [weak self] in self?.closeIsland() }
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
        //   "open", "open:agents", "toggle", "close", "timer:25", "timer:stop",
        //   "mirror", "quiet", "quiet:on", "quiet:off", "settings", "settings:permissions"
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(IsleInstance.commandName), object: nil, queue: .main
        ) { [weak self] n in
            self?.perform(command: (n.object as? String) ?? "toggle")
        }
    }

    func perform(command: String) {
        if IsleInstance.isDev, drive(command) { return }
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
                    + $0.subagents.map { "\n\t↳ \($0.type)\t\($0.label ?? "-")\t\($0.isRunning ? "running" : "finished")\($0.isBackground ? " bg" : "")\t\($0.detail)" }.joined()
            }
            try? lines.joined(separator: "\n").write(toFile: parts[1], atomically: true, encoding: .utf8)
        case "demo" where Demo.isEnabled && parts.count > 1:
            pinnedOpen = false
            env.vm.close()
            Demo.perform(parts[1], env: env)
        case "timer" where parts.count > 1 && parts[1] == "stop": env.timer.cancel()
        case "timer": if parts.count > 1, let m = Int(parts[1]), (1...1440).contains(m) { env.timer.start(minutes: m) }
        case "quiet": env.quiet.perform(parts.count > 1 ? parts[1] : "toggle")
        case "note":
            // Shelf in Note mode with the editor focused, ready to type.
            let note = env.settings.scratchpadNote
            if note { UserDefaults.standard.set(ShelfMode.note.rawValue, forKey: ShelfMode.storageKey) }
            panel?.ignoresMouseEvents = false
            env.vm.open(tab: .shelf)
            guard note else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.panel?.makeKey()
                NoteStore.shared.focusRequested = true
            }
        case "close": pinnedOpen = false; closeIsland()
        case "settings":
            let page = parts.count > 1 ? SettingsPage(rawValue: parts[1]) : nil
            if let page { env.showSettings(page) } else { env.openSettings() }
        case "mirror":
            panel?.ignoresMouseEvents = false
            env.vm.open(tab: .home)
            env.mirror.show()
        case "toggle" where env.vm.isOpen: pinnedOpen = false; closeIsland()
        default:
            // In demo mode a scripted open stays open (for screenshots) until a close command.
            pinnedOpen = Demo.isEnabled
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
        // Esc leaves the text field (a text view would only offer completions); the island then
        // closes as usual once the pointer is away. Input methods keep Esc while composing.
        if let k = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] e in
            guard e.keyCode == 53, let self, self.env.vm.isEditingText, let panel = self.panel, panel.isKeyWindow,
                  (panel.firstResponder as? NSTextView)?.hasMarkedText() != true else { return e }
            panel.makeFirstResponder(nil)
            self.env.vm.isEditingText = false
            self.updateHover(NSEvent.mouseLocation)
            return nil
        }) {
            monitors.append(k)
        }
    }

    private func handle(_ e: NSEvent) {
        switch e.type {
        case .leftMouseDown:
            dragChangeCount = NSPasteboard(name: .drag).changeCount
            isDraggingFile = false
            // Clicking the closed island opens it immediately.
            if !env.vm.isOpen, hotRect().contains(NSEvent.mouseLocation) { openNow() }
            // While typing, the island stays open until you click somewhere else.
            else if env.vm.isOpen, env.vm.isEditingText, !hotRect().contains(NSEvent.mouseLocation) { closeIsland() }
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
            if vm.isOpen, !vm.isEditingText, closeWork == nil, !pinnedOpen {
                let work = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.closeWork = nil
                    self.closeIsland()
                }
                closeWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: work)
            } else if !vm.isOpen, !panel.ignoresMouseEvents {
                panel.ignoresMouseEvents = true
            }
        }
    }

    /// Close and give the keyboard back to whatever app had it before a text field took it.
    func closeIsland() {
        env.vm.isEditingText = false
        env.vm.close()
        panel?.ignoresMouseEvents = true
        guard let panel, panel.isKeyWindow else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            guard let self, let panel = self.panel, !self.env.vm.isOpen, panel.isKeyWindow else { return }
            // Re-ordering a key panel makes the window server hand key back to the active app.
            panel.orderOut(nil)
            panel.orderFrontRegardless()
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

// MARK: - Dev test driver

extension NotchWindowManager {
    /// Dev builds only (`ISLE_INSTANCE`): synthesize input inside the app so a script can test
    /// the UI without Accessibility access. The events go through `NSWindow.sendEvent`, so
    /// hit-testing, buttons, gestures and text fields behave as for real input.
    ///   click:<x>:<y>   screen point, top-left origin (like screencapture -R)
    ///   move:<x>:<y>    pointer moved there (hover)
    ///   type:<text>     typed into whatever has keyboard focus
    ///   key:<esc|return|tab|delete>
    func drive(_ command: String) -> Bool {
        guard let panel else { return false }
        let parts = command.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        switch parts.first {
        case "click" where parts.count == 3, "move" where parts.count == 3:
            guard let x = Double(parts[1]), let y = Double(parts[2]),
                  let top = NSScreen.screens.first?.frame.maxY else { return true }
            let screenPoint = NSPoint(x: x, y: top - y)
            // The frontmost of Isle's windows under the point (the island, or Settings).
            let window = NSApp.orderedWindows.first { $0.isVisible && $0.frame.contains(screenPoint) && $0 !== panel } ?? panel
            let p = window.convertPoint(fromScreen: screenPoint)
            let types: [NSEvent.EventType] = parts[0] == "move" ? [.mouseMoved] : [.mouseMoved, .leftMouseDown, .leftMouseUp]
            for type in types {
                if let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                              pressure: type == .leftMouseDown ? 1 : 0) {
                    window.sendEvent(e)
                }
            }
            DevLog.write("drive: \(parts[0]) \(Int(x)),\(Int(y))")
        case "scroll" where parts.count == 3:
            // scroll:x,y:dy scrolls whatever scroll view of Isle's is at that point (e.g. a Settings page).
            let xy = parts[1].split(separator: ",").compactMap { Double($0) }
            guard xy.count == 2, let dy = Double(parts[2]), let top = NSScreen.screens.first?.frame.maxY else { return true }
            let screenPoint = NSPoint(x: xy[0], y: top - xy[1])
            let window = NSApp.orderedWindows.first { $0.isVisible && $0.frame.contains(screenPoint) && $0 !== panel } ?? panel
            guard let content = window.contentView else { return true }
            var view = content.hitTest(content.convert(window.convertPoint(fromScreen: screenPoint), from: nil))
            while let v = view, !(v is NSScrollView) { view = v.superview }
            if let scroll = view as? NSScrollView, let doc = scroll.documentView {
                let clip = scroll.contentView
                var origin = clip.bounds.origin
                origin.y = min(max(0, origin.y + (doc.isFlipped ? -dy : dy)), max(0, doc.frame.height - clip.bounds.height))
                clip.scroll(to: origin)
                scroll.reflectScrolledClipView(clip)
            }
            DevLog.write("drive: scroll \(Int(dy))")
        case "type" where parts.count >= 2:
            let text = parts.dropFirst().joined(separator: ":")
            for ch in text { key(String(ch), code: 0) }
            DevLog.write("drive: typed \(text.count) chars")
        case "key" where parts.count == 2:
            let codes: [String: (String, UInt16)] = ["esc": ("\u{1b}", 53), "return": ("\r", 36), "tab": ("\t", 48), "delete": ("\u{7f}", 51)]
            guard let (chars, code) = codes[parts[1]] else { return true }
            key(chars, code: code)
            DevLog.write("drive: key \(parts[1])")
        default:
            return false
        }
        return true
    }

    private func key(_ chars: String, code: UInt16) {
        guard let panel = NSApp.keyWindow ?? panel else { return }
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            if let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: panel.windowNumber, context: nil, characters: chars,
                                        charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) {
                // Through NSApp so local key monitors (Esc handling) see it, like real keys.
                NSApp.sendEvent(e)
            }
        }
    }
}
