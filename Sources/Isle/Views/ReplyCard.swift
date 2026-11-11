import Combine
import SwiftUI

extension EnvironmentValues {
    /// Lets small views deep in a tab (like `ReplyCard`) reach the app without threading `env`
    /// through every initializer. Set by AgentsTab.
    @Entry var isleEnv: AppEnvironment? = nil
}

/// One-line answer to a session that ended its turn on a question. Sits under the AgentRow,
/// shaped like PermissionCard but neutral, since nothing is blocked on a decision.
struct ReplyCard: View {
    let session: AgentSession
    let question: String
    @Environment(\.isleEnv) private var env
    @State private var text = ""
    @FocusState private var focused: Bool

    /// Cards on screen (the island takes the keyboard while any is) and which one is typing.
    private static var editing: String?
    /// Unsent text survives the island closing on hover-out.
    private static var drafts: [String: String] = [:]

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "arrowshape.turn.up.left.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.islandTertiary)
                .frame(width: 34)
            // One line: the row above already says what's being asked, so the field carries the
            // question as its placeholder instead of repeating it on a line of its own.
            HStack(spacing: 6) {
                    TextField("", text: $text, prompt: Text(question).foregroundStyle(Color.islandTertiary))
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(.white)
                        .focused($focused)
                        .onSubmit { send(text) }
                        .onExitCommand { focused = false }
                        .help(question)
                    if AgentReplier.isYesNo(question), trimmed.isEmpty {
                        PillButton(title: "Yes") { send("Yes") }
                        PillButton(title: "No") { send("No") }
                    }
                    Button { send(text) } label: {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.black)
                            .frame(width: 20, height: 20)
                            .background(Circle().fill(.white))
                            .opacity(trimmed.isEmpty ? 0.3 : 1)
                    }
                    .buttonStyle(.plain)
                    .disabled(trimmed.isEmpty)
                    .help("Send")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.06))
        )
        .onAppear {
            text = Self.drafts[session.id] ?? ""
            env?.vm.claimKeyboard("reply-\(session.id)")
        }
        .onDisappear {
            env?.vm.claimKeyboard("reply-\(session.id)", false)
        }
        .onChange(of: text) { _, t in Self.drafts[session.id] = t.isEmpty ? nil : t }
        .onChange(of: focused) { _, f in
            if f {
                Self.editing = session.id
                env?.vm.isEditingText = true
            } else if Self.editing == session.id {
                Self.editing = nil
                env?.vm.isEditingText = false
            }
        }
    }

    private func send(_ reply: String) {
        guard let env, !reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        Self.drafts[session.id] = nil
        text = ""
        focused = false
        AgentReplier.send(reply, to: session, env: env)
    }
}
