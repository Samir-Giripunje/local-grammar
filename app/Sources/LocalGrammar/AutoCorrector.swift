import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Corrects confident misspellings as you type, in any app.
///
/// A keyboard event tap tracks the word being typed. When a word ends (space or punctuation) and macOS's
/// autocorrection has a confident fix, the ending key is held back, the differing letters are retyped, and
/// the ending key is replayed. Pressing Delete right after restores the original word and remembers it as an
/// exception. Typing is synthesized with key events, so the clipboard is never touched.
@MainActor
final class AutoCorrector: ObservableObject {
    struct Correction: Identifiable {
        let id = UUID()
        let original: String
        let corrected: String
        let app: String
        let date: Date
        fileprivate let terminator: String
    }

    @Published var isEnabled = UserDefaults.standard.object(forKey: "autocorrect") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: "autocorrect")
            reset()
        }
    }
    @Published private(set) var exceptions = UserDefaults.standard.stringArray(forKey: "autocorrectExceptions") ?? []
    @Published private(set) var recent: [Correction] = []

    /// Apps where autocorrect would mangle commands or code.
    static let skippedApps: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.mitchellh.ghostty",
        "net.kovidgoyal.kitty", "io.alacritty", "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92",
        "dev.zed.Zed", "com.apple.dt.Xcode", "com.sublimetext.4", "com.1password.1password",
        "com.apple.keychainaccess",
    ]

    private static let syntheticMarker: Int64 = 0x4C47_4143
    private static let terminators: Set<Character> = [" ", ".", ",", "!", "?", ";", ":", ")"]

    private let spell: SpellWatcher
    private var tap: CFMachPort?
    private var word = ""
    private var last: Correction?
    private var retry: Timer?

    init(spell: SpellWatcher) {
        self.spell = spell
    }

    var isRunning: Bool { tap != nil }

    func start() {
        guard tap == nil else { return }
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.rightMouseDown.rawValue)
        tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { proxy, type, event, info in
                let corrector = Unmanaged<AutoCorrector>.fromOpaque(info!).takeUnretainedValue()
                return MainActor.assumeIsolated { corrector.handle(type, event, proxy: proxy) }
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )
        guard let tap else {
            // No Accessibility permission yet; try again until it's granted.
            retry = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in
                Task { @MainActor in self?.start() }
            }
            return
        }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func removeException(_ word: String) {
        exceptions.removeAll { $0 == word }
        UserDefaults.standard.set(exceptions, forKey: "autocorrectExceptions")
    }

    private func addException(_ word: String) {
        guard !exceptions.contains(where: { $0.caseInsensitiveCompare(word) == .orderedSame }) else { return }
        exceptions.insert(word.lowercased(), at: 0)
        UserDefaults.standard.set(exceptions, forKey: "autocorrectExceptions")
    }

    private func reset() {
        word = ""
        last = nil
    }

    // MARK: - Event handling

    private func handle(_ type: CGEventType, _ event: CGEvent, proxy: CGEventTapProxy) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass
        case .keyDown:
            break
        default:
            reset()
            return pass
        }
        guard event.getIntegerValueField(.eventSourceUserData) != Self.syntheticMarker else { return pass }
        guard isEnabled else { return pass }

        let flags = event.flags
        if !flags.intersection([.maskCommand, .maskControl, .maskAlternate]).isEmpty {
            reset()
            return pass
        }
        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        if keyCode == kVK_Delete {
            if let last, revert(last, proxy: proxy) { return nil }
            last = nil
            if !word.isEmpty { word.removeLast() }
            return pass
        }

        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        event.keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &length, unicodeString: &chars)
        guard length == 1, let scalar = Unicode.Scalar(chars[0]) else {
            reset()
            return pass
        }
        let character = Character(scalar)
        if character.isASCII, character.isLetter || (character == "'" && !word.isEmpty) {
            word.append(character)
            last = nil
            return pass
        }
        defer { word = "" }
        last = nil
        guard Self.terminators.contains(character), let fix = correction(for: word) else { return pass }
        apply(fix, terminator: String(character), proxy: proxy)
        return nil
    }

    // MARK: - Deciding

    private func correction(for typed: String) -> String? {
        guard typed.count >= 2, typed.count <= 30,
              !typed.allSatisfy(\.isUppercase),
              !typed.dropFirst().contains(where: \.isUppercase),
              !exceptions.contains(where: { $0.caseInsensitiveCompare(typed) == .orderedSame }),
              let app = NSWorkspace.shared.frontmostApplication, let bundleID = app.bundleIdentifier,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              !Self.skippedApps.contains(bundleID), !spell.disabledApps.contains(bundleID)
        else { return nil }

        let checker = NSSpellChecker.shared
        let language = spell.dialect.spellLanguage
        let misspelled = checker.checkSpelling(
            of: typed, startingAt: 0, language: language, wrap: false, inSpellDocumentWithTag: 0, wordCount: nil
        )
        guard misspelled.location != NSNotFound, let context = textBeforeCaret(endingWith: typed) else { return nil }

        // Judged in its sentence: a bare word gets suggestions biased towards the autocorrection itself.
        let length = (typed as NSString).length
        let range = NSRange(location: (context as NSString).length - length, length: length)
        guard var fix = checker.correction(forWordRange: range, in: context, language: language, inSpellDocumentWithTag: 0),
              fix != typed, fix.allSatisfy({ $0.isASCII })
        else { return nil }
        // Only unambiguous typos: swapped neighbouring letters ("teh", "recieve"), a missing apostrophe or space
        // ("dont", "alot"), or a fix no other suggestion is as close to ("tommorow"). "wat" could be was, cat or
        // way and "adress" could be "a dress", so those keep their underline instead.
        let letters = { (word: String) in word.lowercased().filter(\.isLetter) }
        let suggestions = (checker.guesses(forWordRange: range, in: context, language: language, inSpellDocumentWithTag: 0) ?? [])
            + (checker.guesses(
                forWordRange: NSRange(location: 0, length: length), in: typed, language: language, inSpellDocumentWithTag: 0
            ) ?? [])
        let distance = Self.editDistance(typed, fix)
        let rivals = suggestions.filter { $0.lowercased() != fix.lowercased() && Self.editDistance(typed, $0) <= distance }
        guard letters(fix) == letters(typed) || Self.isSwap(typed, fix) || rivals.isEmpty else { return nil }
        if typed.first?.isUppercase == true { fix = fix.prefix(1).uppercased() + fix.dropFirst() }
        return fix
    }

    /// Typing distance: insertions, deletions, substitutions and swapped neighbours each count as one.
    private static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a.lowercased())
        let b = Array(b.lowercased())
        guard !a.isEmpty, !b.isEmpty else { return max(a.count, b.count) }
        var d = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in 0...a.count { d[i][0] = i }
        for j in 0...b.count { d[0][j] = j }
        for i in 1...a.count {
            for j in 1...b.count {
                d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] {
                    d[i][j] = min(d[i][j], d[i - 2][j - 2] + 1)
                }
            }
        }
        return d[a.count][b.count]
    }

    /// Whether `fix` is `typed` with two neighbouring letters swapped back.
    private static func isSwap(_ typed: String, _ fix: String) -> Bool {
        let a = Array(typed.lowercased())
        let b = Array(fix.lowercased())
        guard a.count == b.count else { return false }
        let differing = a.indices.filter { a[$0] != b[$0] }
        guard differing.count == 2, differing[1] == differing[0] + 1 else { return false }
        return a[differing[0]] == b[differing[1]] && a[differing[1]] == b[differing[0]]
    }

    /// The text before the caret, when the focused field really has `typed` right there as its own word and
    /// not inside a URL, @mention, #channel, path or `code`. The tracked keystrokes alone can't see clicks or
    /// pastes, so the field itself is checked.
    private func textBeforeCaret(endingWith typed: String) -> String? {
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, 0.1)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let element = focused, CFGetTypeID(element) == AXUIElementGetTypeID()
        else { return nil }
        let field = element as! AXUIElement
        AXUIElementSetMessagingTimeout(field, 0.1)
        guard !FocusedField.isSecure(field), let caret = Self.caret(of: field) else { return nil }

        let lookback = (typed as NSString).length + 40
        let start = max(0, caret - lookback)
        guard let before = Self.string(of: field, in: NSRange(location: start, length: caret - start)),
              before.hasSuffix(typed)
        else { return nil }
        let prefix = before.dropLast(typed.count)
        if let previous = prefix.last, !(previous.isWhitespace || "([{\"'“‘".contains(previous)) { return nil }
        let token = prefix.split(whereSeparator: \.isWhitespace).last.map(String.init) ?? ""
        if token.contains("://") || token.hasPrefix("www.") { return nil }
        return prefix.filter { $0 == "`" }.count.isMultiple(of: 2) ? before : nil
    }

    private static func caret(of field: AXUIElement) -> Int? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(field, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range), range.length == 0 else { return nil }
        return range.location
    }

    /// Text in selection counting (the caret's counting), falling back to the field's value for apps
    /// without `AXStringForRange`.
    private static func string(of field: AXUIElement, in range: NSRange) -> String? {
        var cfRange = CFRange(location: range.location, length: range.length)
        var result: CFTypeRef?
        if let rangeValue = AXValueCreate(.cfRange, &cfRange),
           AXUIElementCopyParameterizedAttributeValue(
               field, kAXStringForRangeParameterizedAttribute as CFString, rangeValue, &result
           ) == .success, let text = result as? String {
            return text
        }
        guard AXUIElementCopyAttributeValue(field, kAXValueAttribute as CFString, &result) == .success,
              let value = result as? String, NSMaxRange(range) <= (value as NSString).length
        else { return nil }
        return (value as NSString).substring(with: range)
    }

    // MARK: - Typing

    private func apply(_ fix: String, terminator: String, proxy: CGEventTapProxy) {
        let shared = word.commonPrefix(with: fix).count
        post(deleting: word.count - shared, typing: String(fix.dropFirst(shared)) + terminator, proxy: proxy)
        let app = NSWorkspace.shared.frontmostApplication?.localizedName ?? "app"
        let correction = Correction(original: word, corrected: fix, app: app, date: Date(), terminator: terminator)
        last = correction
        recent.insert(correction, at: 0)
        if recent.count > 30 { recent.removeLast() }
        AppLog.write("autocorrected a word in \(app)")
    }

    /// Delete right after an autocorrection: put the original word back (without the ending key, which the
    /// Delete was meant to remove) and never autocorrect that word again.
    private func revert(_ correction: Correction, proxy: CGEventTapProxy) -> Bool {
        last = nil
        let shared = correction.original.commonPrefix(with: correction.corrected).count
        post(
            deleting: correction.corrected.count - shared + correction.terminator.count,
            typing: String(correction.original.dropFirst(shared)),
            proxy: proxy
        )
        word = correction.original
        addException(correction.original)
        recent.removeAll { $0.id == correction.id }
        AppLog.write("autocorrect undone with Delete")
        return true
    }

    private func post(deleting count: Int, typing text: String, proxy: CGEventTapProxy) {
        let source = CGEventSource(stateID: .privateState)
        func send(_ event: CGEvent?) {
            guard let event else { return }
            event.flags = []
            event.setIntegerValueField(.eventSourceUserData, value: Self.syntheticMarker)
            event.tapPostEvent(proxy)
        }
        for _ in 0..<count {
            send(CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Delete), keyDown: true))
            send(CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Delete), keyDown: false))
        }
        let units = Array(text.utf16)
        for start in stride(from: 0, to: units.count, by: 16) {
            var chunk = Array(units[start..<min(start + 16, units.count)])
            for isDown in [true, false] {
                let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: isDown)
                event?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
                send(event)
            }
        }
    }
}
