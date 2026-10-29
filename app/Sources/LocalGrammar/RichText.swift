import Foundation

/// Converts between the HTML that rich editors (Slack, Notion, Teams, Mail, Notes, Gmail) put on the clipboard
/// and Markdown, so ⌥⌘G can send formatting to the model as Markdown and paste the result back formatted.
enum RichText {
    private static let structuralTags: Set<String> = [
        "ul", "ol", "li", "b", "strong", "i", "em", "a", "code", "pre", "blockquote", "s", "del", "strike",
        "h1", "h2", "h3", "h4", "h5", "h6",
    ]

    // MARK: HTML → Markdown

    /// Markdown for clipboard HTML, or nil when the HTML has no formatting worth keeping (only styled spans,
    /// as VS Code and plain text boxes produce).
    static func markdown(fromHTML html: String) -> String? {
        guard let document = try? XMLDocument(xmlString: html, options: [.documentTidyHTML]),
              let root = document.rootElement()
        else { return nil }
        let body = root.elements(forName: "body").first ?? root
        guard containsStructure(body) else { return nil }
        var writer = MarkdownWriter()
        writer.block(body)
        let markdown = writer.output
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .newlines)
        return markdown.isEmpty ? nil : markdown
    }

    private static func containsStructure(_ node: XMLNode) -> Bool {
        if let element = node as? XMLElement, let name = element.name?.lowercased(), structuralTags.contains(name) {
            return true
        }
        return node.children?.contains(where: containsStructure) ?? false
    }

    private struct MarkdownWriter {
        var output = ""
        private var listStack: [(ordered: Bool, index: Int)] = []
        private var quoteDepth = 0

        mutating func block(_ node: XMLNode) {
            for child in node.children ?? [] {
                guard let element = child as? XMLElement, let name = element.name?.lowercased() else {
                    let text = collapse(child.stringValue ?? "")
                    if !text.trimmingCharacters(in: .whitespaces).isEmpty { startLineIfNeeded(); output += text }
                    continue
                }
                switch name {
                case "p", "div", "section", "article", "header", "footer":
                    newBlock()
                    inlineOrBlock(element)
                    newBlock()
                case "br":
                    newLine()
                case "h1", "h2", "h3", "h4", "h5", "h6":
                    newBlock()
                    output += String(repeating: "#", count: Int(name.dropFirst()) ?? 1) + " "
                    inline(element)
                    newBlock()
                case "ul", "ol":
                    if listStack.isEmpty { newBlock() } else { newLine() }
                    listStack.append((name == "ol", 0))
                    block(element)
                    listStack.removeLast()
                    if listStack.isEmpty { newBlock() }
                case "li":
                    newLine()
                    if var top = listStack.popLast() {
                        top.index += 1
                        listStack.append(top)
                        output += String(repeating: "  ", count: listStack.count - 1)
                        output += top.ordered ? "\(top.index). " : "- "
                    } else {
                        output += "- "
                    }
                    inlineOrBlock(element)
                case "blockquote":
                    newBlock()
                    quoteDepth += 1
                    output += String(repeating: "> ", count: quoteDepth)
                    inlineOrBlock(element)
                    quoteDepth -= 1
                    newBlock()
                case "pre":
                    newBlock()
                    output += "```\n" + (element.stringValue ?? "").trimmingCharacters(in: .newlines) + "\n```"
                    newBlock()
                case "script", "style", "meta", "head", "title":
                    continue
                default:
                    inline(element, wrapping: true)
                }
            }
        }

        private mutating func inlineOrBlock(_ element: XMLElement) {
            let blockChildren: Set<String> = ["p", "div", "ul", "ol", "blockquote", "pre", "h1", "h2", "h3", "li"]
            if element.children?.contains(where: { blockChildren.contains(($0 as? XMLElement)?.name?.lowercased() ?? "") }) == true {
                block(element)
            } else {
                inline(element)
            }
        }

        private mutating func inline(_ element: XMLElement, wrapping: Bool = false) {
            let name = element.name?.lowercased() ?? ""
            var inner = MarkdownWriter()
            inner.listStack = listStack
            inner.quoteDepth = quoteDepth
            for child in element.children ?? [] { inner.inlineNode(child) }
            let text = inner.output
            guard wrapping else { output += text; return }
            output += Self.wrap(text, tag: name, href: element.attribute(forName: "href")?.stringValue)
        }

        private mutating func inlineNode(_ node: XMLNode) {
            guard let element = node as? XMLElement, let name = element.name?.lowercased() else {
                output += collapse(node.stringValue ?? "")
                return
            }
            switch name {
            case "br": newLine()
            case "ul", "ol", "p", "div", "blockquote", "pre": block(XMLElement(name: "wrapper").adopting(element))
            default: inline(element, wrapping: true)
            }
        }

        private static func wrap(_ text: String, tag: String, href: String?) -> String {
            let core = text.trimmingCharacters(in: .whitespaces)
            guard !core.isEmpty else { return text }
            let leading = text.prefix { $0 == " " }
            let trailing = String(text.reversed().prefix { $0 == " " })
            let wrapped: String
            switch tag {
            case "b", "strong": wrapped = "**\(core)**"
            case "i", "em": wrapped = "_\(core)_"
            case "s", "del", "strike": wrapped = "~~\(core)~~"
            case "code": wrapped = "`\(core)`"
            case "a": wrapped = href.map { $0 == core ? core : "[\(core)](\($0))" } ?? core
            default: wrapped = core
            }
            return leading + wrapped + trailing
        }

        private func collapse(_ text: String) -> String {
            text.replacingOccurrences(of: #"[ \t\r\n]+"#, with: " ", options: .regularExpression)
        }

        private mutating func newLine() {
            if !output.isEmpty, !output.hasSuffix("\n") { output += "\n" }
            if quoteDepth > 0 { output += String(repeating: "> ", count: quoteDepth) }
        }

        private mutating func newBlock() {
            guard !output.isEmpty else { return }
            // A paragraph right after a list or quote marker belongs on the marker's line.
            let lastLine = output.split(separator: "\n", omittingEmptySubsequences: false).last ?? ""
            if !lastLine.isEmpty, lastLine.wholeMatch(of: #/\s*((- |\d+\. |> ))+/#) != nil { return }
            while output.hasSuffix(" ") { output.removeLast() }
            if !output.hasSuffix("\n") { output += "\n" }
            if listStack.isEmpty, quoteDepth == 0, !output.hasSuffix("\n\n") { output += "\n" }
        }

        private mutating func startLineIfNeeded() {
            if output.hasSuffix("\n"), quoteDepth > 0 { output += String(repeating: "> ", count: quoteDepth) }
        }
    }

    // MARK: Markdown → HTML

    /// HTML for the Markdown subset the model returns: paragraphs, lists, quotes, headings, fenced code,
    /// bold, italic, strikethrough, inline code and links.
    static func html(fromMarkdown markdown: String) -> String {
        var html = ""
        var lists: [String] = []
        var paragraph: [String] = []
        var inCode = false
        var code: [String] = []

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            html += "<p>" + paragraph.map(inlineHTML).joined(separator: "<br>") + "</p>"
            paragraph = []
        }
        func closeLists(to depth: Int = 0) {
            while lists.count > depth { html += "</li></\(lists.removeLast())>" }
        }

        for line in markdown.components(separatedBy: "\n") {
            if line.hasPrefix("```") {
                if inCode {
                    html += "<pre><code>" + escape(code.joined(separator: "\n")) + "</code></pre>"
                    code = []
                } else {
                    flushParagraph()
                    closeLists()
                }
                inCode.toggle()
                continue
            }
            if inCode { code.append(line); continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                flushParagraph()
                closeLists()
                continue
            }
            if let match = trimmed.firstMatch(of: #/^([-*+•]|\d+[.)])\s+(.*)$/#) {
                flushParagraph()
                let tag = match.1.first?.isNumber == true ? "ol" : "ul"
                let depth = min(line.prefix { $0 == " " }.count / 2, lists.count)
                closeLists(to: depth + 1)
                if lists.count == depth + 1, lists.last != tag { closeLists(to: depth) }
                if lists.count == depth {
                    html += "<\(tag)><li>"
                    lists.append(tag)
                } else {
                    html += "</li><li>"
                }
                html += inlineHTML(String(match.2))
                continue
            }
            closeLists()
            if let match = trimmed.firstMatch(of: #/^(#{1,6})\s+(.*)$/#) {
                flushParagraph()
                html += "<h\(match.1.count)>" + inlineHTML(String(match.2)) + "</h\(match.1.count)>"
            } else if let match = trimmed.firstMatch(of: #/^>\s?(.*)$/#) {
                flushParagraph()
                html += "<blockquote>" + inlineHTML(String(match.1)) + "</blockquote>"
            } else {
                paragraph.append(trimmed)
            }
        }
        if inCode { html += "<pre><code>" + escape(code.joined(separator: "\n")) + "</code></pre>" }
        flushParagraph()
        closeLists()
        return "<meta charset=\"utf-8\">" + html
    }

    private static func inlineHTML(_ text: String) -> String {
        var codeSpans: [String] = []
        var result = escape(text).replacing(#/`([^`]+)`/#) { match in
            codeSpans.append("<code>\(match.1)</code>")
            return "\u{E000}\(codeSpans.count - 1)\u{E001}"
        }
        result = result
            .replacing(#/\[([^\]]+)\]\(([^)\s]+)\)/#) { "<a href=\"\($0.2)\">\($0.1)</a>" }
            .replacing(#/\*\*([^*]+)\*\*/#) { "<strong>\($0.1)</strong>" }
            .replacing(#/__([^_]+)__/#) { "<strong>\($0.1)</strong>" }
            .replacing(#/~~([^~]+)~~/#) { "<s>\($0.1)</s>" }
            .replacingOccurrences(of: #"(?<![\w*])\*([^*\n]+)\*(?![\w*])"#, with: "<em>$1</em>", options: .regularExpression)
            .replacingOccurrences(of: #"(?<![\w_])_([^_\n]+)_(?![\w_])"#, with: "<em>$1</em>", options: .regularExpression)
        for (index, span) in codeSpans.enumerated() {
            result = result.replacingOccurrences(of: "\u{E000}\(index)\u{E001}", with: span)
        }
        return result
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    // MARK: Comparing

    /// Letters and digits only, lowercased: lets a paste be confirmed even when the app shows formatting
    /// instead of Markdown symbols, or swaps in smart quotes and non-breaking spaces.
    static func fold(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    /// The words of Markdown text without its symbols, for confirming a formatted paste landed.
    static func plainWords(ofMarkdown markdown: String) -> String {
        markdown.replacing(#/\[([^\]]+)\]\([^)]*\)/#) { String($0.1) }
    }
}

private extension XMLElement {
    func adopting(_ child: XMLElement) -> XMLElement {
        addChild(child.copy() as! XMLNode)
        return self
    }
}
