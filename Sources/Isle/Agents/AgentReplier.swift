import AppKit
import ApplicationServices
import Darwin

/// Sends a one-line answer to a Claude Code session that ended its turn on a question.
///
/// Delivery, most to least direct:
///  1. iTerm2: AppleScript `write text` into the session whose tty matches the agent's,
///     without bringing iTerm2 forward.
///  2. Terminal.app: select the tab with that tty, then paste (Terminal has no reliable write).
///  3. Everything else, including Claude desktop chats (deep-linked by `AgentMonitor.focus`):
///     focus the chat, paste with ⌘V and press Return. That needs Accessibility; without it the
///     reply is left on the clipboard and a banner says so.
enum AgentReplier {
    private static let iTermID = "com.googlecode.iterm2"
    private static let terminalID = "com.apple.Terminal"
    /// Clipboard managers skip items marked transient (nspasteboard.org), so a reply that's only
    /// on the pasteboard for a moment doesn't end up in someone's history.
    private static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    private static let scriptQueue = DispatchQueue(label: "isle.reply", qos: .userInitiated)

    /// Waiting states that aren't free-text questions: the app's own pickers and plan review.
    private static let notQuestions: Set<String> = ["Has a question for you", "Plan ready for review"]

    /// The question to answer from the island, or nil when the session isn't waiting on one.
    /// Only transcript-derived questions qualify: a hook-reported "waiting" is a permission or
    /// notification, and tool calls already have their own card.
    static func question(for s: AgentSession, monitor: AgentMonitor) -> String? {
        guard AppSettings.shared.agentReplies, s.kind == .claude, s.phase == .waiting, s.source == "transcript",
              s.hostPID != nil || s.sessionID != nil, monitor.prompts(for: s).isEmpty else { return nil }
        let q = (s.lastMessage ?? s.detail).trimmingCharacters(in: .whitespacesAndNewlines)
        return q.isEmpty || notQuestions.contains(q) ? nil : q
    }

    private static let yesNoOpeners: Set<String> = [
        "should", "shall", "do", "does", "did", "is", "are", "was", "can", "could", "would", "will",
        "want", "may", "have", "has", "ok", "okay", "ready", "proceed",
    ]

    /// "Want me to push it?" gets Yes / No buttons; "Which fix first?" or "A or B?" don't.
    static func isYesNo(_ q: String) -> Bool {
        // An explicit hint settles it: "Should I create it? (yes/no)", "Continue? [y/N]".
        if q.range(of: #"\?\s*[\(\[]\s*(yes\s*/\s*no|y\s*/\s*n)\s*[\)\]]$"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return true
        }
        guard q.count <= 120, q.hasSuffix("?") else { return false }
        let sentence = q.components(separatedBy: CharacterSet(charactersIn: ".!:\n")).last ?? q
        let lower = sentence.lowercased().trimmingCharacters(in: .whitespaces)
        guard !lower.contains(" or "), let first = lower.split(separator: " ").first else { return false }
        return yesNoOpeners.contains(String(first))
    }

    // MARK: Sending

    static func send(_ raw: String, to s: AgentSession, env: AppEnvironment) {
        // The field is one line; a pasted newline would submit early in a terminal.
        let text = raw.replacingOccurrences(of: "\\s*\\n\\s*", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        env.closeIsland()

        let host = s.hostPID.flatMap { NSRunningApplication(processIdentifier: $0) }
        if let host, host.bundleIdentifier != ClaudeDesktop.bundleID, let tty = ProcInfo.ttyPath(s.pid) {
            switch host.bundleIdentifier {
            case iTermID:
                runScript(iTermWrite, args: [tty, text]) { out in
                    if out != "ok" { paste(text, into: s, env: env, submit: false) }
                }
                return
            case terminalID:
                // Only press Return when the agent's own tab is known to be in front.
                runScript(terminalSelect, args: [tty]) { out in paste(text, into: s, env: env, submit: out == "ok") }
                return
            default: break
            }
        }
        let desktop = host == nil || host?.bundleIdentifier == ClaudeDesktop.bundleID
        paste(text, into: s, env: env, submit: desktop)
    }

    /// `submit` presses Return after pasting. Only when the paste is known to land in the agent's
    /// own chat or tab: in a terminal Isle can't target (Ghostty, Warp, editor terminals) the
    /// front tab might be a shell, where Return would run the reply as a command.
    private static func paste(_ text: String, into s: AgentSession, env: AppEnvironment, submit: Bool) {
        let host = s.hostPID.flatMap { NSRunningApplication(processIdentifier: $0) }
        let desktop = host == nil || host?.bundleIdentifier == ClaudeDesktop.bundleID
        // Without a chat to deep-link to, activating Claude would paste into whatever chat is open.
        let reachable = desktop ? s.sessionID.flatMap(ClaudeDesktop.chatURL(forCLISession:)) != nil : true
        let pb = NSPasteboard.general

        guard AXIsProcessTrusted(), reachable else {
            pb.clearContents()
            pb.setString(text, forType: .string)
            env.agents.focus(s)
            copied(env, subtitle: reachable ? "Paste it with ⌘V · allow Accessibility in Settings to send directly"
                                            : "Paste it with ⌘V")
            return
        }

        let saved = snapshot(pb)
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setData(Data(), forType: transientType)
        pb.writeObjects([item])
        let ours = pb.changeCount
        env.agents.focus(s)

        // Type only once the chat's app is in front and the island has given the keyboard back.
        let isTarget: () -> Bool = {
            guard NSApp.keyWindow == nil, let front = NSWorkspace.shared.frontmostApplication else { return false }
            return desktop ? front.bundleIdentifier == ClaudeDesktop.bundleID : front.processIdentifier == s.hostPID
        }
        wait(until: isTarget, minimum: 0.35, timeout: desktop ? 4 : 2) { ready in
            guard ready else {
                // Leave the reply on the clipboard so nothing typed is lost.
                copied(env, subtitle: "Paste it with ⌘V")
                return
            }
            postKey(9, flags: .maskCommand) // V
            if submit {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { postKey(36) } // Return
            } else {
                env.vm.notify(Notice(icon: "return", tint: .white, title: "Reply pasted",
                                     subtitle: "Check it's the right tab, then press Return"))
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.62) {
                if pb.changeCount == ours { restore(saved, to: pb) }
            }
        }
    }

    private static func copied(_ env: AppEnvironment, subtitle: String) {
        env.vm.notify(Notice(icon: "doc.on.clipboard", tint: .white, title: "Reply copied", subtitle: subtitle))
    }

    // MARK: Helpers

    /// Polls `condition` on the main queue every 50 ms; calls back once it holds (but not
    /// before `minimum`), or with false after `timeout`.
    private static func wait(until condition: @escaping () -> Bool, minimum: TimeInterval, timeout: TimeInterval,
                             start: Date = Date(), then done: @escaping (Bool) -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            let elapsed = Date().timeIntervalSince(start)
            if elapsed >= minimum, condition() { return done(true) }
            if elapsed >= timeout { return done(false) }
            wait(until: condition, minimum: minimum, timeout: timeout, start: start, then: done)
        }
    }

    private static func postKey(_ code: CGKeyCode, flags: CGEventFlags = []) {
        let src = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down) else { continue }
            e.flags = flags
            e.post(tap: .cghidEventTap)
        }
    }

    private static func snapshot(_ pb: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (pb.pasteboardItems ?? []).map { item in
            var types: [NSPasteboard.PasteboardType: Data] = [:]
            for t in item.types { if let d = item.data(forType: t) { types[t] = d } }
            return types
        }
    }

    private static func restore(_ saved: [[NSPasteboard.PasteboardType: Data]], to pb: NSPasteboard) {
        pb.clearContents()
        guard !saved.isEmpty else { return }
        pb.writeObjects(saved.map { types in
            let item = NSPasteboardItem()
            for (t, d) in types { item.setData(d, forType: t) }
            return item
        })
    }

    /// Runs an AppleScript via osascript off the main thread (killed after `timeout`; the first
    /// run may wait on the Automation consent prompt). Calls back on main with its output, or nil.
    private static func runScript(_ source: String, args: [String], timeout: TimeInterval = 10,
                                  completion: @escaping (String?) -> Void) {
        scriptQueue.async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", source] + args
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            do { try p.run() } catch { DispatchQueue.main.async { completion(nil) }; return }
            let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
            p.waitUntilExit()
            killer.cancel()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            let result = p.terminationStatus == 0
                ? String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) : nil
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Types the reply into the iTerm2 session on the agent's tty, then a carriage return
    /// (a separate write, so the TUI reads it as Enter rather than part of the text).
    private static let iTermWrite = """
    on run argv
        set theTTY to item 1 of argv
        set theText to item 2 of argv
        tell application id "com.googlecode.iterm2"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if tty of s is theTTY then
                            tell s
                                write text theText newline false
                                delay 0.15
                                write text (character id 13) newline false
                            end tell
                            return "ok"
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        return "missing"
    end run
    """

    /// Brings the Terminal.app tab on the agent's tty to the front so the paste lands there.
    private static let terminalSelect = """
    on run argv
        set theTTY to item 1 of argv
        tell application id "com.apple.Terminal"
            repeat with w in windows
                repeat with t in tabs of w
                    if tty of t is theTTY then
                        set selected tab of w to t
                        set index of w to 1
                        return "ok"
                    end if
                end repeat
            end repeat
        end tell
        return "missing"
    end run
    """
}

extension ProcInfo {
    /// The process's controlling terminal, e.g. "/dev/ttys003" (what iTerm2 and Terminal report).
    static func ttyPath(_ pid: pid_t) -> String? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard pid > 0, proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
              info.e_tdev != 0, info.e_tdev != UInt32.max, // NODEV
              let name = devname(dev_t(bitPattern: info.e_tdev), S_IFCHR) else { return nil }
        let tty = String(cString: name)
        return tty.hasPrefix("tty") ? "/dev/" + tty : nil
    }
}
