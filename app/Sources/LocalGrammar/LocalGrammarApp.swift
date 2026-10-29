import Carbon.HIToolbox
import SwiftUI

@main
struct LocalGrammarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(
                server: delegate.server, library: delegate.library, access: delegate.access, spell: delegate.spell,
                autocorrect: delegate.autocorrect, controller: delegate.controller,
                openWindow: { delegate.mainWindow.show() }
            )
        } label: {
            StatusIcon(server: delegate.server)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let server = ServerManager()
    let access = SystemAccess()
    let spell = SpellWatcher()
    let library = ModelLibrary()
    let python = PythonEngine()
    lazy var autocorrect = AutoCorrector(spell: spell)
    lazy var controller = FixController(server: server)
    lazy var mainWindow = MainWindowController { [unowned self] in
        AnyView(MainView(
            server: server, library: library, python: python, spell: spell, autocorrect: autocorrect, access: access
        ))
    }
    private var hotKey: HotKey?

    func applicationDidFinishLaunching(_ notification: Notification) {
        signal(SIGPIPE, SIG_IGN)
        if server.engine == .qwen, server.keepsLoaded { server.start() }
        spell.start()
        autocorrect.start()
        library.refresh()
        if !UserDefaults.standard.bool(forKey: "mainWindowShown") {
            UserDefaults.standard.set(true, forKey: "mainWindowShown")
            mainWindow.show()
        }
        access.enableLaunchAtLoginOnFirstRun()
        if !Accessibility.isTrusted { Accessibility.prompt() }
        hotKey = HotKey(keyCode: kVK_ANSI_G, modifiers: cmdKey | optionKey) { [weak self] in
            Task { @MainActor in self?.controller.run() }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        mainWindow.show()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        server.stop()
    }
}

struct StatusIcon: View {
    @ObservedObject var server: ServerManager

    var body: some View {
        switch server.status {
        case .ready, .stopped: logo
        case .loading: Image(systemName: "hourglass")
        case .failed: Image(systemName: "exclamationmark.triangle")
        }
    }

    private static let menuBarImage: NSImage? = {
        let image = Bundle.main.image(forResource: "MenuBarIcon")
        image?.isTemplate = true
        return image
    }()

    @ViewBuilder
    private var logo: some View {
        if let image = Self.menuBarImage {
            Image(nsImage: image)
        } else {
            Image(systemName: "text.badge.checkmark")
        }
    }
}

struct MenuContent: View {
    @ObservedObject var server: ServerManager
    @ObservedObject var library: ModelLibrary
    @ObservedObject var access: SystemAccess
    @ObservedObject var spell: SpellWatcher
    @ObservedObject var autocorrect: AutoCorrector
    let controller: FixController
    let openWindow: () -> Void

    var body: some View {
        spellStatus
        Divider()
        Text(statusLine)
        Button("Fix Selected Text  ⌥⌘G") { controller.run() }
        Picker("Proofread With", selection: $server.engine) {
            ForEach(ProofreadingEngine.allCases) { Text($0.title).tag($0) }
        }
        if server.engine == .qwen, server.qwenIsSetUp {
            Toggle("Keep Model Loaded", isOn: $server.keepsLoaded)
        }
        if server.engine == .qwen, !library.usable.isEmpty {
            Picker("Model", selection: Binding(get: { server.modelID }, set: { server.select(model: $0) })) {
                ForEach(library.usable) { model in
                    Text(model.name).tag(model.loadID)
                }
            }
        }
        Divider()
        Toggle("Live Spell Check", isOn: $spell.isEnabled)
        Toggle("Autocorrect", isOn: $autocorrect.isEnabled)
        Picker("English", selection: $spell.dialect) {
            ForEach(EnglishDialect.allCases) { dialect in
                Text(dialect.rawValue).tag(dialect)
            }
        }
        if let app = otherFrontmostApp, let bundleID = app.bundleIdentifier {
            let disabled = spell.disabledApps.contains(bundleID)
            Button("\(disabled ? "Enable" : "Disable") Spell Check in \(app.localizedName ?? bundleID)") {
                spell.toggle(app: bundleID)
            }
        }
        Divider()
        Button("Open Local Grammar…") { openWindow() }
            .keyboardShortcut(",")
        Toggle("Launch at Login", isOn: Binding(get: { access.launchesAtLogin }, set: { access.setLaunchAtLogin($0) }))
        if !access.accessibilityTrusted {
            Button("Grant Accessibility Access…") { Accessibility.prompt() }
        }
        Button("Open Server Log") { NSWorkspace.shared.open(ServerManager.logFile) }
        Divider()
        Button("Quit Local Grammar") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    @ViewBuilder
    private var spellStatus: some View {
        switch spell.status {
        case .off:
            Text("Live spell check is off")
        case .needsAccess:
            Text("Needs Accessibility permission")
            Button("Open Accessibility Settings…") { Accessibility.openSettings() }
        case .disabled(let app, let bundleID):
            Text("Off in \(app)")
            Button("Turn On in \(app)") { spell.toggle(app: bundleID) }
        case .unreadable(let app, let pid):
            Text("Can't read \(app)'s text right now")
            Button("Reconnect to \(app)") { spell.reconnect(pid: pid) }
        case .noField(let app):
            Text("Click into a text box in \(app) to start checking")
        case .passwordField:
            Text("Password fields are never read")
        case .tooLong(let app):
            Text("This text in \(app) is too long to check live (over \(SpellWatcher.maxLength.formatted()) characters)")
            Text("Select up to \(server.settings.maxSelection.formatted()) characters and press ⌥⌘G to proofread a part")
        case .checking(let app, let underlines):
            Text(underlines ? "✓ Checking in \(app)" : "◐ Checking in \(app) — no underlines here, use the badge")
        }
    }

    private var otherFrontmostApp: NSRunningApplication? {
        let app = NSWorkspace.shared.frontmostApplication
        return app?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : app
    }

    private var statusLine: String {
        if server.engine == .apple {
            if case .unavailable(let reason) = AppleProofreader.status { return reason }
            return "Ready · Apple Intelligence"
        }
        guard server.qwenIsSetUp else { return "Qwen isn't set up · open Local Grammar" }
        let model = library.name(for: server.modelID) ?? GrammarModel.named(server.modelID)
        switch server.status {
        case .ready:
            let memory = server.memoryBytes.map { " · \(MainView.format($0))" } ?? ""
            return "Ready · \(model)\(memory)"
        case .loading: return GrammarModel.isDownloaded(server.modelID) ? "Loading \(model)…" : "Downloading \(model)…"
        case .stopped: return "Model unloaded · loads on ⌥⌘G"
        case .failed(let reason): return "Error: \(reason)"
        }
    }

}
