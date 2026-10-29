import AppKit
import Carbon.HIToolbox

@MainActor
final class SpellWatcher: ObservableObject {
    enum CheckStatus: Equatable {
        case off
        case needsAccess
        case disabled(app: String, bundleID: String)
        case unreadable(app: String, pid: pid_t)
        case noField(app: String)
        case passwordField
        case tooLong(app: String)
        case checking(app: String, underlines: Bool)
    }

    static var maxLength: Int { Int(CheckingTiming.liveLimit.current) }

    @Published var isEnabled = UserDefaults.standard.object(forKey: "liveSpellCheck") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: "liveSpellCheck")
            if !isEnabled { clear(.off) }
        }
    }
    @Published var dialect = EnglishDialect.current {
        didSet {
            UserDefaults.standard.set(dialect.rawValue, forKey: "dialect")
            engine.use(dialect)
            suggestionCache = [:]
            recheck()
        }
    }
    @Published private(set) var disabledApps = Set(UserDefaults.standard.stringArray(forKey: "disabledApps") ?? [])
    @Published private(set) var issues: [SpellIssue] = []
    @Published private(set) var status = CheckStatus.off
    private(set) var issuesText = ""

    let engine = HarperEngine()
    private lazy var overlay = SpellOverlay(watcher: self)
    private var field: FocusedField?
    private var lintedText = ""
    private var rawIssues: [SpellIssue] = []
    private var ignored = Set<String>()
    private var isLinting = false
    private var lintGeneration = 0
    @Published private(set) var isFixing = false
    private var lastExposed: [pid_t: Date] = [:]
    private var lastKeystrokeAt = Date.distantPast
    private var drawnUnderlines: [Underline] = []
    private var underlineKey = ""
    private var lastFocusDescription = ""
    private var monitors: [Any] = []
    private var timer: Timer?
    private var timerInterval = 0.0
    /// Suggestions per misspelled word: looking them up costs ~40 ms a word, so it's done once, a word at a time.
    private var suggestionCache: [String: (suggestions: [String], best: String?)] = [:]
    private var suggesting: Task<Void, Never>?
    /// The page is moving: underlines are hidden until it settles, then redrawn where the words now are.
    private var isScrolling = false
    private var settle: Task<Void, Never>?

    var fixableSpelling: [SpellIssue] {
        issues.filter { $0.kind == "Spelling" && $0.best != nil }
    }

    func start() {
        engine.use(dialect)
        scheduleTimer()
        monitors = [
            NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
                let point = NSEvent.mouseLocation
                Task { @MainActor in self?.handleClick(at: point) }
            },
            NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
                let point = NSEvent.mouseLocation
                Task { @MainActor in self?.overlay.mouseMoved(to: point) }
            },
            NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] _ in
                let point = NSEvent.mouseLocation
                Task { @MainActor in self?.pageMoved(scrolledUnder: point) }
            },
            NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard Self.movesPage.contains(Int(event.keyCode)) else { return }
                Task { @MainActor in self?.pageMoved(scrolledUnder: nil) }
            },
        ].compactMap { $0 }
    }

    /// Keys that can scroll the page: Return, Page Up/Down, Home, End and the up/down arrows.
    private static let movesPage: Set<Int> = [
        kVK_Return, kVK_PageUp, kVK_PageDown, kVK_Home, kVK_End, kVK_UpArrow, kVK_DownArrow,
    ]

    /// Underlines sit in a window of their own, so they can't scroll with the text. Like Grammarly, they're
    /// hidden as soon as the page moves and drawn again where the words are once it settles.
    /// A scroll under the field's window hides them; a key that may scroll (`point` is nil) only redraws
    /// them shortly after, so moving the caret with the arrows doesn't make them flicker.
    private func pageMoved(scrolledUnder point: CGPoint?) {
        guard let field, !issues.isEmpty || isScrolling else { return }
        if let point, !isScrolling, !(FocusedField.windowFrame(of: field.element) ?? field.frame).contains(point) { return }
        if point != nil, !isScrolling {
            isScrolling = true
            drawnUnderlines = []
            overlay.underline([], within: field.frame)
            overlay.closeCard()
        }
        settle?.cancel()
        settle = Task {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            isScrolling = false
            underlineKey = ""
            tick()
        }
    }

    /// Re-reads the focused field at the user's chosen interval; picks up a changed interval on the next tick.
    private func scheduleTimer() {
        timerInterval = CheckingTiming.interval.current
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: timerInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if CheckingTiming.interval.current != self.timerInterval { self.scheduleTimer() }
                self.tick()
            }
        }
    }

    func underline(at point: CGPoint) -> (issue: SpellIssue, rect: CGRect)? {
        guard let hit = drawnUnderlines.first(where: { $0.rect.insetBy(dx: -2, dy: -3).contains(point) }),
              let issue = issues.first(where: { $0.id == hit.issueID })
        else { return nil }
        return (issue, hit.rect)
    }

    private func handleClick(at point: CGPoint) {
        guard let (issue, rect) = underline(at: point) else { return overlay.closeCard() }
        overlay.showCard(for: withSuggestions(issue), under: rect, pinned: true)
    }

    func toggle(app bundleID: String) {
        if disabledApps.contains(bundleID) {
            disabledApps.remove(bundleID)
        } else {
            disabledApps.insert(bundleID)
        }
        UserDefaults.standard.set(Array(disabledApps), forKey: "disabledApps")
    }

    func reconnect(pid: pid_t) {
        lastExposed[pid] = nil
        FocusedField.exposeWebContent(of: pid)
    }

    func apply(_ suggestion: String, for issue: SpellIssue) {
        guard !isFixing, let current = FocusedField.current(), current.text == issuesText, issues.contains(issue) else {
            return recheck()
        }
        let base = issuesText
        overlay.closeCard()
        isFixing = true
        Task {
            let applied = await replace(issue, with: suggestion, in: current, base: base)
            isFixing = false
            // The fix shows in the text itself; only say something when it didn't work.
            if !applied { overlay.toast("Couldn't apply — the text changed. Try again.", success: false) }
            recheck()
        }
    }

    func fixAllSpelling() {
        guard !isFixing, let current = FocusedField.current(), current.text == issuesText else { return recheck() }
        let fixes = fixableSpelling.sorted { $0.start > $1.start }
        guard !fixes.isEmpty else { return }
        isFixing = true
        Task {
            var base = issuesText
            var fixed = 0
            for issue in fixes {
                guard let best = issue.best, await replace(issue, with: best, in: current, base: base) else { break }
                base = (base as NSString).replacingCharacters(in: issue.range, with: best)
                fixed += 1
            }
            isFixing = false
            if fixed < fixes.count {
                overlay.toast("Fixed \(fixed) of \(fixes.count) — stopped because the text changed", success: false)
            }
            recheck()
        }
    }

    private func replace(_ issue: SpellIssue, with suggestion: String, in current: FocusedField, base: String) async -> Bool {
        let range = issue.range
        let expected = (base as NSString).replacingCharacters(in: range, with: suggestion)
        guard current.currentText() == base else { return false }
        guard await current.select(range, of: base) else {
            AppLog.write("could not select \(range) in \(current.role); fix not applied")
            return false
        }
        guard current.isStillFocused() else {
            AppLog.write("focus moved before the fix could be pasted; fix not applied")
            return false
        }
        let landed = { current.currentText() == expected }
        let applied = suggestion.isEmpty
            ? await Selection.delete(landed: landed)
            : await Selection.paste(suggestion, landed: landed)
        AppLog.write("fix [\(issue.kind)] in \(current.role): \(applied ? "applied ✓" : "NOT applied as expected")")
        return applied
    }

    func addToDictionary(_ issue: SpellIssue) {
        let word = word(for: issue)
        guard !word.isEmpty else { return }
        Task {
            MacSpelling.learn(word)
            await engine.addWord(word)
            overlay.toast("Added \u{201C}\(word)\u{201D} to your Mac's dictionary", success: true)
            recheck()
        }
    }

    func ignore(_ issue: SpellIssue) {
        ignored.insert(ignoreKey(issue))
        refreshVisibleIssues()
    }

    private func ignoreKey(_ issue: SpellIssue) -> String {
        "\(word(for: issue))|\(issue.message)"
    }

    func word(for issue: SpellIssue) -> String {
        let text = issuesText as NSString
        guard issue.start >= 0, issue.end <= text.length, issue.start <= issue.end else { return "" }
        return text.substring(with: issue.range)
    }

    private func tick() {
        guard isEnabled else { return clear(.off) }
        guard Accessibility.isTrusted else { return clear(.needsAccess) }
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else { return }
        let name = app.localizedName ?? app.bundleIdentifier ?? "this app"
        if let bundleID = app.bundleIdentifier, disabledApps.contains(bundleID) {
            return clear(.disabled(app: name, bundleID: bundleID))
        }

        logFocusChange(app)
        guard let current = FocusedField.current() else {
            exposeWebContent(of: app.processIdentifier)
            return clear(focusProblem(app: name, pid: app.processIdentifier))
        }
        guard current.text.utf16.count <= Self.maxLength else { return clear(.tooLong(app: name)) }
        guard current.frame.width >= 60, current.frame.height >= 14 else { return clear(.noField(app: name)) }

        let textChanged = current.text != field?.text
        if textChanged, let previous = field?.text, abs(current.text.utf16.count - previous.utf16.count) <= 2 {
            lastKeystrokeAt = Date()
        }
        field = current
        if textChanged { lint(current.text) }
        refreshVisibleIssues()
        let upToDate = current.text == issuesText
        let unchangedUntil = upToDate ? Int.max : Self.commonPrefixLength(issuesText, current.text)
        drawnUnderlines = isScrolling ? [] : underlines(in: current, for: issues.filter { $0.end < unchangedUntil })
        overlay.underline(drawnUnderlines, within: current.frame)
        overlay.show(
            at: current.frame,
            count: issues.count,
            hasSpelling: issues.contains { $0.kind == "Spelling" },
            checking: isLinting || !upToDate,
            compactField: current.frame.width < 200 && current.frame.height < 40
        )
        let underlinesWork = issues.isEmpty || !drawnUnderlines.isEmpty || !upToDate
        setStatus(.checking(app: name, underlines: underlinesWork))
    }

    private func focusProblem(app: String, pid: pid_t) -> CheckStatus {
        guard let element = FocusedField.focusedElement() else { return .unreadable(app: app, pid: pid) }
        return FocusedField.isSecure(element) ? .passwordField : .noField(app: app)
    }

    private static func commonPrefixLength(_ a: String, _ b: String) -> Int {
        zip(a.utf16, b.utf16).prefix { $0 == $1 }.count
    }

    private func underlines(in field: FocusedField, for candidates: [SpellIssue]) -> [Underline] {
        let key = "\(field.frame)|\(candidates.map(\.id))|\(Int(Date().timeIntervalSince1970 / 2))"
        guard key != underlineKey else { return drawnUnderlines }
        underlineKey = key
        // A long document can have more issues than are worth placing; the ones around the caret come first.
        let caret = field.caret ?? 0
        let shown = candidates.count <= 40
            ? candidates : Array(candidates.sorted { abs($0.start - caret) < abs($1.start - caret) }.prefix(40))
        let rects = field.wordRects(for: shown.map(\.range))
        return zip(shown, rects).compactMap { issue, rect in
            guard let rect, field.frame.insetBy(dx: -2, dy: -2).contains(CGPoint(x: rect.midX, y: rect.midY)) else { return nil }
            return Underline(issueID: issue.id, rect: rect, isSpelling: issue.kind == "Spelling")
        }
    }

    private func exposeWebContent(of pid: pid_t) {
        guard Date().timeIntervalSince(lastExposed[pid] ?? .distantPast) > 2 else { return }
        lastExposed[pid] = Date()
        FocusedField.exposeWebContent(of: pid)
    }

    private func lint(_ text: String) {
        guard !isLinting else { return }
        isLinting = true
        let dialect = dialect
        let generation = lintGeneration
        Task {
            let spelling = spellingIssues(in: text, dialect: dialect)
            let found = Self.merge(spelling: spelling, grammar: await engine.lint(text))
                .filter { !Self.isInCode($0.range, of: text as NSString) }
            isLinting = false
            let current = generation == lintGeneration
            if current {
                lintedText = text
                rawIssues = found
                refreshVisibleIssues()
                lookUpSuggestions()
            }
            if let latest = field?.text, !current || latest != text { lint(latest) }
        }
    }

    private func spellingIssues(in text: String, dialect: EnglishDialect) -> [SpellIssue] {
        let ns = text as NSString
        return MacSpelling.misspellings(in: text, dialect: dialect).map { range in
            let word = ns.substring(with: range)
            let cached = suggestionCache[word]
            return SpellIssue(
                start: range.location,
                end: NSMaxRange(range),
                kind: "Spelling",
                message: "\u{201C}\(word)\u{201D} may be misspelled.",
                suggestions: cached?.suggestions ?? [],
                best: cached?.best
            )
        }
    }

    /// Fills in suggestions for new misspelled words, nearest the caret first, pausing between words so
    /// a long pasted document never stalls the app.
    private func lookUpSuggestions() {
        suggesting?.cancel()
        let text = lintedText
        let ns = text as NSString
        let caret = field?.caret ?? 0
        var seen = Set<String>()
        let missing = rawIssues
            .filter { $0.kind == "Spelling" && suggestionCache[ns.substring(with: $0.range)] == nil }
            .sorted { abs($0.start - caret) < abs($1.start - caret) }
            .filter { seen.insert(ns.substring(with: $0.range)).inserted }
        guard !missing.isEmpty else { return }
        let dialect = dialect
        suggesting = Task {
            for (index, issue) in missing.enumerated() {
                guard !Task.isCancelled, lintedText == text else { return }
                cacheSuggestions(for: issue, in: text, dialect: dialect)
                if index % 8 == 7 { applyCachedSuggestions() }
                try? await Task.sleep(for: .milliseconds(5))
            }
            applyCachedSuggestions()
        }
    }

    private func cacheSuggestions(for issue: SpellIssue, in text: String, dialect: EnglishDialect) {
        let word = (text as NSString).substring(with: issue.range)
        guard suggestionCache[word] == nil else { return }
        if suggestionCache.count > 2000 { suggestionCache = [:] }
        suggestionCache[word] = MacSpelling.suggestions(for: issue.range, in: text, dialect: dialect)
    }

    private func applyCachedSuggestions() {
        let ns = lintedText as NSString
        rawIssues = rawIssues.map { issue in
            guard issue.kind == "Spelling", issue.best == nil, issue.suggestions.isEmpty, NSMaxRange(issue.range) <= ns.length,
                  let cached = suggestionCache[ns.substring(with: issue.range)]
            else { return issue }
            var filled = issue
            filled.suggestions = cached.suggestions
            filled.best = cached.best
            return filled
        }
        refreshVisibleIssues()
    }

    /// Makes sure an issue that's about to be shown has its suggestions, looking them up now if needed.
    func withSuggestions(_ issue: SpellIssue) -> SpellIssue {
        guard issue.kind == "Spelling", issue.suggestions.isEmpty, issue.best == nil, lintedText == issuesText else { return issue }
        cacheSuggestions(for: issue, in: lintedText, dialect: dialect)
        applyCachedSuggestions()
        return issues.first { $0.id == issue.id } ?? issue
    }

    /// Paths, file names, identifiers, handles and links ("sandbox/samir/", "bench500.xlsx",
    /// "pe-6109-bse-cost", "camelCase") aren't prose, so nothing inside one is flagged.
    static func isInCode(_ range: NSRange, of text: NSString) -> Bool {
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FFFC}"))
        func isSeparator(_ index: Int) -> Bool {
            UnicodeScalar(text.character(at: index)).map(separators.contains) ?? false
        }
        var start = range.location
        var end = NSMaxRange(range)
        guard end <= text.length else { return false }
        while start > 0, !isSeparator(start - 1) { start -= 1 }
        while end < text.length, !isSeparator(end) { end += 1 }
        let token = text.substring(with: NSRange(location: start, length: end - start))
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'\u{201C}\u{201D}\u{2018}\u{2019}()[]<>,;:!?*.…"))
        guard !token.isEmpty, NSMaxRange(range) <= end else { return false }
        if token.contains(where: { "/\\_@#`=|~{}$%^&+".contains($0) }) { return true }
        let scalars = Array(token.unicodeScalars)
        let hasLetter = scalars.contains { CharacterSet.letters.contains($0) }
        let hasDigit = scalars.contains { CharacterSet.decimalDigits.contains($0) }
        if hasLetter, hasDigit { return true }
        // A dot between letters: a file name or domain ("bench500.xlsx", "linear.app").
        if token.range(of: #"[A-Za-z0-9]\.[A-Za-z0-9]"#, options: .regularExpression) != nil { return true }
        // A capital after a lowercase letter: camelCase or a product name ("bseClassifier", "macOS").
        return token.range(of: #"[a-z][A-Z]"#, options: .regularExpression) != nil
    }

    private static func merge(spelling: [SpellIssue], grammar: [SpellIssue]) -> [SpellIssue] {
        let grammarOnly = grammar.filter { issue in
            issue.kind != "Spelling" && !spelling.contains { $0.start < issue.end && issue.start < $0.end }
        }
        return (spelling + grammarOnly).sorted { $0.start < $1.start }
    }

    private func recheck() {
        suggesting?.cancel()
        field = nil
        underlineKey = ""
        lintGeneration += 1
    }

    private func refreshVisibleIssues() {
        guard let field, field.text == lintedText else { return }
        issuesText = lintedText
        let visible = rawIssues.filter { !isBeingTyped($0, caret: field.caret) && !ignored.contains(ignoreKey($0)) }
        if visible != issues { issues = visible }
    }

    private func isBeingTyped(_ issue: SpellIssue, caret: Int?) -> Bool {
        guard let caret, issue.end == caret, issue.kind == "Spelling" else { return false }
        return Date().timeIntervalSince(lastKeystrokeAt) < CheckingTiming.typingPause.current
    }

    private func setStatus(_ newStatus: CheckStatus) {
        if status != newStatus { status = newStatus }
    }

    private func clear(_ newStatus: CheckStatus) {
        setStatus(newStatus)
        field = nil
        drawnUnderlines = []
        underlineKey = ""
        if !issues.isEmpty { issues = [] }
        issuesText = ""
        overlay.hide()
    }

    private func logFocusChange(_ app: NSRunningApplication) {
        let description = "\(app.bundleIdentifier ?? "?") \(FocusedField.describeFocus())"
        guard description != lastFocusDescription else { return }
        lastFocusDescription = description
        AppLog.write("focus: \(description)")
    }
}

enum AppLog {
    static let file = PythonEngine.logs.appendingPathComponent("app.log")
    private static let maxBytes: UInt64 = 1_000_000

    static func write(_ message: String) {
        if let size = try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? UInt64, size > maxBytes {
            try? FileManager.default.removeItem(at: file)
        }
        let line = "\(Date().formatted(date: .omitted, time: .standard)) \(message)\n"
        if let handle = try? FileHandle(forWritingTo: file) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? line.write(to: file, atomically: true, encoding: .utf8)
        }
    }
}
