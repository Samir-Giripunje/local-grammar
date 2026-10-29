import Foundation

enum WordDiff {
    enum Change: Equatable {
        case same(String)
        case removed(String)
        case added(String)
    }

    private static let maxCells = 4_000_000

    enum Segment: Identifiable {
        case same(id: Int, text: String)
        case change(id: Int, old: String, new: String)

        var id: Int {
            switch self {
            case .same(let id, _), .change(let id, _, _): id
            }
        }
    }

    static func segments(_ old: String, _ new: String) -> [Segment] {
        var segments: [Segment] = []
        var removed = ""
        var added = ""
        func flushChange() {
            guard !removed.isEmpty || !added.isEmpty else { return }
            segments.append(.change(id: segments.count, old: removed, new: added))
            removed = ""
            added = ""
        }
        for change in diff(old, new) {
            switch change {
            case .same(let text) where text.allSatisfy(\.isWhitespace) && (!removed.isEmpty || !added.isEmpty):
                removed += text
                added += text
            case .same(let text):
                flushChange()
                segments.append(.same(id: segments.count, text: text))
            case .removed(let text):
                removed += text
            case .added(let text):
                added += text
            }
        }
        flushChange()
        return segments
    }

    static func diff(_ old: String, _ new: String) -> [Change] {
        let a = tokens(old)
        let b = tokens(new)
        guard a.count * b.count <= maxCells else { return [.removed(old), .added(new)] }
        var lcs = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                lcs[i][j] = a[i] == b[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }
        var changes: [Change] = []
        var i = 0
        var j = 0
        while i < a.count || j < b.count {
            if i < a.count, j < b.count, a[i] == b[j] {
                changes.append(.same(a[i]))
                i += 1
                j += 1
            } else if j < b.count, i == a.count || lcs[i][j + 1] > lcs[i + 1][j] {
                changes.append(.added(b[j]))
                j += 1
            } else {
                changes.append(.removed(a[i]))
                i += 1
            }
        }
        return changes
    }

    private static func tokens(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        for char in text {
            if !current.isEmpty, char.isWhitespace != current.last!.isWhitespace {
                result.append(current)
                current = ""
            }
            current.append(char)
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}
