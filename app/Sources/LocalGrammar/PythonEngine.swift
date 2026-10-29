import Foundation

/// The Python side of the Qwen engine: the MLX model server and the model tools. The app carries the
/// scripts and `uv`; setting up copies the scripts to Application Support and lets `uv` install Python
/// and MLX next to them (once, ~400 MB). Apple Intelligence needs none of this.
@MainActor
final class PythonEngine: ObservableObject {
    enum State: Equatable {
        case missing
        case installing(String)
        case installed
        case failed(String)
    }

    nonisolated static let support = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/LocalGrammar")
    nonisolated static let dir = support.appendingPathComponent("engine")
    nonisolated static let python = dir.appendingPathComponent(".venv/bin/python")
    nonisolated static let logs = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/LocalGrammar")

    /// Files the app carries in Contents/Resources/engine.
    private static let files = ["server.py", "corrector.py", "models.py", "benchmark.py", "pyproject.toml", "uv.lock", ".python-version"]
    private nonisolated static var bundled: URL? { Bundle.main.url(forResource: "engine", withExtension: nil) }
    private static var uv: URL? { Bundle.main.url(forResource: "uv", withExtension: nil) }

    @Published private(set) var state: State = .missing
    private var installer: Process?

    init() {
        refreshScripts()
        state = Self.isSetUp ? .installed : .missing
    }

    var isInstalled: Bool { state == .installed }

    /// Installed when Python and MLX are there for the lock file this version of the app carries.
    nonisolated static var isSetUp: Bool {
        guard FileManager.default.isExecutableFile(atPath: python.path), let bundled else { return false }
        let installedLock = try? Data(contentsOf: dir.appendingPathComponent(".installed.lock"))
        return installedLock != nil && installedLock == (try? Data(contentsOf: bundled.appendingPathComponent("uv.lock")))
    }

    /// Keeps the scripts in step with the app, so an app update brings its engine fixes along.
    private func refreshScripts() {
        guard let bundled = Self.bundled else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.dir, withIntermediateDirectories: true)
        for name in Self.files {
            let source = bundled.appendingPathComponent(name)
            let target = Self.dir.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: source), (try? Data(contentsOf: target)) != data else { continue }
            try? data.write(to: target, options: .atomic)
        }
    }

    func install() {
        guard installer == nil, let uv = Self.uv, let bundled = Self.bundled else {
            if Self.uv == nil { state = .failed("This copy of the app is missing its installer (uv).") }
            return
        }
        refreshScripts()
        state = .installing("Downloading Python and MLX (about 400 MB)…")
        let process = Process()
        process.executableURL = uv
        process.arguments = ["sync", "--frozen", "--no-dev", "--python-preference", "only-managed"]
        process.currentDirectoryURL = Self.dir
        var env = ProcessInfo.processInfo.environment
        env["UV_PROJECT_ENVIRONMENT"] = Self.dir.appendingPathComponent(".venv").path
        env["UV_NO_PROGRESS"] = "1"
        process.environment = env
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        installer = process
        do {
            try process.run()
        } catch {
            installer = nil
            state = .failed(error.localizedDescription)
            return
        }
        Task {
            let output = await Task.detached { errors.fileHandleForReading.readDataToEndOfFile() }.value
            process.waitUntilExit()
            installer = nil
            Self.writeLog(output)
            guard process.terminationStatus == 0 else {
                let lastLine = String(decoding: output, as: UTF8.self)
                    .split(separator: "\n").last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                state = .failed("Setup failed: \(lastLine.map(String.init) ?? "uv exited with \(process.terminationStatus)")")
                return
            }
            try? FileManager.default.copyItem(
                at: bundled.appendingPathComponent("uv.lock"), to: Self.dir.appendingPathComponent(".installed.lock.tmp")
            )
            _ = try? FileManager.default.replaceItemAt(
                Self.dir.appendingPathComponent(".installed.lock"),
                withItemAt: Self.dir.appendingPathComponent(".installed.lock.tmp")
            )
            state = Self.isSetUp ? .installed : .failed("Setup finished, but Python wasn't found afterwards.")
        }
    }

    func cancelInstall() {
        installer?.terminate()
    }

    /// Removes Python and MLX. Downloaded models stay, in the Hugging Face cache.
    func uninstall() {
        try? FileManager.default.removeItem(at: Self.dir.appendingPathComponent(".venv"))
        try? FileManager.default.removeItem(at: Self.dir.appendingPathComponent(".installed.lock"))
        state = .missing
    }

    private nonisolated static func writeLog(_ data: Data) {
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        try? data.write(to: logs.appendingPathComponent("engine-setup.log"))
    }
}
