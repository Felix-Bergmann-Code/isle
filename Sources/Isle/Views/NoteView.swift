import AppKit
import SwiftUI

/// The Shelf's Note mode: one plain-text scratchpad you can jot into from the notch.
/// While it's on screen the panel may take the keyboard (`vm.wantsKeyboard`), and while the
/// editor has focus the island stays open (`vm.isEditingText`). Esc drops focus.
struct NoteView: View {
    let env: AppEnvironment
    var topInset: CGFloat = 0
    @Bindable private var note = NoteStore.shared
    @FocusState private var focused: Bool
    @State private var hovering = false
    @State private var copied = false
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        TextEditor(text: $note.text)
            .font(.system(size: 12.5))
            .foregroundStyle(Color.white.opacity(0.9))
            .lineSpacing(2)
            .scrollContentBackground(.hidden)
            .scrollIndicators(.never)
            .focused($focused)
            .overlay(alignment: .topLeading) {
                if note.text.isEmpty {
                    Text("Jot something down…")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Color.islandTertiary)
                        .padding(.leading, 5) // the editor's line fragment padding
                        .allowsHitTesting(false)
                }
            }
            .padding(10)
            .padding(.top, topInset)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.white.opacity(0.04)))
            .overlay(alignment: .topTrailing) {
                if hovering, !note.text.isEmpty {
                    actions.transition(.opacity)
                }
            }
            .onHover { h in withAnimation(Anim.micro) { hovering = h } }
            .onAppear { env.vm.claimKeyboard("note") }
            .onDisappear {
                env.vm.claimKeyboard("note", false)
                env.vm.isEditingText = false
                note.save()
            }
            .onChange(of: focused) { _, f in env.vm.isEditingText = f }
            .onChange(of: env.vm.isEditingText) { _, editing in
                if !editing, focused { focused = false }
            }
            .onChange(of: note.focusRequested, initial: true) { _, requested in
                guard requested else { return }
                note.focusRequested = false
                focused = true
            }
    }

    /// Copy and clear, shown on hover. The opaque backing matches the card so text runs under it.
    private var actions: some View {
        HStack(spacing: 0) {
            IslandIconButton(systemName: copied ? "checkmark" : "doc.on.doc", size: 10, padding: 4) { copy() }
                .contentTransition(.symbolEffect(.replace))
                .help("Copy note")
            IslandIconButton(systemName: "trash", size: 10, padding: 4) {
                note.replace(with: "", undoManager: undoManager)
            }
            .help("Clear note (⌘Z brings it back)")
        }
        .background(Capsule().fill(Color(white: 0.04)))
        .padding(6)
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(note.text, forType: .string)
        withAnimation(Anim.micro) { copied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            withAnimation(Anim.micro) { copied = false }
        }
    }
}
