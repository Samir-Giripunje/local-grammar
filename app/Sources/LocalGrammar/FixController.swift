import AppKit
import SwiftUI

@MainActor
final class FixController: ObservableObject {
    enum State {
        case checking
        case loadingModel
        case noSelection
        case needsAccess
        case unchanged
        case replaced
        case copied
        case failed(String)
        case reviewing
    }

    @Published private(set) var state: State = .checking

    private let server: ServerManager
    private lazy var panel = FixPanel(controller: self)
    private var target: NSRunningApplication?
    private var context: SelectionContext?
    /// The selection as the field itself reports it, for confirming it is still selected before pasting.
    private var selectionText: String?
    /// The selection came from a rich editor and was sent as Markdown, so the fix is pasted formatted.
    private var isRich = false
    private var job: Task<Void, Never>?
    private var shownCount = 0
    private var review: ReviewModel?
    private var reviewWindow: ReviewWindow?

    init(server: ServerManager) {
        self.server = server
    }

    func run() {
        job?.cancel()
        guard Accessibility.isTrusted else {
            Accessibility.prompt()
            return show(.needsAccess)
        }
        let wasShowing = panel.isVisible
        panel.orderOut(nil)
        job = Task {
            if wasShowing { try? await Task.sleep(for: .milliseconds(120)) }
            target = NSWorkspace.shared.frontmostApplication
            let context = SelectionContext.capture()
            self.context = context
            if let context, context.range.length == 0 {
                return show(.noSelection, autoHide: 1.5)
            }
            // Copying keeps paragraph breaks (Chromium's selected text joins paragraphs) and the formatting.
            let copied = await Selection.copy()
            let markdown = copied.flatMap(Self.markdown(of:))
            let fieldText = context?.selectedText?.isEmpty == false ? context?.selectedText : nil
            guard let text = markdown ?? copied?.text ?? fieldText, !Task.isCancelled else {
                return show(.noSelection, autoHide: 1.5)
            }
            selectionText = fieldText ?? copied?.text
            isRich = markdown != nil
            let limit = server.settings.maxSelection
            guard text.count <= limit else {
                return show(
                    .failed("That's \(text.count.formatted()) characters — this model takes up to \(limit.formatted()). Select less, or raise the limit in Local Grammar → model settings."),
                    autoHide: 4
                )
            }
            show(.checking)
            do {
                let corrected = try await proofread(text)
                guard !Task.isCancelled else { return }
                if corrected == text {
                    show(.unchanged, autoHide: 1.2)
                } else {
                    openReview(original: text, corrected: corrected)
                }
            } catch {
                guard !Task.isCancelled else { return }
                show(.failed(error.localizedDescription), autoHide: 3)
            }
        }
    }

    /// Proofreads with the chosen engine. When Apple's model won't take the text (too long, declined) and
    /// Qwen is ready to go, Qwen gets a try.
    private func proofread(_ text: String) async throws -> String {
        guard server.engine == .apple else { return try await proofreadWithQwen(text) }
        do {
            return try await AppleProofreader.correct(text, settings: server.settings)
        } catch let failure as AppleProofreader.Failure where failure.qwenMightWork && canFallBackToQwen(text) {
            AppLog.write("Apple's model couldn't proofread (\(failure.message)); trying Qwen")
            return try await proofreadWithQwen(text)
        }
    }

    private func canFallBackToQwen(_ text: String) -> Bool {
        server.qwenIsSetUp && GrammarModel.isDownloaded(server.modelID)
            && text.count <= server.tuning.settings(for: server.modelID).maxSelection
    }

    private func proofreadWithQwen(_ text: String) async throws -> String {
        guard server.qwenIsSetUp else {
            throw GrammarError(message: "Qwen isn't set up yet — open Local Grammar to set it up, or switch to Apple Intelligence.")
        }
        if server.status != .ready {
            show(.loadingModel)
            guard await server.ensureLoaded(), !Task.isCancelled else {
                throw GrammarError(message: "The model couldn't load — open Local Grammar to check.")
            }
            show(.checking)
        }
        server.noteUsed()
        return try await GrammarClient.correct(text, token: server.token, settings: server.tuning.settings(for: server.modelID))
    }

    /// Markdown for a rich selection, only when it holds exactly the same words as the plain copy.
    private static func markdown(of copied: Selection.Copied) -> String? {
        guard let html = copied.html, let markdown = RichText.markdown(fromHTML: html) else { return nil }
        let letters = { (text: String) in RichText.fold(text).filter(\.isLetter) }
        return letters(RichText.plainWords(ofMarkdown: markdown)) == letters(copied.text) ? markdown : nil
    }

    private func openReview(original: String, corrected: String) {
        state = .reviewing
        panel.orderOut(nil)
        let model = ReviewModel(original: original, corrected: corrected, appName: target?.localizedName ?? "app")
        review = model
        reviewWindow?.close()
        let window = ReviewWindow(model: model, onReplace: { [weak self] in self?.apply() }, onClose: { [weak self] in
            self?.reviewClosed()
        })
        reviewWindow = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func reviewClosed() {
        reviewWindow = nil
        if case .reviewing = state { state = .checking }
    }

    func apply() {
        guard let review else { return }
        let original = selectionText ?? review.original
        let corrected = review.text
        let html = isRich ? RichText.html(fromMarkdown: corrected) : nil
        self.review = nil
        reviewWindow?.close()
        let app = target
        let context = context
        Task {
            app?.activate()
            try? await Task.sleep(for: .milliseconds(120))
            guard let app, NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else {
                return show(.failed("You switched apps, so the fix wasn't pasted."), autoHide: 2.5, focus: false)
            }
            guard let context, let before = await context.reselect(original: original) else {
                Selection.copyToClipboard(corrected, html: html)
                return show(.copied, autoHide: 4, focus: false)
            }
            let landed = await Selection.paste(corrected, html: html) {
                guard let value = context.currentValue(), value != before.value else { return false }
                if html == nil, let range = before.range {
                    let expected = (before.value as NSString).replacingCharacters(in: range, with: corrected)
                    if value == expected || RichText.fold(value) == RichText.fold(expected) { return true }
                }
                // Formatted paste, or a selection Chromium counts differently: the corrected words must be there.
                return RichText.fold(value).contains(RichText.fold(RichText.plainWords(ofMarkdown: corrected)))
            }
            if landed {
                show(.replaced, autoHide: 1.5, focus: false)
            } else {
                show(.failed("Couldn't confirm the fix was pasted — check your text (⌘Z undoes it)."), autoHide: 3.5, focus: false)
            }
        }
    }

    func cancel() {
        job?.cancel()
        panel.orderOut(nil)
        review = nil
        reviewWindow?.close()
    }

    func panelLostFocus() {
        if case .reviewing = state { return panel.orderOut(nil) }
        cancel()
    }

    private func show(_ newState: State, autoHide delay: Double? = nil, focus: Bool = true) {
        state = newState
        shownCount += 1
        panel.present(takingFocus: focus)
        guard let delay else { return }
        let shown = shownCount
        Task {
            try? await Task.sleep(for: .seconds(delay))
            if self.shownCount == shown { self.panel.orderOut(nil) }
        }
    }
}

final class FixPanel: NSPanel, NSWindowDelegate {
    private let controller: FixController

    init(controller: FixController) {
        self.controller = controller
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 120),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: true
        )
        level = .floating
        isFloatingPanel = true
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        delegate = self
        contentView = NSHostingView(rootView: FixView(controller: controller))
    }

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        controller.cancel()
    }

    func windowDidResignKey(_ notification: Notification) {
        controller.panelLostFocus()
    }

    @MainActor
    func present(takingFocus: Bool) {
        guard let content = contentView else { return }
        content.layoutSubtreeIfNeeded()
        let size = content.fittingSize
        if !isVisible {
            setFrameOrigin(origin(for: size))
        }
        setContentSize(size)
        if takingFocus {
            makeKeyAndOrderFront(nil)
        } else {
            orderFrontRegardless()
        }
    }

    private func origin(for size: NSSize) -> NSPoint {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        let bounds = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let x = min(max(mouse.x - size.width / 2, bounds.minX + 8), bounds.maxX - size.width - 8)
        let y = min(max(mouse.y - size.height - 16, bounds.minY + 8), bounds.maxY - size.height - 8)
        return NSPoint(x: x, y: y)
    }
}
