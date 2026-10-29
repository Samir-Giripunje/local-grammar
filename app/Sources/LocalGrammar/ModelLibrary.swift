import Foundation

/// Models on this Mac and the "add a model from Hugging Face" flow, backed by `models.py`.
@MainActor
final class ModelLibrary: ObservableObject {
    struct Installed: Identifiable, Decodable, Equatable {
        let id: String
        let name: String
        let path: String
        let source: String
        let bytes: Int64
        let modelType: String?
        let supported: Bool
        let complete: Bool
        let chatTemplate: Bool

        /// What the model server loads: the Hugging Face id (found in its cache), or the folder of a
        /// model that was shrunk to 4-bit on this Mac.
        var loadID: String { source == "converted" ? path : id }

        enum CodingKeys: String, CodingKey {
            case id, name, path, source, bytes, supported, complete
            case modelType = "model_type"
            case chatTemplate = "chat_template"
        }
    }

    struct Inspection: Decodable, Equatable {
        let id: String
        let name: String
        let verdict: String
        let reasons: [String]
        let modelType: String?
        let format: String?
        let bits: Int?
        let downloadBytes: Int64?
        let memoryBytes: Int64?
        let convertedBytes: Int64?
        let alternative: String?
        let installed: Bool?

        var canInstall: Bool { verdict == "ready" || verdict == "convert" }
        var needsConversion: Bool { verdict == "convert" }
        /// Disk the model takes once installed (the shrunk copy, when it's converted).
        var diskBytes: Int64 { (needsConversion ? convertedBytes : nil) ?? downloadBytes ?? 0 }

        enum CodingKeys: String, CodingKey {
            case id, name, verdict, reasons, format, bits, alternative, installed
            case modelType = "model_type"
            case downloadBytes = "download_bytes"
            case memoryBytes = "memory_bytes"
            case convertedBytes = "converted_bytes"
        }
    }

    struct TestResult: Codable, Equatable {
        let score: Int
        let total: Int
        let avgMs: Int
        let loadMs: Int

        enum CodingKeys: String, CodingKey {
            case score, total
            case avgMs = "avg_ms"
            case loadMs = "load_ms"
        }
    }

    struct SystemCheck: Equatable {
        let freeDisk: Int64
        let ram: Int64
        let neededDisk: Int64
        let neededMemory: Int64

        /// Keeps 1 GB of disk spare after the download.
        var fitsDisk: Bool { neededDisk + 1_000_000_000 <= freeDisk }
        /// More than ~60% of RAM leaves too little for everything else.
        var memoryIsTight: Bool { Double(neededMemory) > Double(ram) * 0.6 }
        var fitsMemory: Bool { neededMemory < ram - 2_000_000_000 }
    }

    enum AddState: Equatable {
        case idle
        case fetching(String)
        case checked(Inspection, SystemCheck)
        case downloading(Inspection, done: Int64, total: Int64)
        case converting(Inspection)
        case testing(Inspection)
        case ready(Inspection, loadID: String, result: TestResult?)
        case failed(String)
    }

    @Published private(set) var installed: [Installed] = []
    @Published private(set) var addState = AddState.idle
    @Published private(set) var testResults: [String: TestResult]
    @Published private(set) var testing: Set<String> = []
    @Published private(set) var isRefreshing = false

    private var download: Process?

    init() {
        let data = UserDefaults.standard.data(forKey: "modelTests")
        testResults = data.flatMap { try? JSONDecoder().decode([String: TestResult].self, from: $0) } ?? [:]
    }

    var usable: [Installed] { installed.filter { $0.supported && $0.complete } }

    func name(for loadID: String) -> String? {
        installed.first { $0.loadID == loadID }?.name
    }

    // MARK: Installed models

    func refresh() {
        guard !isRefreshing, PythonEngine.isSetUp else { return }
        isRefreshing = true
        Task {
            defer { isRefreshing = false }
            struct Listing: Decodable { let models: [Installed] }
            guard let output = await Self.run(["list"]),
                  let listing = try? JSONDecoder().decode(Listing.self, from: Data(output.utf8))
            else { return }
            installed = listing.models
        }
    }

    func delete(_ model: Installed) async -> String? {
        struct Deleted: Decodable { let ok: Bool; let message: String? }
        let output = await Self.run(["delete", model.source == "converted" ? model.path : model.id])
        let result = output.flatMap { try? JSONDecoder().decode(Deleted.self, from: Data($0.utf8)) }
        refresh()
        return result?.ok == true ? nil : (result?.message ?? "Couldn't delete the model.")
    }

    func test(_ loadID: String) {
        guard !testing.contains(loadID) else { return }
        testing.insert(loadID)
        Task {
            let result = await Self.runTest(loadID)
            testing.remove(loadID)
            if let result { record(result, for: loadID) }
        }
    }

    private func record(_ result: TestResult, for loadID: String) {
        testResults[loadID] = result
        if let data = try? JSONEncoder().encode(testResults) { UserDefaults.standard.set(data, forKey: "modelTests") }
    }

    // MARK: Adding a model

    func inspect(_ link: String) {
        let link = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !link.isEmpty else { return }
        cancelDownload()
        addState = .fetching(link)
        Task {
            guard let output = await Self.run(["inspect", link]),
                  let inspection = try? JSONDecoder().decode(Inspection.self, from: Data(output.utf8))
            else { return addState = .failed("Couldn't read that model's details.") }
            guard case .fetching(link) = addState else { return }
            let disk = Self.systemInfo()
            let check = SystemCheck(
                freeDisk: disk.free,
                ram: disk.ram,
                neededDisk: inspection.installed == true
                    ? 0 : (inspection.downloadBytes ?? 0) + (inspection.needsConversion ? inspection.convertedBytes ?? 0 : 0),
                neededMemory: inspection.memoryBytes ?? 0
            )
            addState = .checked(inspection, check)
        }
    }

    func install(_ inspection: Inspection) {
        addState = .downloading(inspection, done: 0, total: inspection.downloadBytes ?? 0)
        Task {
            var arguments = ["download", inspection.id]
            if inspection.needsConversion { arguments.append("--convert") }
            let process = Self.makeProcess(arguments)
            let pipe = Pipe()
            process.standardOutput = pipe
            download = process
            do { try process.run() } catch { return addState = .failed(error.localizedDescription) }

            var loadID: String?
            var failure: String?
            for try await line in pipe.fileHandleForReading.bytes.lines {
                guard let event = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
                switch event["phase"] as? String {
                case "downloading":
                    let done = (event["done"] as? NSNumber)?.int64Value ?? 0
                    let total = (event["total"] as? NSNumber)?.int64Value ?? inspection.downloadBytes ?? 0
                    addState = .downloading(inspection, done: done, total: total)
                case "converting":
                    addState = .converting(inspection)
                case "done":
                    loadID = inspection.needsConversion ? event["path"] as? String : inspection.id
                case "error":
                    failure = event["message"] as? String ?? "The download failed."
                case "cancelled":
                    failure = "cancelled"
                default:
                    break
                }
            }
            process.waitUntilExit()
            download = nil
            if failure == "cancelled" { return addState = .idle }
            guard let loadID else { return addState = .failed(failure ?? "The download stopped unexpectedly.") }
            refresh()
            addState = .testing(inspection)
            let result = await Self.runTest(loadID)
            if let result { record(result, for: loadID) }
            addState = .ready(inspection, loadID: loadID, result: result)
        }
    }

    func cancelDownload() {
        download?.terminate()
    }

    func resetAdd() {
        cancelDownload()
        addState = .idle
    }

    // MARK: Helper process

    private static func makeProcess(_ arguments: [String]) -> Process {
        let process = Process()
        process.executableURL = PythonEngine.python
        process.arguments = ["models.py"] + arguments
        process.currentDirectoryURL = PythonEngine.dir
        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        env["HF_HUB_DISABLE_PROGRESS_BARS"] = "1"
        // Testing only ever runs a model that's already on disk.
        if arguments.first == "test" { env["HF_HUB_OFFLINE"] = "1" }
        process.environment = env
        process.standardError = FileHandle.nullDevice
        return process
    }

    /// Runs a helper command and returns its stdout (a JSON object).
    private static func run(_ arguments: [String]) async -> String? {
        let process = makeProcess(arguments)
        let pipe = Pipe()
        process.standardOutput = pipe
        do { try process.run() } catch { return nil }
        // Read until the helper closes its output (it exits right after), off the main thread.
        let data = await Task.detached { pipe.fileHandleForReading.readDataToEndOfFile() }.value
        return String(data: data, encoding: .utf8)
    }

    private static func runTest(_ loadID: String) async -> TestResult? {
        guard let output = await run(["test", loadID]) else { return nil }
        return try? JSONDecoder().decode(TestResult.self, from: Data(output.utf8))
    }

    static func systemInfo() -> (free: Int64, ram: Int64) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let free = (try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? 0
        return (free, Int64(ProcessInfo.processInfo.physicalMemory))
    }
}
