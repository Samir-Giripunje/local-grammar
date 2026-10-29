import Foundation

/// Keeps a model's correction from breaking Markdown: code and links are swapped for placeholders the
/// model must copy, and if the corrected text's layout or markers changed, it's corrected line by line
/// with list markers and formatted words held back. The same rules as the Qwen engine's `corrector.py`.
enum MarkdownGuard {
    struct Unusable: Error {}

    private static func regex(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: options)
    }

    private static let fencedCode = regex("```.*?```", .dotMatchesLineSeparators)
    private static let inlineCode = regex("`[^`\\n]+`")
    private static let linkTarget = regex(#"(?<=\]\()[^)\s]+(?=\))|\bhttps?://\S+|\bwww\.\S+"#)
    private static let emphasisSpan = regex(
        #"\*\*[^*\n]+\*\*|__[^_\n]+__|~~[^~\n]+~~|(?<![\w*])\*[^*\n]+\*(?![\w*])|(?<![\w_])_[^_\n]+_(?![\w_])"#
    )
    private static let emphasisMark = regex(#"\*\*|__|~~|(?<![\w*])[*_](?=\S)|(?<=\S)[*_](?![\w*])"#)
    private static let lineMarkers = regex(#"^(\s*(?:[-*+•]\s+|\d+[.)]\s+|>\s?|#{1,6}\s+)*)"#)
    private static let placeholder = regex("⟦\\d+⟧")
    private static let twoLetters = regex("[A-Za-z]{2}")

    /// Corrects `text` with `generate`, keeping its structure when `keepStructure` is on.
    static func correct(
        _ text: String, keepStructure: Bool, generate: (String) async throws -> String
    ) async throws -> String {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return text }
        guard keepStructure else { return try await generate(text) }
        let (masked, saved) = protect(text, [fencedCode, inlineCode, linkTarget])
        let whole = try await generate(masked)
        if structure(whole) == structure(masked), let restored = restore(whole, saved) {
            return restored
        }
        var lines: [String] = []
        for line in masked.components(separatedBy: "\n") {
            try Task.checkCancellation()
            lines.append(await correctLine(line, generate: generate))
        }
        return restore(lines.joined(separator: "\n"), saved) ?? text
    }

    private static func correctLine(_ line: String, generate: (String) async throws -> String) async -> String {
        let markers = firstGroup(lineMarkers, in: line)
        let body = String(line.dropFirst(markers.count))
        let first = matches(placeholder, in: line).count
        let (protected, spans) = protect(body, [emphasisSpan], first: first)
        let words = placeholder.stringByReplacingMatches(
            in: protected, range: NSRange(protected.startIndex..., in: protected), withTemplate: " "
        )
        guard !matches(twoLetters, in: words).isEmpty else { return line }
        guard let fixed = try? await generate(protected).trimmingCharacters(in: .whitespacesAndNewlines),
              !fixed.contains("\n"),
              structure(fixed).marks == structure(protected).marks,
              structure(fixed).placeholders == structure(protected).placeholders,
              let restored = restore(fixed, spans, first: first)
        else { return line }
        return markers + restored
    }

    /// Swaps text the model must not touch for placeholders numbered from `first`.
    static func protect(_ text: String, _ patterns: [NSRegularExpression], first: Int = 0) -> (String, [String]) {
        var text = text
        var saved: [String] = []
        for pattern in patterns {
            var result = ""
            var cursor = text.startIndex
            for match in matches(pattern, in: text) {
                guard let range = Range(match.range, in: text) else { continue }
                result += text[cursor..<range.lowerBound]
                saved.append(String(text[range]))
                result += "⟦\(first + saved.count - 1)⟧"
                cursor = range.upperBound
            }
            result += text[cursor...]
            text = result
        }
        return (text, saved)
    }

    static func restore(_ text: String, _ saved: [String], first: Int = 0) -> String? {
        var text = text
        for (index, original) in saved.enumerated() {
            let token = "⟦\(first + index)⟧"
            guard text.components(separatedBy: token).count == 2 else { return nil }
            text = text.replacingOccurrences(of: token, with: original)
        }
        return text
    }

    struct Structure: Equatable {
        let lines: [String]
        let marks: Int
        let placeholders: [String]
    }

    /// Line layout and Markdown markers, which a correction must leave exactly as they were.
    static func structure(_ text: String) -> Structure {
        let lines = text.components(separatedBy: "\n").map { line in
            line.trimmingCharacters(in: .whitespaces).isEmpty
                ? "" : firstGroup(lineMarkers, in: line).trimmingCharacters(in: .whitespaces) + "|"
        }
        let placeholders = matches(placeholder, in: text).compactMap { Range($0.range, in: text).map { String(text[$0]) } }
        return Structure(lines: lines, marks: matches(emphasisMark, in: text).count, placeholders: placeholders.sorted())
    }

    private static func matches(_ regex: NSRegularExpression, in text: String) -> [NSTextCheckingResult] {
        regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
    }

    private static func firstGroup(_ regex: NSRegularExpression, in text: String) -> String {
        guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text)
        else { return "" }
        return String(text[range])
    }
}
