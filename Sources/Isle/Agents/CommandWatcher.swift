import AppKit
import SwiftUI

/// Turns "a terminal command finished" reports from the zsh hook (POST /hook/command) into a
/// banner, so you can start `swift build`, look away, and hear back from the notch.
/// The shell reports anything that ran 10 s or longer; Isle applies the person's threshold,
/// so changing it never needs a shell restart.
final class CommandWatcher {
    private let vm: IslandViewModel
    private let settings: AppSettings

    init(vm: IslandViewModel, settings: AppSettings) {
        self.vm = vm
        self.settings = settings
    }

    /// Main thread. Payload: {cmd, exit, duration, cwd, term, pid}.
    func ingest(_ payload: [String: Any]) {
        DevLog.write("command: \(payload["cmd"] ?? "?") exit=\(payload["exit"] ?? "?") \(payload["duration"] ?? "?")s")
        guard settings.commandBanners, !vm.isOpen,
              let cmd = payload["cmd"] as? String,
              let exit = (payload["exit"] as? NSNumber)?.intValue,
              let duration = (payload["duration"] as? NSNumber)?.doubleValue,
              duration >= settings.commandThreshold,
              // 130: stopped with Ctrl-C. 148: suspended with Ctrl-Z, so not finished.
              exit != 130, exit != 148
        else { return }
        let words = Self.words(cmd)
        guard !words.isEmpty, !Self.isInteractive(words) else { return }
        let term = payload["term"] as? String ?? ""
        let pid = (payload["pid"] as? NSNumber)?.int32Value
        guard !Self.ranInFrontmostApp(pid: pid, term: term) else {
            DevLog.write("command skipped: its terminal is in front")
            return
        }

        let ok = exit == 0
        let folder = Self.folderName(payload["cwd"] as? String ?? "")
        let label = Self.label(words)
        vm.notify(Notice(icon: ok ? "checkmark" : "xmark",
                         tint: ok ? AgentPhase.done.color : .red,
                         title: ok ? "\(label) finished" : "\(label) failed",
                         subtitle: ok ? folder : "\(folder) · exit \(exit)",
                         trailing: formatDuration(duration)),
                  duration: ok ? 5 : 8)
        if settings.agentSound { IsleSound.play(ok ? "Glass" : "Basso") }
    }

    // MARK: Reading the command line

    /// The words of the first simple command, quotes removed, leading `FOO=1`, `sudo`, `time`…
    /// dropped. Good enough for a label and a first-word check, not a shell parser.
    static func words(_ cmd: String) -> [String] {
        var words: [String] = []
        var cur = ""
        var quote: Character?
        var escaped = false
        func flush() { if !cur.isEmpty { words.append(cur); cur = "" } }
        scan: for ch in cmd {
            if escaped { cur.append(ch); escaped = false; continue }
            if let q = quote {
                if ch == q { quote = nil } else if ch == "\\" && q == "\"" { escaped = true } else { cur.append(ch) }
                continue
            }
            switch ch {
            case "\\": escaped = true
            case "'", "\"": quote = ch
            case " ", "\t", "(", ")", "{", "}": flush()
            case ";", "|", "&", "\n", "<", ">":
                flush()
                // `cd ios && xcodebuild …` is about xcodebuild.
                if words.first == "cd" || words.first == "pushd" { words.removeAll() }
                if !words.isEmpty { break scan }
            default: cur.append(ch)
            }
        }
        flush()

        // Wrappers that run the real command: skip them, their flags and numeric arguments.
        var i = 0
        var afterWrapper = false
        while i < words.count {
            let w = words[i]
            if isAssignment(w) || wrappers.contains(w) { afterWrapper = afterWrapper || wrappers.contains(w); i += 1; continue }
            if afterWrapper, w.hasPrefix("-") || Int(w) != nil { i += 1; continue }
            break
        }
        var rest = Array(words[i...])
        if let first = rest.first, first.contains("/") { rest[0] = (first as NSString).lastPathComponent }
        return rest
    }

    private static let wrappers: Set<String> = ["sudo", "time", "command", "builtin", "noglob", "nocorrect",
                                                "nice", "nohup", "env", "caffeinate", "exec"]

    private static func isAssignment(_ w: String) -> Bool {
        guard let eq = w.firstIndex(of: "="), eq != w.startIndex else { return false }
        return w[..<eq].allSatisfy { $0 == "_" || $0.isLetter || $0.isNumber }
    }

    /// Editors, pagers, remote shells, monitors, agents and REPLs run until you quit them,
    /// so their "finishing" is never news.
    static func isInteractive(_ words: [String]) -> Bool {
        guard let name = words.first else { return false }
        let args = Array(words.dropFirst())
        if alwaysInteractive.contains(name) { return true }
        if replsWithoutArgs.contains(name) && args.isEmpty { return true }
        switch name {
        case "tail":
            return args.contains { $0 == "--follow" || $0.hasPrefix("--follow=") || ($0.hasPrefix("-") && !$0.hasPrefix("--") && ($0.contains("f") || $0.contains("F"))) }
        case "git":
            var j = 0
            while j < args.count, args[j].hasPrefix("-") { j += ["-C", "-c"].contains(args[j]) ? 2 : 1 }
            return j < args.count && ["log", "diff", "show", "blame", "reflog", "help"].contains(args[j])
        case "docker", "podman", "kubectl":
            return args.contains { ["-it", "-ti", "-i", "-t", "--interactive", "--tty"].contains($0) }
        default:
            return false
        }
    }

    private static let alwaysInteractive: Set<String> = [
        "vim", "vi", "nvim", "view", "nano", "pico", "micro", "emacs", "hx",
        "less", "more", "most", "man",
        "ssh", "mosh", "sftp", "ftp", "telnet", "su",
        "top", "htop", "btop", "atop", "watch",
        "tmux", "screen", "zellij",
        "claude", "codex", "gemini", "aider", "opencode", "cursor-agent", "amp", "goose",
        "irb", "ipython", "ghci", "psql", "mysql", "sqlite3", "redis-cli", "mongosh",
        "lazygit", "tig", "fzf", "ranger", "nnn", "yazi", "mc",
        "fg", "bg", "wait",
    ]
    private static let replsWithoutArgs: Set<String> = ["python", "python3", "node", "bun", "deno", "swift", "lua", "ruby"]

    /// "swift build", "npm run test", "cargo test": up to three words, stopping at the first
    /// flag, and never wider than 28 characters.
    static func label(_ words: [String]) -> String {
        var picked: [String] = []
        for w in words.prefix(3) {
            if !picked.isEmpty && w.hasPrefix("-") { break }
            picked.append(w)
        }
        while picked.count > 1 && picked.joined(separator: " ").count > 28 { picked.removeLast() }
        let s = picked.joined(separator: " ")
        return s.count > 28 ? String(s.prefix(27)) + "…" : s
    }

    static func folderName(_ cwd: String) -> String {
        if cwd.isEmpty { return "Terminal" }
        if cwd == NSHomeDirectory() { return "~" }
        return (cwd as NSString).lastPathComponent
    }

    // MARK: Frontmost terminal

    /// You're looking at the terminal that ran it, so a banner would only repeat what you see.
    /// The shell's parent chain finds most hosts exactly (Terminal, Ghostty, VS Code, Cursor…);
    /// $TERM_PROGRAM covers hosts whose shells are detached from the app (iTerm2's server).
    static func ranInFrontmostApp(pid: pid_t?, term: String) -> Bool {
        guard let front = NSWorkspace.shared.frontmostApplication else { return false }
        if var p = pid, p > 1 {
            for _ in 0..<32 {
                if p == front.processIdentifier { return true }
                guard let b = ProcInfo.bsd(p), b.ppid > 1, b.ppid != p else { break }
                p = b.ppid
            }
        }
        guard let id = front.bundleIdentifier else { return false }
        return terminalBundles[term]?.contains(id) ?? false
    }

    private static let terminalBundles: [String: Set<String>] = [
        "Apple_Terminal": ["com.apple.Terminal"],
        "iTerm.app": ["com.googlecode.iterm2"],
        "ghostty": ["com.mitchellh.ghostty"],
        "WezTerm": ["com.github.wez.wezterm"],
        // Cursor, Windsurf and VSCodium report themselves as vscode too.
        "vscode": ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.todesktop.230313mzl4w4u92",
                   "com.exafunction.windsurf", "com.vscodium"],
        "cursor": ["com.todesktop.230313mzl4w4u92"],
        "WarpTerminal": ["dev.warp.Warp-Stable", "dev.warp.Warp"],
        "Hyper": ["co.zeit.hyper"],
        "kitty": ["net.kovidgoyal.kitty"],
        "zed": ["dev.zed.Zed"],
    ]
}

/// Installs the zsh hook that reports finished commands: writes ~/.config/isle/isle.zsh and
/// adds one `source` line to ~/.zshrc (a backup is kept next to it). Removing deletes only
/// that line and the script.
enum ShellHookInstaller {
    static let marker = ".config/isle/isle.zsh"
    static let sourceLine = #"[[ -r "$HOME/.config/isle/isle.zsh" ]] && source "$HOME/.config/isle/isle.zsh"  # Isle: banner when a long command finishes"#

    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    static var scriptURL: URL { home.appendingPathComponent(marker) }
    /// Resolved so a dotfiles symlink stays a symlink.
    static var zshrcURL: URL { home.appendingPathComponent(".zshrc").resolvingSymlinksInPath() }

    static var isInstalled: Bool {
        guard FileManager.default.fileExists(atPath: scriptURL.path),
              let rc = try? String(contentsOf: zshrcURL, encoding: .utf8) else { return false }
        return rc.contains(marker)
    }

    /// The login shell isn't zsh, so the hook would never load.
    static var loginShellIsZsh: Bool {
        guard let pw = getpwuid(getuid()), let sh = pw.pointee.pw_shell else { return true }
        return String(cString: sh).hasSuffix("/zsh")
    }

    static func install() throws {
        try writeScript()
        let rc = (try? String(contentsOf: zshrcURL, encoding: .utf8)) ?? ""
        guard !rc.contains(marker) else { return }
        let sep = rc.isEmpty || rc.hasSuffix("\n") ? "" : "\n"
        try writeZshrc(rc + sep + sourceLine + "\n")
    }

    static func uninstall() throws {
        if let rc = try? String(contentsOf: zshrcURL, encoding: .utf8), rc.contains(marker) {
            let kept = rc.components(separatedBy: "\n").filter { !$0.contains(marker) }
            try writeZshrc(kept.joined(separator: "\n"))
        }
        try? FileManager.default.removeItem(at: scriptURL)
    }

    /// Keeps an installed script in step with this version of Isle. Off the main thread.
    static func refreshIfInstalled() {
        DispatchQueue.global(qos: .utility).async {
            guard isInstalled, (try? String(contentsOf: scriptURL, encoding: .utf8)) != script else { return }
            try? writeScript()
        }
    }

    private static func writeScript() throws {
        try FileManager.default.createDirectory(at: scriptURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
    }

    private static func writeZshrc(_ text: String) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: zshrcURL.path) {
            let backup = zshrcURL.appendingPathExtension("isle-backup")
            try? fm.removeItem(at: backup)
            try fm.copyItem(at: zshrcURL, to: backup)
        }
        try text.write(to: zshrcURL, atomically: true, encoding: .utf8)
    }

    /// preexec notes the command (aliases expanded) and start time; precmd posts in the
    /// background if it ran 10 s or longer. Never prints, never waits, and does nothing when
    /// curl is missing or the file is sourced twice.
    static let script = #"""
    # Isle: tells the notch when a long command finishes.
    # Written by Isle (Settings > Agents > Terminal commands) and replaced on update.
    [[ -o interactive ]] || return 0
    (( ${+_isle_cmd_loaded} )) && return 0
    typeset -g _isle_cmd_loaded=1
    (( ${+commands[curl]} )) || return 0
    zmodload zsh/datetime 2>/dev/null || return 0
    autoload -Uz add-zsh-hook

    typeset -g _isle_cmd= _isle_start=

    _isle_preexec() {
      _isle_cmd=${2:-$1}
      _isle_start=$EPOCHREALTIME
    }

    # $1 as the body of a JSON string, in REPLY.
    _isle_json() {
      emulate -L zsh
      local s=$1 bs='\' q='"' out= c hex i
      s=${s//$bs/$bs$bs}
      s=${s//$q/$bs$q}
      s=${s//$'\n'/${bs}n}
      s=${s//$'\t'/${bs}t}
      s=${s//$'\r'/${bs}r}
      if [[ $s == *[[:cntrl:]]* ]]; then
        for (( i = 1; i <= $#s; i++ )); do
          c=$s[i]
          if [[ $c == [[:cntrl:]] ]]; then
            printf -v hex '\\u%04x' "'$c"
            out+=$hex
          else
            out+=$c
          fi
        done
        s=$out
      fi
      REPLY=$s
    }

    _isle_precmd() {
      local code=$?
      emulate -L zsh
      [[ -n $_isle_start ]] || return 0
      local -i ms=$(( (EPOCHREALTIME - _isle_start) * 1000 ))
      local cmd=$_isle_cmd
      _isle_start= _isle_cmd=
      (( ms >= 10000 )) || return 0
      local term=$TERM_PROGRAM json
      [[ -z $term && -n $KITTY_WINDOW_ID ]] && term=kitty
      # Integer math: printf %f would write "12,3" under a German locale.
      local dur=$(( ms / 1000 )).$(( ms % 1000 / 100 ))
      _isle_json "$cmd";  json="{\"cmd\":\"$REPLY\""
      _isle_json "$PWD";  json+=",\"cwd\":\"$REPLY\""
      _isle_json "$term"; json+=",\"term\":\"$REPLY\""
      json+=",\"exit\":$code,\"duration\":$dur,\"pid\":$$}"
      curl -s -m 1 -X POST -H 'Content-Type: application/json' --data-binary "$json" \
        http://127.0.0.1:\#(HookServer.defaultPort)/hook/command >/dev/null 2>&1 &!
    }

    add-zsh-hook preexec _isle_preexec
    add-zsh-hook precmd _isle_precmd

    """#
}
