import AppKit
import SwiftUI

/// The AI model part of the main window: installed models, adding one from Hugging Face, per-model settings.
struct ModelsSection: View {
    @ObservedObject var server: ServerManager
    @ObservedObject var library: ModelLibrary
    @ObservedObject var python: PythonEngine
    @ObservedObject var tuning: ModelSettingsStore
    @State private var link = ""
    @State private var settingsFor: SettingsTarget?
    @State private var deleting: ModelLibrary.Installed?
    @State private var deleteError: String?

    private struct SettingsTarget: Identifiable {
        let id: String
        let name: String
    }

    var body: some View {
        Section {
            Picker("Proofread with", selection: $server.engine) {
                ForEach(ProofreadingEngine.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            if server.engine == .apple {
                appleRow
            } else if !python.isInstalled {
                QwenSetup(python: python)
            }
        } header: {
            Text("AI proofreading")
        } footer: {
            Text(engineFooter)
        }
        .sheet(item: $settingsFor) { target in
            ModelSettingsView(modelID: target.id, name: target.name, tuning: tuning)
        }
        .onChange(of: python.state) { _, state in
            guard state == .installed else { return }
            library.refresh()
            if server.engine == .qwen, server.keepsLoaded { server.start() }
        }

        if server.engine == .qwen, python.isInstalled {
            qwenSections
        }
    }

    private var engineFooter: String {
        server.engine == .apple
            ? "Used by ⌥⌘G. Apple's on-device model: nothing to download, and macOS manages its memory."
            : "Used by ⌥⌘G. Runs Qwen with MLX on this Mac; you choose when it's in memory."
    }

    private var appleRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles").foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text(AppleProofreader.name)
                switch AppleProofreader.status {
                case .available:
                    Text("Built into macOS · about 0.5 s per sentence").font(.caption).foregroundStyle(.secondary)
                case .unavailable(let reason):
                    Text(reason).font(.caption).foregroundStyle(.orange)
                }
            }
            Spacer()
            if !AppleProofreader.isAvailable {
                Button("Open Settings…") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Siri-Settings.extension")!)
                }
                .controlSize(.small)
            }
            Button("Settings…") {
                settingsFor = SettingsTarget(id: AppleProofreader.settingsID, name: AppleProofreader.name)
            }
            .controlSize(.small)
        }
    }

    @ViewBuilder
    private var qwenSections: some View {
        Section {
            ForEach(library.usable) { model in
                row(model)
            }
            if library.usable.isEmpty {
                Text(library.isRefreshing ? "Looking for models on this Mac…" : "No models on this Mac yet.")
                    .foregroundStyle(.secondary)
            }
            Picker("Unload when unused", selection: $server.unloadAfterMinutes) {
                Text("Never").tag(0)
                Text("After 5 min").tag(5)
                Text("After 15 min").tag(15)
                Text("After 30 min").tag(30)
                Text("After 1 hour").tag(60)
            }
        } header: {
            Text("Qwen models")
        } footer: {
            Text("⌥⌘G uses the checked model and loads it if it isn't in memory. The others only take disk space.")
        }

        Section {
            HStack(spacing: 8) {
                TextField("Hugging Face link or org/name", text: $link, prompt: Text("huggingface.co/mlx-community/…"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { library.inspect(link) }
                Button("Check") { library.inspect(link) }
                    .disabled(link.trimmingCharacters(in: .whitespaces).isEmpty || isBusy)
            }
            AddCard(library: library, server: server) { alternative in
                link = alternative
                library.inspect(alternative)
            }
            .animation(.easeInOut(duration: 0.25), value: library.addState)
            if case .idle = library.addState, !suggestions.isEmpty {
                HStack(spacing: 6) {
                    Text("Suggested:").font(.caption).foregroundStyle(.secondary)
                    ForEach(suggestions) { model in
                        Button(model.name) {
                            link = model.id
                            library.inspect(model.id)
                        }
                        .buttonStyle(.link)
                        .font(.caption)
                    }
                }
            }
        } header: {
            Text("Add a model")
        } footer: {
            Text("Any MLX-compatible chat model works. Full-size models are shrunk to 4-bit while installing.")
        }
        .confirmationDialog(
            "Delete \(deleting?.name ?? "model")?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            presenting: deleting
        ) { model in
            Button("Delete \(ByteCountFormatter.string(fromByteCount: model.bytes, countStyle: .file))", role: .destructive) {
                Task { deleteError = await library.delete(model) }
            }
        } message: { _ in
            Text("Its files are removed from this Mac. You can download it again later.")
        }
        .alert("Couldn't delete", isPresented: Binding(get: { deleteError != nil }, set: { if !$0 { deleteError = nil } })) {
            Button("OK") {}
        } message: {
            Text(deleteError ?? "")
        }
    }

    // MARK: Rows

    private func row(_ model: ModelLibrary.Installed) -> some View {
        let active = model.loadID == server.modelID
        return HStack(spacing: 8) {
            Image(systemName: active ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(active ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(model.name).lineLimit(1)
                    if tuning.isCustomized(model.loadID) {
                        Image(systemName: "slider.horizontal.3").font(.caption2).foregroundStyle(.secondary)
                            .help("Has its own settings")
                    }
                }
                Text(active ? "\(memoryStatus) · \(caption(for: model))" : caption(for: model))
                    .font(.caption)
                    .foregroundStyle(active && isFailed ? Color.orange : .secondary)
                    .lineLimit(1)
                    .help(active ? memoryStatus : "")
            }
            Spacer()
            if !active {
                Button("Use") { server.select(model: model.loadID) }.controlSize(.small)
            } else if server.status == .stopped || isFailed {
                Button("Load") { server.keepsLoaded = true }.controlSize(.small)
            } else {
                Button("Unload") { server.keepsLoaded = false }.controlSize(.small)
            }
            Menu {
                Button("Test Proofreading") { library.test(model.loadID) }
                    .disabled(library.testing.contains(model.loadID))
                Button("Settings…") { settingsFor = SettingsTarget(id: model.loadID, name: model.name) }
                Button("Show in Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: model.path) }
                Divider()
                Button("Delete…", role: .destructive) { deleting = model }
                    .disabled(active)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .contentShape(Rectangle())
    }

    private func caption(for model: ModelLibrary.Installed) -> String {
        var parts = [ByteCountFormatter.string(fromByteCount: model.bytes, countStyle: .file) + " on disk"]
        if library.testing.contains(model.loadID) {
            parts.append("testing…")
        } else if let result = library.testResults[model.loadID] {
            parts.append("fixed \(result.score)/\(result.total) · \(Self.seconds(result.avgMs)) each")
        }
        if !model.chatTemplate { parts.append("may not follow instructions") }
        if let result = library.testResults[model.loadID], result.score * 2 < result.total { parts.append("weak at proofreading") }
        return parts.joined(separator: " · ")
    }

    static func seconds(_ ms: Int) -> String {
        String(format: "%.1f s", Double(ms) / 1000)
    }

    // MARK: Active model

    /// Whether the checked model is in memory, and how much it takes.
    private var memoryStatus: String {
        switch server.status {
        case .ready:
            return "In memory (" + (server.memoryBytes.map { MainView.format($0) } ?? "measuring…") + ")"
        case .loading:
            return "Loading…"
        case .stopped:
            return "Not loaded"
        case .failed(let reason):
            return reason
        }
    }

    private var isFailed: Bool {
        if case .failed = server.status { return true }
        return false
    }

    private var isBusy: Bool {
        switch library.addState {
        case .fetching, .downloading, .converting, .testing: return true
        default: return false
        }
    }

    private var suggestions: [GrammarModel] {
        GrammarModel.catalog.filter { model in !library.installed.contains { $0.id == model.id } }
    }
}

// MARK: - Qwen setup

/// One-time setup of Python and MLX for Qwen, shown until it's done.
private struct QwenSetup: View {
    @ObservedObject var python: PythonEngine

    var body: some View {
        switch python.state {
        case .missing, .installed:
            VStack(alignment: .leading, spacing: 6) {
                Text("Qwen runs on this Mac with Apple's MLX. Setting it up downloads Python and MLX once "
                    + "(about 400 MB); the Qwen3.5 2B model (1.6 GB) follows the first time you use it.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("Set Up Qwen") { python.install() }.buttonStyle(.borderedProminent)
                }
                .controlSize(.small)
            }
        case .installing(let step):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(step).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { python.cancelInstall() }.controlSize(.small)
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Open Log") {
                        NSWorkspace.shared.open(PythonEngine.logs.appendingPathComponent("engine-setup.log"))
                    }
                    Spacer()
                    Button("Try Again") { python.install() }.buttonStyle(.borderedProminent)
                }
                .controlSize(.small)
            }
        }
    }
}

// MARK: - Add card

private struct AddCard: View {
    @ObservedObject var library: ModelLibrary
    @ObservedObject var server: ServerManager
    let checkInstead: (String) -> Void

    var body: some View {
        switch library.addState {
        case .idle:
            EmptyView()
        case .fetching:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Fetching model info from Hugging Face…").foregroundStyle(.secondary)
            }
            .transition(.opacity)
        case .checked(let info, let check):
            checked(info, check).transition(.opacity)
        case .downloading(let info, let done, let total):
            VStack(alignment: .leading, spacing: 6) {
                title(info)
                ProgressView(value: total > 0 ? min(Double(done) / Double(total), 1) : nil)
                HStack {
                    Text("Downloading · \(Self.size(done)) of \(Self.size(total))")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    Spacer()
                    Button("Cancel") { library.cancelDownload() }.controlSize(.small)
                }
            }
            .transition(.opacity)
        case .converting(let info):
            progress(info, "Shrinking to 4-bit so it fits in less memory…")
        case .testing(let info):
            progress(info, "Testing proofreading on 8 sample sentences…")
        case .ready(let info, let loadID, let result):
            VStack(alignment: .leading, spacing: 6) {
                Label("\(info.name) is ready to use", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                if let result {
                    Text("Fixed \(result.score) of \(result.total) test sentences · \(ModelsSection.seconds(result.avgMs)) each")
                        .font(.caption).foregroundStyle(.secondary)
                    if result.score * 2 < result.total {
                        Label(
                            "It got most test sentences wrong, so it probably won't proofread well. Larger models (1.5B+) do much better.",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.caption).foregroundStyle(.orange)
                    }
                }
                HStack {
                    Spacer()
                    Button("Done") { library.resetAdd() }
                    if loadID != server.modelID {
                        Button("Use This Model") {
                            server.select(model: loadID)
                            library.resetAdd()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .controlSize(.small)
            }
            .transition(.opacity)
        case .failed(let message):
            HStack {
                Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Spacer()
                Button("Dismiss") { library.resetAdd() }.controlSize(.small)
            }
            .transition(.opacity)
        }
    }

    private func checked(_ info: ModelLibrary.Inspection, _ check: ModelLibrary.SystemCheck) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                title(info)
                Spacer()
                badge(info)
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                if let type = info.modelType {
                    fact("Model", "\(type)" + (info.bits.map { " · \($0)-bit" } ?? (info.needsConversion ? " · full size" : "")))
                }
                if info.canInstall, info.installed != true, let bytes = info.downloadBytes {
                    fact("Download", Self.size(bytes))
                }
                if info.needsConversion, let bytes = info.convertedBytes {
                    fact("After shrinking", Self.size(bytes))
                }
                if let memory = info.memoryBytes, info.canInstall {
                    fact("Memory when in use", Self.memory(memory))
                }
            }
            .font(.callout)
            if info.canInstall, info.installed != true {
                VStack(alignment: .leading, spacing: 2) {
                    requirement(
                        check.fitsDisk, "Disk: \(Self.size(check.freeDisk)) free, needs \(Self.size(check.neededDisk))"
                    )
                    requirement(
                        check.fitsMemory && !check.memoryIsTight,
                        "Memory: \(Self.memory(check.ram)) on this Mac"
                            + (check.memoryIsTight ? " — this model would use most of it" : ""),
                        warningOnly: check.fitsMemory
                    )
                }
                .font(.caption)
            }
            ForEach(info.reasons, id: \.self) { reason in
                Text(reason).font(.caption).foregroundStyle(info.canInstall ? Color.secondary : .orange)
            }
            HStack {
                if let alternative = info.alternative, !info.canInstall || info.needsConversion {
                    Button("Check \(alternative) instead") { checkInstead(alternative) }
                        .buttonStyle(.link).font(.caption).lineLimit(1)
                }
                Spacer()
                Button("Cancel") { library.resetAdd() }
                if info.installed == true {
                    Button("Use This Model") {
                        server.select(model: library.installed.first { $0.id == info.id }?.loadID ?? info.id)
                        library.resetAdd()
                    }
                    .buttonStyle(.borderedProminent)
                } else if info.canInstall {
                    Button(info.needsConversion ? "Download & Shrink" : "Download \(Self.size(info.downloadBytes ?? 0))") {
                        library.install(info)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!check.fitsDisk || !check.fitsMemory)
                }
            }
            .controlSize(.small)
        }
    }

    private func title(_ info: ModelLibrary.Inspection) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(info.name).font(.headline).lineLimit(1)
            Text(info.id).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private func badge(_ info: ModelLibrary.Inspection) -> some View {
        let (text, color): (String, Color) = switch (info.installed == true, info.verdict) {
        case (true, _): ("Installed", .green)
        case (_, "ready"): ("Works here", .green)
        case (_, "convert"): ("Works after shrinking", .blue)
        default: ("Not supported", .orange)
        }
        return Text(text).font(.caption.weight(.medium)).foregroundStyle(color)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
    }

    private func fact(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value)
        }
    }

    private func requirement(_ ok: Bool, _ text: String, warningOnly: Bool = false) -> some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: ok ? "checkmark.circle.fill" : (warningOnly ? "exclamationmark.triangle.fill" : "xmark.circle.fill"))
                .foregroundStyle(ok ? .green : (warningOnly ? .orange : .red))
        }
    }

    private func progress(_ info: ModelLibrary.Inspection, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            title(info)
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(text).font(.caption).foregroundStyle(.secondary)
            }
        }
        .transition(.opacity)
    }

    static func size(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: bytes)
    }

    static func memory(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .memory)
    }
}

// MARK: - Per-model settings

struct ModelSettingsView: View {
    let modelID: String
    let name: String
    @ObservedObject var tuning: ModelSettingsStore
    @Environment(\.dismiss) private var dismiss
    @State private var settings = ModelSettings.standard

    private var isApple: Bool { modelID == AppleProofreader.settingsID }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    LabeledContent("Creativity") {
                        HStack {
                            Slider(value: $settings.temperature, in: 0...1, step: 0.1)
                            Text(settings.temperature.formatted(.number.precision(.fractionLength(1))))
                                .monospacedDigit().frame(width: 28)
                        }
                    }
                    if !isApple {
                        Toggle(isOn: $settings.thinking) {
                            Text("Let the model think first")
                            Text("For reasoning models. Slower; usually not needed to fix grammar.")
                        }
                    }
                    Toggle(isOn: $settings.keepStructure) {
                        Text("Protect formatting")
                        Text("Keeps Markdown, code and links exactly as they were.")
                    }
                } header: {
                    Text(name)
                } footer: {
                    Text("Creativity 0 gives the same answer every time and sticks closest to your wording.")
                }
                Section("Limits") {
                    stepper("Time limit", "\(settings.timeLimit) s", value: $settings.timeLimit, in: 10...300, step: 5)
                    stepper(
                        "Longest selection", "\(settings.maxSelection.formatted()) characters",
                        value: $settings.maxSelection, in: 1000...(isApple ? 8000 : 32000), step: 1000
                    )
                    if !isApple {
                        stepper(
                            "Answer budget",
                            "\(settings.answerLength.formatted(.number.precision(.fractionLength(1))))× the selection",
                            value: $settings.answerLength, in: 1.2...4, step: 0.2
                        )
                    }
                }
                Section {
                    TextEditor(text: $settings.instructions)
                        .font(.callout)
                        .frame(minHeight: 70)
                        .overlay(alignment: .topLeading) {
                            if settings.instructions.isEmpty {
                                Text("Built-in: fix spelling, grammar and punctuation only; keep wording, tone and formatting.")
                                    .font(.callout).foregroundStyle(.tertiary).padding(.top, 1).padding(.leading, 5)
                                    .allowsHitTesting(false)
                            }
                        }
                } header: {
                    Text("Instructions")
                } footer: {
                    Text("Leave empty to use the built-in proofreading instructions.")
                }
            }
            .formStyle(.grouped)
            HStack {
                Button("Reset to Defaults") { settings = ModelSettingsStore.defaults(for: modelID) }
                    .disabled(settings == ModelSettingsStore.defaults(for: modelID))
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    tuning.set(settings, for: modelID)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 440, height: 660)
        .onAppear { settings = tuning.settings(for: modelID) }
    }

    private func stepper<Value: Strideable>(
        _ title: String, _ shown: String, value: Binding<Value>, in range: ClosedRange<Value>, step: Value.Stride
    ) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(shown).foregroundStyle(.secondary).monospacedDigit()
            Stepper(title, value: value, in: range, step: step).labelsHidden()
        }
    }
}
