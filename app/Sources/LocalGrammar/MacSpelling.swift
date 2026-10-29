import AppKit

@MainActor
enum MacSpelling {
    private static let checker = NSSpellChecker.shared

    /// Misspelled ranges only. Fast (~20 ms for 8,000 characters); suggestions cost ~40 ms a word, so
    /// they're looked up separately with `suggestions(for:in:dialect:)`.
    static func misspellings(in text: String, dialect: EnglishDialect) -> [NSRange] {
        use(dialect)
        let fullRange = NSRange(location: 0, length: (text as NSString).length)
        return checker.check(
            text, range: fullRange, types: NSTextCheckingResult.CheckingType.spelling.rawValue,
            options: nil, inSpellDocumentWithTag: 0, orthography: nil, wordCount: nil
        ).map(\.range)
    }

    static func suggestions(for range: NSRange, in text: String, dialect: EnglishDialect) -> (suggestions: [String], best: String?) {
        use(dialect)
        let language = dialect.spellLanguage
        let guesses = checker.guesses(forWordRange: range, in: text, language: language, inSpellDocumentWithTag: 0) ?? []
        let best = checker.correction(forWordRange: range, in: text, language: language, inSpellDocumentWithTag: 0)
        var suggestions = Array(guesses.prefix(3))
        if let best, !suggestions.contains(best) { suggestions.insert(best, at: 0) }
        return (Array(suggestions.prefix(3)), best)
    }

    static func learn(_ word: String) {
        checker.learnWord(word)
    }

    private static func use(_ dialect: EnglishDialect) {
        checker.automaticallyIdentifiesLanguages = false
        if checker.language() != dialect.spellLanguage { checker.setLanguage(dialect.spellLanguage) }
    }
}
