import Foundation

struct SpellIssue: Decodable, Identifiable, Equatable {
    let start: Int
    let end: Int
    let kind: String
    let message: String
    var suggestions: [String]
    var best: String?

    var id: String { "\(start)-\(end)-\(message)" }
    var length: Int { end - start }
    var range: NSRange { NSRange(location: start, length: length) }
}

final class HarperEngine: @unchecked Sendable {
    static let dictionaryFile = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/LocalGrammar/dictionary.txt")

    private let queue = DispatchQueue(label: "harper-engine")
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var buffer = Data()
    private var dialect = EnglishDialect.current

    func use(_ dialect: EnglishDialect) {
        queue.async {
            self.dialect = dialect
            self.discardProcess()
        }
    }

    func lint(_ text: String) async -> [SpellIssue] {
        guard let line = await send(["text": text]) else { return [] }
        struct Response: Decodable { let issues: [SpellIssue]? }
        return (try? JSONDecoder().decode(Response.self, from: line))?.issues ?? []
    }

    func addWord(_ word: String) async {
        _ = await send(["add_word": word])
    }

    private func send(_ request: [String: String]) async -> Data? {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.roundTrip(request)) }
        }
    }

    private func roundTrip(_ request: [String: String]) -> Data? {
        if process?.isRunning != true, !launch() { return nil }
        guard var payload = try? JSONSerialization.data(withJSONObject: request) else { return nil }
        payload.append(0x0A)
        do {
            try input?.write(contentsOf: payload)
        } catch {
            discardProcess()
            return nil
        }
        return readLine()
    }

    private func readLine() -> Data? {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                return Data(line)
            }
            guard let output, Self.waitForData(on: output, seconds: 5) else {
                discardProcess()
                return nil
            }
            let chunk = output.availableData
            guard !chunk.isEmpty else {
                discardProcess()
                return nil
            }
            buffer.append(chunk)
        }
    }

    private static func waitForData(on handle: FileHandle, seconds: Int32) -> Bool {
        var descriptor = pollfd(fd: handle.fileDescriptor, events: Int16(POLLIN), revents: 0)
        return poll(&descriptor, 1, seconds * 1000) > 0
    }

    private func discardProcess() {
        process?.terminate()
        try? input?.close()
        try? output?.close()
        process = nil
        input = nil
        output = nil
        buffer.removeAll()
    }

    private func launch() -> Bool {
        discardProcess()
        guard let binary = Bundle.main.url(forResource: "harper-lint", withExtension: nil) else { return false }
        let stdin = Pipe()
        let stdout = Pipe()
        let engine = Process()
        engine.executableURL = binary
        engine.arguments = [Self.dictionaryFile.path, dialect.rawValue]
        engine.standardInput = stdin
        engine.standardOutput = stdout
        engine.standardError = FileHandle.nullDevice
        do {
            try engine.run()
        } catch {
            return false
        }
        process = engine
        input = stdin.fileHandleForWriting
        output = stdout.fileHandleForReading
        buffer.removeAll()
        return true
    }
}
