import AppKit
import SwiftUI

@MainActor
final class MainWindowController {
    private var window: NSWindow?
    private let makeView: () -> AnyView

    init(makeView: @escaping () -> AnyView) {
        self.makeView = makeView
    }

    func show() {
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 460, height: 600),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Local Grammar"
            window.isReleasedWhenClosed = false
            window.contentMinSize = NSSize(width: 460, height: 420)
            window.contentMaxSize = NSSize(width: 460, height: 2000)
            window.contentView = NSHostingView(rootView: makeView())
            window.center()
            window.setFrameAutosaveName("LocalGrammarSettings")
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

enum AppLogo {
    static let image: NSImage? = Bundle.main.url(forResource: "Logo", withExtension: "png").flatMap(NSImage.init)
}

struct MainView: View {
    @ObservedObject var server: ServerManager
    @ObservedObject var library: ModelLibrary
    @ObservedObject var python: PythonEngine
    @ObservedObject var spell: SpellWatcher
    @ObservedObject var autocorrect: AutoCorrector
    @ObservedObject var access: SystemAccess

    var body: some View {
        Form {
            Section {
                header
            }
            if !access.accessibilityTrusted {
                Section {
                    HStack {
                        Label("Accessibility access is needed", systemImage: "lock.shield")
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("Open Settings…") { Accessibility.openSettings() }
                    }
                }
            }
            ModelsSection(server: server, library: library, python: python, tuning: server.tuning)
            Section("Writing") {
                Toggle("Spelling & grammar underlines", isOn: $spell.isEnabled)
                Toggle(isOn: $autocorrect.isEnabled) {
                    Text("Autocorrect as you type")
                    Text("Press Delete right after a correction to undo it")
                }
                Picker("English", selection: $spell.dialect) {
                    ForEach(EnglishDialect.allCases) { Text($0.rawValue).tag($0) }
                }
            }
            if !autocorrect.recent.isEmpty || !autocorrect.exceptions.isEmpty {
                Section("Autocorrect") {
                    if !autocorrect.recent.isEmpty {
                        LabeledContent("Recent") {
                            Text(autocorrect.recent.prefix(4).map { "\($0.original) → \($0.corrected)" }.joined(separator: ", "))
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                    if !autocorrect.exceptions.isEmpty {
                        LabeledContent("Never correct") {
                            FlowLayout(spacing: 4) {
                                ForEach(autocorrect.exceptions, id: \.self) { word in
                                    Chip(text: word) { autocorrect.removeException(word) }
                                }
                            }
                        }
                    }
                }
            }
            if !spell.disabledApps.isEmpty {
                Section("Turned off in") {
                    ForEach(spell.disabledApps.sorted(), id: \.self) { bundleID in
                        HStack {
                            AppName(bundleID: bundleID)
                            Spacer()
                            Button("Turn On") { spell.toggle(app: bundleID) }.controlSize(.small)
                        }
                    }
                }
            }
            TimingSection()
            Section("General") {
                LabeledContent("Proofread selection", value: "⌥⌘G")
                Toggle(
                    "Open at login",
                    isOn: Binding(get: { access.launchesAtLogin }, set: { access.setLaunchAtLogin($0) })
                )
                HStack {
                    Button("Open Logs") {
                        try? FileManager.default.createDirectory(at: PythonEngine.logs, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(PythonEngine.logs)
                    }
                    Spacer()
                    Button("Quit") { NSApp.terminate(nil) }
                }
                .controlSize(.small)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .frame(minHeight: 420)
        .onAppear { library.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            library.refresh()
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Group {
                if let logo = AppLogo.image {
                    Image(nsImage: logo).resizable()
                } else {
                    Image(systemName: "text.badge.checkmark").resizable().scaledToFit()
                }
            }
            .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 1) {
                Text("Local Grammar").font(.headline)
                Text("Runs on this Mac. Nothing leaves it.").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            StatusPill(server: server)
        }
    }

    static func format(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }
}

/// Timing for underlines and autocorrect. The same for every model: neither uses the AI model.
private struct TimingSection: View {
    @AppStorage(CheckingTiming.interval.key) private var interval = CheckingTiming.interval.standard
    @AppStorage(CheckingTiming.typingPause.key) private var typingPause = CheckingTiming.typingPause.standard
    @AppStorage(CheckingTiming.hoverDelay.key) private var hoverDelay = CheckingTiming.hoverDelay.standard
    @AppStorage(CheckingTiming.liveLimit.key) private var liveLimit = CheckingTiming.liveLimit.standard
    @State private var expanded = false

    var body: some View {
        Section {
            DisclosureGroup("Checking speed", isExpanded: $expanded) {
                slider("Check text every", value: $interval, in: 0.1...1, step: 0.1, unit: "s")
                slider("Flag the word you're typing after", value: $typingPause, in: 0.3...3, step: 0.1, unit: "s")
                slider("Open suggestions on hover after", value: $hoverDelay, in: 0.1...1.5, step: 0.1, unit: "s")
                Stepper(value: $liveLimit, in: 5000...50000, step: 5000) {
                    LabeledContent("Check live up to", value: "\(Int(liveLimit).formatted()) characters")
                }
                HStack {
                    Spacer()
                    Button("Reset to Defaults") {
                        interval = CheckingTiming.interval.standard
                        typingPause = CheckingTiming.typingPause.standard
                        hoverDelay = CheckingTiming.hoverDelay.standard
                        liveLimit = CheckingTiming.liveLimit.standard
                    }
                    .controlSize(.small)
                }
            }
        } footer: {
            Text("Underlines and autocorrect come from macOS and Harper, not the AI model, so these apply to every model.")
        }
    }

    private func slider(
        _ title: String, value: Binding<Double>, in range: ClosedRange<Double>, step: Double, unit: String
    ) -> some View {
        LabeledContent(title) {
            HStack {
                Slider(value: value, in: range, step: step).frame(width: 120)
                Text("\(value.wrappedValue.formatted(.number.precision(.fractionLength(1)))) \(unit)")
                    .monospacedDigit().frame(width: 40, alignment: .trailing)
            }
        }
    }
}

// MARK: - Components

private struct StatusPill: View {
    @ObservedObject var server: ServerManager

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text).font(.caption)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(color.opacity(0.12), in: Capsule())
    }

    private var text: String {
        if server.engine == .apple { return AppleProofreader.isAvailable ? "Apple Intelligence" : "Not available" }
        switch server.status {
        case .ready: return "Model loaded"
        case .loading: return "Loading…"
        case .stopped: return "Model unloaded"
        case .failed: return "Model error"
        }
    }

    private var color: Color {
        if server.engine == .apple { return AppleProofreader.isAvailable ? .green : .orange }
        switch server.status {
        case .ready: return .green
        case .loading: return .orange
        case .stopped: return .secondary
        case .failed: return .red
        }
    }
}

private struct Chip: View {
    let text: String
    let onRemove: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 4) {
            Text(text)
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill").foregroundStyle(hovering ? .primary : .secondary)
            }
            .buttonStyle(.plain)
            .help("Allow autocorrecting “\(text)” again")
        }
        .font(.caption)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(.quaternary, in: Capsule())
        .onHover { hovering = $0 }
    }
}

private struct AppName: View {
    let bundleID: String

    var body: some View {
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        HStack(spacing: 8) {
            if let url {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 16, height: 16)
            }
            Text(url.map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") }
                ?? bundleID)
        }
    }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width == .infinity ? x : width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
