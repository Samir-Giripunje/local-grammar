import AppKit
import Carbon.HIToolbox

@MainActor
enum Selection {
    private static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    private static var queue: Task<Void, Never>?

    struct Copied {
        let text: String
        let html: String?
    }

    static func copy() async -> Copied? {
        await serialized {
            await waitForModifierRelease()
            let pasteboard = NSPasteboard.general
            let saved = snapshot(pasteboard)
            let before = pasteboard.changeCount
            press(kVK_ANSI_C)
            for _ in 0..<25 where pasteboard.changeCount == before {
                try? await Task.sleep(for: .milliseconds(20))
            }
            guard pasteboard.changeCount > before else { return nil }
            let text = pasteboard.string(forType: .string)
            let html = pasteboard.string(forType: .html)
            restore(saved, to: pasteboard, ifStill: pasteboard.changeCount)
            guard let text, !text.isEmpty else { return nil }
            return Copied(text: text, html: html)
        }
    }

    @discardableResult
    static func paste(
        _ text: String, html: String? = nil, landed: @escaping @MainActor () -> Bool = { false }
    ) async -> Bool {
        await serialized {
            await waitForModifierRelease()
            let pasteboard = NSPasteboard.general
            let saved = snapshot(pasteboard)
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            if let html { pasteboard.setString(html, forType: .html) }
            pasteboard.setString("", forType: transientType)
            let ours = pasteboard.changeCount
            // Something else wrote the clipboard in between: pasting now would insert its content instead.
            guard pasteboard.changeCount == ours, pasteboard.string(forType: .string) == text else { return false }
            press(kVK_ANSI_V)
            try? await Task.sleep(for: .milliseconds(150))
            var success = landed()
            for _ in 0..<40 where !success {
                try? await Task.sleep(for: .milliseconds(50))
                success = landed()
            }
            restore(saved, to: pasteboard, ifStill: ours)
            return success
        }
    }

    static func delete(landed: @escaping @MainActor () -> Bool) async -> Bool {
        await serialized {
            press(kVK_Delete, flags: [])
            for _ in 0..<20 where !landed() {
                try? await Task.sleep(for: .milliseconds(50))
            }
            return landed()
        }
    }

    static func copyToClipboard(_ text: String, html: String? = nil) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        if let html { pasteboard.setString(html, forType: .html) }
    }

    private static func serialized<T>(_ operation: @escaping @MainActor () async -> T) async -> T {
        let previous = queue
        let task = Task { @MainActor in
            await previous?.value
            return await operation()
        }
        queue = Task { _ = await task.value }
        return await task.value
    }

    private static func press(_ key: Int, flags: CGEventFlags = .maskCommand) {
        let source = CGEventSource(stateID: .combinedSessionState)
        for isDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(key), keyDown: isDown)
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
        }
    }

    private static func waitForModifierRelease() async {
        let held: CGEventFlags = [.maskCommand, .maskAlternate, .maskShift, .maskControl]
        for _ in 0..<50 where !CGEventSource.flagsState(.combinedSessionState).intersection(held).isEmpty {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    private static func snapshot(_ pasteboard: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (pasteboard.pasteboardItems ?? []).map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in item.data(forType: type).map { (type, $0) } })
        }
    }

    private static func restore(
        _ items: [[NSPasteboard.PasteboardType: Data]], to pasteboard: NSPasteboard, ifStill changeCount: Int
    ) {
        guard pasteboard.changeCount == changeCount else { return }
        pasteboard.clearContents()
        let restored = items.map { entries in
            let item = NSPasteboardItem()
            entries.forEach { item.setData($0.value, forType: $0.key) }
            return item
        }
        pasteboard.writeObjects(restored)
    }
}
