import Darwin
import Foundation

/// Which model ⌥⌘G proofreads with.
enum ProofreadingEngine: String, CaseIterable, Identifiable {
    /// Apple's on-device model: built into macOS 26, nothing to download.
    case apple
    /// A local MLX model (Qwen by default) run by the Python engine.
    case qwen

    var id: String { rawValue }
    var title: String { self == .apple ? "Apple Intelligence" : "Qwen (MLX)" }
}

@MainActor
final class ServerManager: ObservableObject {
    enum Status: Equatable {
        case stopped
        case loading
        case ready
        case failed(String)
    }

    nonisolated static let port = 8765
    static let logFile = PythonEngine.logs.appendingPathComponent("server.log")

    @Published var engine: ProofreadingEngine {
        didSet {
            guard engine != oldValue else { return }
            UserDefaults.standard.set(engine.rawValue, forKey: "engine")
            if engine == .apple { stop() } else if keepsLoaded { start() }
        }
    }
    @Published private(set) var status: Status = .stopped
    @Published private(set) var modelID: String
    /// Memory the loaded model takes (the server process's physical footprint, which includes GPU buffers).
    @Published private(set) var memoryBytes: UInt64?
    /// Whether the model should be in memory. Off frees its RAM until ⌥⌘G needs it again.
    @Published var keepsLoaded = UserDefaults.standard.object(forKey: "keepModelLoaded") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(keepsLoaded, forKey: "keepModelLoaded")
            keepsLoaded ? start() : stop()
        }
    }
    /// Minutes without a correction before the model is unloaded automatically; 0 keeps it loaded.
    @Published var unloadAfterMinutes = UserDefaults.standard.integer(forKey: "unloadAfterMinutes") {
        didSet { UserDefaults.standard.set(unloadAfterMinutes, forKey: "unloadAfterMinutes") }
    }

    /// Per-model proofreading settings, keyed by model id.
    let tuning = ModelSettingsStore()
    /// Settings for whichever engine ⌥⌘G uses now.
    var settings: ModelSettings { tuning.settings(for: settingsID) }
    var settingsID: String { engine == .apple ? AppleProofreader.settingsID : modelID }
    /// Qwen can run: its Python engine is set up.
    var qwenIsSetUp: Bool { PythonEngine.isSetUp }

    private(set) var token = ""
    private var process: Process?
    private var healthTask: Task<Void, Never>?
    private var lastUsed = Date()
    private var monitor: Timer?

    init() {
        modelID = UserDefaults.standard.string(forKey: "modelID") ?? GrammarModel.defaultID
        engine = UserDefaults.standard.string(forKey: "engine").flatMap(ProofreadingEngine.init(rawValue:))
            ?? (AppleProofreader.isAvailable ? .apple : .qwen)
        monitor = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkMemoryAndIdle() }
        }
    }

    func select(model id: String) {
        guard id != modelID || status != .ready else { return }
        modelID = id
        UserDefaults.standard.set(id, forKey: "modelID")
        if keepsLoaded { start() }
    }

    /// Starts the model if it is unloaded and waits until it answers. Called before every correction.
    func ensureLoaded() async -> Bool {
        lastUsed = Date()
        if status == .ready { return true }
        if process == nil {
            if !keepsLoaded {
                // Loading on demand: the model stays loaded until the user unloads it again or it idles out.
                keepsLoaded = true
            } else {
                start()
            }
        }
        for _ in 0..<720 {
            if status == .ready { return true }
            if case .failed = status { return false }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return status == .ready
    }

    func noteUsed() {
        lastUsed = Date()
    }

    private func checkMemoryAndIdle() {
        memoryBytes = process.flatMap { Self.footprint(of: $0.processIdentifier) }
        guard unloadAfterMinutes > 0, status == .ready,
              Date().timeIntervalSince(lastUsed) > Double(unloadAfterMinutes) * 60
        else { return }
        keepsLoaded = false
    }

    private static func footprint(of pid: pid_t) -> UInt64? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        return result == 0 ? info.ri_phys_footprint : nil
    }

    func start() {
        stop()
        guard PythonEngine.isSetUp else { return }
        lastUsed = Date()
        status = .loading
        do {
            process = try launchServer()
            watchHealth()
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    func stop() {
        healthTask?.cancel()
        let running = process
        process = nil
        running?.terminate()
        running?.waitUntilExit()
        memoryBytes = nil
        status = .stopped
    }

    private func launchServer() throws -> Process {
        let server = Process()
        server.executableURL = PythonEngine.python
        server.arguments = ["server.py"]
        server.currentDirectoryURL = PythonEngine.dir

        var env = ProcessInfo.processInfo.environment
        env["GRAMMAR_MODEL"] = modelID
        env["GRAMMAR_PORT"] = String(Self.port)
        token = UUID().uuidString
        env["GRAMMAR_TOKEN"] = token
        env["PYTHONUNBUFFERED"] = "1"
        if GrammarModel.isDownloaded(modelID) {
            env["HF_HUB_OFFLINE"] = "1"
        }
        server.environment = env

        let log = try openLog()
        server.standardOutput = log
        server.standardError = log
        server.terminationHandler = { [weak self] exited in
            Task { @MainActor in self?.serverExited(exited) }
        }
        try server.run()
        return server
    }

    private func openLog() throws -> FileHandle {
        let fm = FileManager.default
        try fm.createDirectory(at: Self.logFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: Self.logFile.path) {
            fm.createFile(atPath: Self.logFile.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: Self.logFile)
        handle.seekToEndOfFile()
        return handle
    }

    private func serverExited(_ exited: Process) {
        guard exited === process else { return }
        healthTask?.cancel()
        process = nil
        status = .failed("server exited (code \(exited.terminationStatus)) — see log")
    }

    private func watchHealth() {
        let launch = process
        let token = token
        healthTask = Task { [weak self] in
            while !Task.isCancelled {
                let healthy = await GrammarClient.isHealthy(token: token)
                guard !Task.isCancelled, let self, self.process === launch else { return }
                if healthy {
                    self.status = .ready
                    self.memoryBytes = launch.flatMap { Self.footprint(of: $0.processIdentifier) }
                    return
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}
