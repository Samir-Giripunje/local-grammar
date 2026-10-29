import AppKit
import SwiftUI

@MainActor
final class ReviewModel: ObservableObject {
    let original: String
    let appName: String
    let segments: [WordDiff.Segment]
    @Published private(set) var rejected = Set<Int>()
    @Published private(set) var text: String
    @Published private(set) var isEdited = false
    @Published var copied = false

    init(original: String, corrected: String, appName: String) {
        self.original = original
        self.appName = appName
        segments = WordDiff.segments(original, corrected)
        text = corrected
    }

    var changes: [(id: Int, old: String, new: String, before: String, after: String)] {
        segments.enumerated().compactMap { index, segment in
            guard case .change(let id, let old, let new) = segment else { return nil }
            return (id, old, new, context(before: index), context(after: index))
        }
    }

    func setText(_ newText: String) {
        text = newText
        isEdited = newText != assembled()
    }

    func toggle(_ id: Int) {
        if rejected.contains(id) { rejected.remove(id) } else { rejected.insert(id) }
        text = assembled()
    }

    func resetEdits() {
        isEdited = false
        text = assembled()
    }

    private func assembled() -> String {
        segments.map { segment in
            switch segment {
            case .same(_, let text): text
            case .change(let id, let old, let new): rejected.contains(id) ? old : new
            }
        }.joined()
    }

    private func context(before index: Int) -> String {
        let words = segments[..<index].map(Self.visibleText).joined().split(separator: " ").suffix(3)
        return words.joined(separator: " ")
    }

    private func context(after index: Int) -> String {
        let words = segments[(index + 1)...].map(Self.visibleText).joined().split(separator: " ").prefix(3)
        return words.joined(separator: " ")
    }

    private static func visibleText(_ segment: WordDiff.Segment) -> String {
        switch segment {
        case .same(_, let text): text
        case .change(_, _, let new): new
        }
    }
}

final class ReviewWindow: NSWindow, NSWindowDelegate {
    private let onClose: () -> Void

    init(model: ReviewModel, onReplace: @escaping () -> Void, onClose: @escaping () -> Void) {
        self.onClose = onClose
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 600),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        title = "Local Grammar — Review"
        titlebarAppearsTransparent = true
        isReleasedWhenClosed = false
        level = .floating
        minSize = NSSize(width: 360, height: 360)
        delegate = self
        contentView = NSHostingView(
            rootView: ReviewView(model: model, onReplace: onReplace, onCancel: { [weak self] in self?.close() })
        )
        placeOnRightEdge()
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }

    private func placeOnRightEdge() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let height = min(640, visible.height - 40)
        setFrame(
            NSRect(x: visible.maxX - 440 - 16, y: visible.maxY - height - 20, width: 440, height: height),
            display: false
        )
    }
}

struct ReviewView: View {
    @ObservedObject var model: ReviewModel
    let onReplace: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    section("Corrected text — you can edit it") {
                        TextEditor(text: Binding(get: { model.text }, set: { model.setText($0) }))
                            .font(.body)
                            .scrollContentBackground(.hidden)
                            .padding(8)
                            .frame(minHeight: 140)
                            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
                    }
                    section("\(model.changes.count) change\(model.changes.count == 1 ? "" : "s") — untick to keep your original") {
                        if model.isEdited {
                            HStack {
                                Text("You edited the text, so these switches are paused.")
                                    .font(.caption).foregroundStyle(.secondary)
                                Button("Undo my edits") { model.resetEdits() }
                                    .buttonStyle(.link).controlSize(.small)
                            }
                        }
                        VStack(spacing: 0) {
                            ForEach(model.changes, id: \.id) { change in
                                ChangeRow(change: change, accepted: !model.rejected.contains(change.id)) {
                                    model.toggle(change.id)
                                }
                                .disabled(model.isEdited)
                                Divider()
                            }
                        }
                    }
                }
                .padding(16)
                .padding(.top, 20)
            }
            Divider()
            HStack {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(model.copied ? "Copied ✓" : "Copy") {
                    Selection.copyToClipboard(model.text)
                    model.copied = true
                }
                Button("Replace in \(model.appName)", action: onReplace)
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .help("⌘↩")
            }
            .padding(12)
        }
        .frame(minWidth: 360, minHeight: 360)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
    }
}

struct ChangeRow: View {
    let change: (id: Int, old: String, new: String, before: String, after: String)
    let accepted: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: accepted ? "checkmark.square.fill" : "square")
                    .foregroundStyle(accepted ? Color.accentColor : Color.secondary)
                    .font(.system(size: 15))
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        let old = change.old.trimmingCharacters(in: .whitespacesAndNewlines)
                        let new = change.new.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !old.isEmpty { Text(old).strikethrough().foregroundStyle(.red) }
                        Image(systemName: "arrow.right").font(.caption).foregroundStyle(.secondary)
                        Text(new.isEmpty ? "(remove)" : new).bold().foregroundStyle(.green)
                    }
                    Text("…\(change.before) ▸ \(change.after)…")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .opacity(accepted ? 1 : 0.55)
        }
        .buttonStyle(.plain)
    }
}
