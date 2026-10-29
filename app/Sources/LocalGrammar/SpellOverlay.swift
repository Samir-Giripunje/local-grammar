import AppKit
import SwiftUI

@MainActor
final class SpellOverlay {
    private let watcher: SpellWatcher
    private let badge = OverlayPanel(size: NSSize(width: 26, height: 26))
    private let list = OverlayPanel(size: NSSize(width: 340, height: 100))
    private let card = OverlayPanel(size: NSSize(width: 300, height: 100))
    private let toastPanel = OverlayPanel(size: NSSize(width: 300, height: 30))
    private let underlinePanel = OverlayPanel(size: .zero)
    private let badgeState = BadgeState()
    private let underlineState = UnderlineState()
    private let cardState = CardState()
    private let toastState = ToastState()
    private var cardPinned = false
    private var hoverTask: Task<Void, Never>?
    private var toastCount = 0

    init(watcher: SpellWatcher) {
        self.watcher = watcher
        badge.setContent(BadgeView(state: badgeState) { [weak self] in self?.toggleList() })
        list.setContent(IssueListView(watcher: watcher))
        card.setContent(IssueCardView(watcher: watcher, state: cardState))
        toastPanel.setContent(ToastView(state: toastState))
        toastPanel.ignoresMouseEvents = true
        underlinePanel.hasShadow = false
        underlinePanel.ignoresMouseEvents = true
        underlinePanel.setContent(UnderlineView(state: underlineState))
    }

    func show(at fieldFrame: CGRect, count: Int, hasSpelling: Bool, checking: Bool, compactField: Bool) {
        badgeState.count = count
        badgeState.hasSpelling = hasSpelling
        badgeState.checking = checking
        if count == 0, compactField {
            badge.orderOut(nil)
        } else {
            let origin = NSPoint(x: fieldFrame.maxX - 32, y: fieldFrame.minY + 6)
            if badge.frame.origin != origin { badge.setFrameOrigin(origin) }
            if !badge.isVisible { badge.orderFrontRegardless() }
        }
        if list.isVisible, count == 0 { list.orderOut(nil) }
        if list.isVisible { fitList() }
        if card.isVisible, !watcher.issues.contains(where: { $0.id == cardState.issueID }) { closeCard() }
    }

    func underline(_ lines: [Underline], within fieldFrame: CGRect) {
        guard !lines.isEmpty else { return underlinePanel.orderOut(nil) }
        let area = fieldFrame.insetBy(dx: -4, dy: -4)
        if underlinePanel.frame != area { underlinePanel.setFrame(area, display: false) }
        if lines.count != underlineState.lines.count {
            AppLog.write("underlines: \(lines.count) drawn (\(lines.filter(\.isSpelling).count) spelling)")
        }
        underlineState.lines = lines.map { line in
            Underline(
                issueID: line.issueID, rect: line.rect.offsetBy(dx: -area.minX, dy: -area.minY), isSpelling: line.isSpelling
            )
        }
        if !underlinePanel.isVisible {
            underlinePanel.orderFrontRegardless()
            if badge.isVisible { badge.orderFrontRegardless() }
        }
    }

    func showCard(for issue: SpellIssue, under wordRect: CGRect, pinned: Bool) {
        hoverTask?.cancel()
        list.orderOut(nil)
        cardPinned = pinned
        cardState.issueID = issue.id
        card.contentView?.layoutSubtreeIfNeeded()
        let size = card.contentView?.fittingSize ?? card.frame.size
        let visible = NSScreen.screens.first { $0.frame.contains(wordRect.origin) }?.visibleFrame ?? .zero
        var origin = NSPoint(x: wordRect.minX - 8, y: wordRect.minY - size.height - 4)
        if origin.y < visible.minY { origin.y = wordRect.maxY + 4 }
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        card.setFrame(NSRect(origin: origin, size: size), display: true)
        card.orderFrontRegardless()
    }

    func closeCard() {
        hoverTask?.cancel()
        card.orderOut(nil)
    }

    func mouseMoved(to point: CGPoint) {
        if card.isVisible, card.frame.insetBy(dx: -8, dy: -8).contains(point) {
            hoverTask?.cancel()
            return
        }
        if let (issue, _) = watcher.underline(at: point) {
            if card.isVisible, cardState.issueID == issue.id {
                hoverTask?.cancel()
                return
            }
            hoverTask?.cancel()
            hoverTask = Task {
                try? await Task.sleep(for: .seconds(CheckingTiming.hoverDelay.current))
                guard !Task.isCancelled, let still = watcher.underline(at: NSEvent.mouseLocation), still.issue.id == issue.id
                else { return }
                showCard(for: watcher.withSuggestions(still.issue), under: still.rect, pinned: false)
            }
            return
        }
        guard card.isVisible, !cardPinned else {
            hoverTask?.cancel()
            return
        }
        hoverTask?.cancel()
        hoverTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            card.orderOut(nil)
        }
    }

    func toast(_ message: String, success: Bool) {
        toastState.message = message
        toastState.success = success
        toastCount += 1
        let shown = toastCount
        toastPanel.contentView?.layoutSubtreeIfNeeded()
        let size = toastPanel.contentView?.fittingSize ?? toastPanel.frame.size
        let anchor = badge.isVisible ? NSPoint(x: badge.frame.maxX, y: badge.frame.maxY + 6) : NSEvent.mouseLocation
        let visible = NSScreen.screens.first { $0.frame.contains(anchor) }?.visibleFrame ?? .zero
        let origin = NSPoint(
            x: min(max(anchor.x - size.width, visible.minX + 8), visible.maxX - size.width - 8),
            y: min(anchor.y, visible.maxY - size.height - 8)
        )
        toastPanel.setFrame(NSRect(origin: origin, size: size), display: true)
        toastPanel.orderFrontRegardless()
        Task {
            try? await Task.sleep(for: .seconds(2))
            if toastCount == shown { toastPanel.orderOut(nil) }
        }
    }

    func hide() {
        badge.orderOut(nil)
        underlinePanel.orderOut(nil)
        closeList()
    }

    func closeList() {
        list.orderOut(nil)
        closeCard()
    }

    private func fitList() {
        guard let size = list.contentView?.fittingSize, size != list.frame.size else { return }
        let below = list.frame.maxY <= badge.frame.minY
        let y = below ? list.frame.maxY - size.height : list.frame.minY
        list.setFrame(NSRect(x: list.frame.maxX - size.width, y: y, width: size.width, height: size.height), display: true)
    }

    private func toggleList() {
        if list.isVisible || watcher.issues.isEmpty { return closeList() }
        closeCard()
        list.contentView?.layoutSubtreeIfNeeded()
        let size = list.contentView?.fittingSize ?? list.frame.size
        let visible = badge.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        var origin = NSPoint(x: badge.frame.maxX - size.width, y: badge.frame.maxY + 6)
        if origin.y + size.height > visible.maxY { origin.y = badge.frame.minY - size.height - 6 }
        origin.x = max(origin.x, visible.minX + 8)
        list.setFrame(NSRect(origin: origin, size: size), display: true)
        list.orderFrontRegardless()
    }
}

final class OverlayPanel: NSPanel {
    init(size: NSSize) {
        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: true
        )
        level = .floating
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    }

    func setContent<Content: View>(_ view: Content) {
        contentView = FirstClickHostingView(rootView: view)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class BadgeState: ObservableObject {
    @Published var count = 0
    @Published var hasSpelling = false
    @Published var checking = false
}

struct BadgeView: View {
    @ObservedObject var state: BadgeState
    let onTap: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onTap) {
            if state.count > 0 {
                ZStack {
                    Circle().fill(state.hasSpelling ? Color.red : Color.orange)
                    Text(state.count > 99 ? "99+" : "\(state.count)")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                }
                .frame(width: 22, height: 22)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.green)
                    .opacity(0.35)
                    .frame(width: 22, height: 22)
            }
        }
        .buttonStyle(.plain)
        .opacity(state.checking ? 0.6 : 1)
        .scaleEffect(hovering ? 1.12 : 1)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .pointingHand(hovering: $hovering)
        .padding(2)
    }
}

struct IssueListView: View {
    @ObservedObject var watcher: SpellWatcher

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(watcher.issues.count) issue\(watcher.issues.count == 1 ? "" : "s")").font(.headline)
                Spacer()
                let fixable = watcher.fixableSpelling.count
                if fixable > 1 {
                    Button("Fix all spelling (\(fixable))") { watcher.fixAllSpelling() }
                        .buttonStyle(ChipButtonStyle(prominent: true))
                        .disabled(watcher.isFixing)
                }
            }
            .padding(10)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(watcher.issues) { issue in
                        IssueRow(watcher: watcher, issue: issue)
                        if issue != watcher.issues.last { Divider() }
                    }
                }
            }
            .frame(maxHeight: 320)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 340)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
    }
}

struct IssueRow: View {
    @ObservedObject var watcher: SpellWatcher
    let issue: SpellIssue

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle().fill(issue.kind == "Spelling" ? Color.red : Color.orange).frame(width: 7, height: 7)
                Text(watcher.word(for: issue)).strikethrough().foregroundStyle(.secondary)
                Text(issue.kind).font(.caption).foregroundStyle(.tertiary)
                Spacer()
                if issue.kind == "Spelling" {
                    Button("Add to dictionary") { watcher.addToDictionary(issue) }
                        .buttonStyle(HoverLinkStyle())
                }
                Button("Ignore") { watcher.ignore(issue) }
                    .buttonStyle(HoverLinkStyle())
            }
            HStack(spacing: 6) {
                ForEach(Array(issue.suggestions.prefix(3).enumerated()), id: \.offset) { index, suggestion in
                    let label = suggestion.isEmpty ? "Remove" : suggestion
                    Button(label) { watcher.apply(suggestion, for: issue) }
                        .buttonStyle(ChipButtonStyle(prominent: index == 0))
                }
            }
            .disabled(watcher.isFixing)
            Text(issue.message).font(.caption).foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
    }
}

struct Underline: Equatable {
    let issueID: String
    let rect: CGRect
    let isSpelling: Bool
}

@MainActor
final class UnderlineState: ObservableObject {
    @Published var lines: [Underline] = []
}

struct UnderlineView: View {
    @ObservedObject var state: UnderlineState

    var body: some View {
        Canvas { context, size in
            for line in state.lines {
                let y = size.height - line.rect.minY + 1
                var path = Path()
                path.move(to: CGPoint(x: line.rect.minX, y: y))
                path.addLine(to: CGPoint(x: line.rect.maxX, y: y))
                context.stroke(
                    path, with: .color(line.isSpelling ? .red : .orange),
                    style: StrokeStyle(lineWidth: 2, lineCap: .round)
                )
            }
        }
        .allowsHitTesting(false)
    }
}

@MainActor
final class CardState: ObservableObject {
    @Published var issueID = ""
}

struct IssueCardView: View {
    @ObservedObject var watcher: SpellWatcher
    @ObservedObject var state: CardState

    var body: some View {
        VStack(spacing: 0) {
            if let issue = watcher.issues.first(where: { $0.id == state.issueID }) {
                IssueRow(watcher: watcher, issue: issue)
            }
        }
        .frame(width: 300)
        .fixedSize(horizontal: false, vertical: true)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
    }
}

@MainActor
final class ToastState: ObservableObject {
    @Published var message = ""
    @Published var success = true
}

struct ToastView: View {
    @ObservedObject var state: ToastState

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: state.success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(state.success ? .green : .orange)
            Text(state.message).font(.callout)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .fixedSize()
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.separator))
    }
}
