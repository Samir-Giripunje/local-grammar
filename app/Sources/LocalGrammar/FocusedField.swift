import AppKit
import ApplicationServices

struct FocusedField {
    let element: AXUIElement
    let role: String
    let text: String
    let caret: Int?
    let frame: CGRect

    static func current() -> FocusedField? {
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, 0.25)
        guard let element: AXUIElement = attribute(systemWide, kAXFocusedUIElementAttribute),
              let role: String = attribute(element, kAXRoleAttribute),
              isEditable(element, role: role),
              let text: String = attribute(element, kAXValueAttribute),
              let frame = screenFrame(of: element)
        else { return nil }
        let selection = selectedRange(of: element)
        let caret = selection.map { $0.length == 0 ? $0.location : nil } ?? nil
        return FocusedField(element: element, role: role, text: text, caret: caret, frame: frame)
    }

    static func describeFocus() -> String {
        let systemWide = AXUIElementCreateSystemWide()
        guard let element: AXUIElement = attribute(systemWide, kAXFocusedUIElementAttribute) else {
            return "no focused element"
        }
        let role: String = attribute(element, kAXRoleAttribute) ?? "?"
        let subrole: String = attribute(element, kAXSubroleAttribute) ?? "-"
        var settable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
        return "role=\(role) subrole=\(subrole) valueSettable=\(settable.boolValue)"
    }

    static func exposeWebContent(of pid: pid_t) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    static func focusedElement() -> AXUIElement? {
        attribute(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute)
    }

    func isStillFocused() -> Bool {
        Self.focusedElement().map { CFEqual($0, element) } ?? false
    }

    func select(_ range: NSRange, of value: String) async -> Bool {
        await Self.select(range, of: value, in: element)
    }

    /// Selects `range` of the field's `value` and confirms the selected text is that exact text.
    /// Chromium (Slack, T3 Code, browsers) counts paragraph breaks and emoji differently in selection
    /// ranges than in the field's value, while still reporting back the range it was given, so the
    /// range alone can't be trusted. When the direct attempt selects other text, the same occurrence
    /// of the text is located in Chromium's own counting and selected there instead.
    static func select(_ range: NSRange, of value: String, in element: AXUIElement) async -> Bool {
        let text = value as NSString
        guard range.length > 0, NSMaxRange(range) <= text.length else { return false }
        let expected = text.substring(with: range)
        if await trySelect(range, expecting: expected, in: element) { return true }
        guard let selectionText = selectionSpaceText(of: element, around: text.length),
              let mapped = mapOccurrence(range, from: value, to: selectionText),
              mapped != range
        else { return false }
        return await trySelect(mapped, expecting: expected, in: element)
    }

    private static func trySelect(_ range: NSRange, expecting expected: String, in element: AXUIElement) async -> Bool {
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let value = AXValueCreate(.cfRange, &cfRange),
              AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value) == .success
        else { return false }
        func selectedExpected() -> Bool {
            guard selectedRange(of: element) == range else { return false }
            let selected: String? = attribute(element, kAXSelectedTextAttribute)
            if let selected, !selected.isEmpty { return selected == expected }
            // Chromium can report "" right after a selection is set: read the text at the range instead.
            guard let atRange = string(of: element, in: range) else { return selected == nil }
            return atRange == expected
        }
        for _ in 0..<30 where !selectedExpected() {
            try? await Task.sleep(for: .milliseconds(20))
        }
        return selectedExpected()
    }

    /// Text at `range` in selection counting, through `AXStringForRange`.
    private static func string(of element: AXUIElement, in range: NSRange) -> String? {
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let rangeValue = AXValueCreate(.cfRange, &cfRange) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXStringForRangeParameterizedAttribute as CFString, rangeValue, &value
        ) == .success else { return nil }
        return value as? String
    }

    /// The field's text as counted by selection ranges, read through `AXStringForRange`.
    fileprivate static func selectionSpaceText(of element: AXUIElement, around length: Int) -> String? {
        let prefix = { (length: Int) in string(of: element, in: NSRange(location: 0, length: length)) }
        var low = 0
        var high = length + 64
        while low < high {
            let mid = (low + high + 1) / 2
            if prefix(mid) != nil { low = mid } else { high = mid - 1 }
        }
        return low > 0 ? prefix(low) : nil
    }

    /// Maps `range` to the same occurrence of its text (e.g. the second "teh") in another counting of
    /// the field. Gives up when the two countings don't contain the text the same number of times.
    fileprivate static func mapOccurrence(_ range: NSRange, from source: String, to target: String) -> NSRange? {
        let from = source as NSString
        let to = target as NSString
        guard range.length > 0, NSMaxRange(range) <= from.length else { return nil }
        let needle = from.substring(with: range)
        let inSource = occurrences(of: needle, in: from)
        let inTarget = occurrences(of: needle, in: to)
        guard inSource.count == inTarget.count, let index = inSource.firstIndex(of: range.location) else { return nil }
        return NSRange(location: inTarget[index], length: range.length)
    }

    private static func occurrences(of needle: String, in text: NSString) -> [Int] {
        var found: [Int] = []
        var from = 0
        while from < text.length {
            let match = text.range(of: needle, options: .literal, range: NSRange(location: from, length: text.length - from))
            guard match.location != NSNotFound else { break }
            found.append(match.location)
            from = match.location + 1
        }
        return found
    }

    func wordRects(for ranges: [NSRange]) -> [CGRect?] {
        var markers: TextMarkerBounds?
        var useMarkers = false
        var runs: [TextRun]?
        return ranges.map { range in
            if !useMarkers, let rect = boundsByRange(range).map(Self.toCocoa), isWordSized(rect) { return rect }
            if runs == nil { runs = textRuns() }
            if let run = Self.run(containing: range, in: runs ?? []) {
                // The run knows where its text is; when it can't place it, stepping through markers won't either.
                guard let rect = bounds(of: range, in: run).map(Self.toCocoa), isWordSized(rect) else { return nil }
                return rect
            }
            useMarkers = true
            if markers == nil { markers = TextMarkerBounds(element: element) }
            let word = (text as NSString).substring(with: range)
            guard let rect = markers?.bounds(of: range, expecting: word).map(Self.toCocoa), isWordSized(rect) else {
                return nil
            }
            return rect
        }
    }

    private struct TextRun {
        let element: AXUIElement
        let start: Int
        let length: Int
    }

    /// The last field's text runs: walking a long document's tree takes ~30 ms, and only edits change it.
    nonisolated(unsafe) private static var runCache: (element: AXUIElement, text: String, runs: [TextRun])?

    private func textRuns() -> [TextRun] {
        if let cached = Self.runCache, cached.text == text, CFEqual(cached.element, element) { return cached.runs }
        let fullText = text as NSString
        var runs: [TextRun] = []
        var cursor = 0
        func visit(_ parent: AXUIElement, depth: Int) {
            guard depth < 8, runs.count < 2000 else { return }
            let children: [AXUIElement] = Self.attribute(parent, kAXChildrenAttribute) ?? []
            for child in children {
                let role: String? = Self.attribute(child, kAXRoleAttribute)
                guard role == "AXStaticText", let value: String = Self.attribute(child, kAXValueAttribute), !value.isEmpty
                else {
                    visit(child, depth: depth + 1)
                    continue
                }
                guard let (run, end) = Self.locate(value, of: child, in: fullText, from: cursor) else { continue }
                runs.append(run)
                cursor = end
            }
        }
        visit(element, depth: 0)
        Self.runCache = (element, text, runs)
        return runs
    }

    /// Finds a run's text just after the previous one. Chromium leaves out spaces next to inline elements
    /// (" and " after a `code` span reads "and "), so the text is also looked for without its edge spaces.
    /// Short runs ("." or "2") are only looked for nearby, so they can't jump ahead and misplace every run
    /// after them; longer ones may skip a gap (text with no runs of its own, like an embed).
    private static func locate(_ value: String, of element: AXUIElement, in text: NSString, from cursor: Int) -> (TextRun, end: Int)? {
        let length = (value as NSString).length
        let window = NSRange(location: cursor, length: min(text.length - cursor, length + 64))
        let exact = text.range(of: value, options: .literal, range: window)
        if exact.location != NSNotFound {
            return (TextRun(element: element, start: exact.location, length: length), NSMaxRange(exact))
        }
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        var found = text.range(of: trimmed, options: .literal, range: window)
        if found.location == NSNotFound, (trimmed as NSString).length >= 12 {
            found = text.range(of: trimmed, options: .literal, range: NSRange(location: cursor, length: text.length - cursor))
        }
        guard found.location != NSNotFound else { return nil }
        let leading = (value as NSString).range(of: trimmed, options: .literal).location
        // Offsets into the run still count its own leading spaces.
        return (TextRun(element: element, start: found.location - leading, length: length), NSMaxRange(found))
    }

    private static func run(containing range: NSRange, in runs: [TextRun]) -> TextRun? {
        runs.first { $0.start <= range.location && NSMaxRange(range) <= $0.start + $0.length }
    }

    private func bounds(of range: NSRange, in run: TextRun) -> CGRect? {
        var local = CFRange(location: range.location - run.start, length: range.length)
        var value: CFTypeRef?
        guard let rangeValue = AXValueCreate(.cfRange, &local),
              AXUIElementCopyParameterizedAttributeValue(
                  run.element, kAXBoundsForRangeParameterizedAttribute as CFString, rangeValue, &value
              ) == .success
        else { return nil }
        return Self.rect(from: value)
    }

    private func isWordSized(_ rect: CGRect) -> Bool {
        let fillsField = rect.width >= frame.width * 0.95 && rect.height >= frame.height * 0.8
        return rect.height <= 60 && !fillsField
    }

    private func boundsByRange(_ range: NSRange) -> CGRect? {
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let rangeValue = AXValueCreate(.cfRange, &cfRange) else { return nil }
        return Self.rect(from: parameterized(kAXBoundsForRangeParameterizedAttribute, rangeValue))
    }

    private func parameterized(_ attribute: String, _ parameter: CFTypeRef) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, attribute as CFString, parameter, &value) == .success
        else { return nil }
        return value
    }

    private static func rect(from value: CFTypeRef?) -> CGRect? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(value as! AXValue, .cgRect, &rect), rect.width > 0, rect.height > 0 else { return nil }
        return rect
    }

    func currentText() -> String? {
        Self.attribute(element, kAXValueAttribute)
    }

    static func isSecure(_ element: AXUIElement) -> Bool {
        let role: String? = attribute(element, kAXRoleAttribute)
        let subrole: String? = attribute(element, kAXSubroleAttribute)
        if role == "AXSecureTextField" || subrole == "AXSecureTextField" { return true }
        let description = (attribute(element, kAXRoleDescriptionAttribute) as String?)?.lowercased() ?? ""
        return description.contains("secure") || description.contains("password")
    }

    private static func isEditable(_ element: AXUIElement, role: String) -> Bool {
        if isSecure(element) { return false }
        if ["AXTextArea", "AXTextField", "AXComboBox"].contains(role) { return true }
        var settable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
        return settable.boolValue
    }

    fileprivate static func selectedRange(of element: AXUIElement) -> NSRange? {
        guard let value: AXValue = attribute(element, kAXSelectedTextRangeAttribute) else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value, .cfRange, &range) else { return nil }
        return NSRange(location: range.location, length: range.length)
    }

    /// The frame of the window holding `element`.
    static func windowFrame(of element: AXUIElement) -> CGRect? {
        guard let window: AXUIElement = attribute(element, kAXWindowAttribute) else { return nil }
        return screenFrame(of: window)
    }

    private static func screenFrame(of element: AXUIElement) -> CGRect? {
        guard let positionValue: AXValue = attribute(element, kAXPositionAttribute),
              let sizeValue: AXValue = attribute(element, kAXSizeAttribute)
        else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(positionValue, .cgPoint, &position)
        AXValueGetValue(sizeValue, .cgSize, &size)
        return toCocoa(CGRect(origin: position, size: size))
    }

    private static func toCocoa(_ rect: CGRect) -> CGRect {
        let primary = NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.screens.first
        let primaryHeight = primary?.frame.maxY ?? 0
        return CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    fileprivate static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }
}

struct SelectionContext {
    let element: AXUIElement
    let range: NSRange
    let selectedText: String?

    static func capture() -> SelectionContext? {
        guard let element = FocusedField.focusedElement(),
              let range = FocusedField.selectedRange(of: element)
        else { return nil }
        let text: String? = FocusedField.attribute(element, kAXSelectedTextAttribute)
        return SelectionContext(element: element, range: range, selectedText: text)
    }

    func currentValue() -> String? {
        FocusedField.attribute(element, kAXValueAttribute)
    }

    /// Makes sure the original text is selected again and returns the field's value, plus the original's
    /// range in that value when it can be worked out. `range` was captured in selection counting, which
    /// differs from the value's in Chromium (paragraph breaks), so a still-intact selection is trusted as is.
    func reselect(original: String) async -> (value: String, range: NSRange?)? {
        guard let focused = FocusedField.focusedElement(), CFEqual(focused, element),
              let value = currentValue()
        else { return nil }
        let text = value as NSString
        var valueRange: NSRange?
        if NSMaxRange(range) <= text.length, text.substring(with: range) == original {
            valueRange = range
        } else if let selectionText = FocusedField.selectionSpaceText(of: element, around: text.length),
                  NSMaxRange(range) <= (selectionText as NSString).length,
                  (selectionText as NSString).substring(with: range) == original {
            valueRange = FocusedField.mapOccurrence(range, from: selectionText, to: value)
        }
        let stillSelected = FocusedField.selectedRange(of: element) == range
            && FocusedField.attribute(element, kAXSelectedTextAttribute) as String? == original
        if stillSelected { return (value, valueRange) }
        guard let valueRange, await FocusedField.select(valueRange, of: value, in: element) else { return nil }
        return (value, valueRange)
    }
}
