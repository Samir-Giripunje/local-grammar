import AppKit
import ApplicationServices
import Foundation
import ServiceManagement

enum Accessibility {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func prompt() {
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    static func openSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}

@MainActor
final class SystemAccess: ObservableObject {
    @Published private(set) var accessibilityTrusted = Accessibility.isTrusted
    @Published private(set) var launchesAtLogin = SMAppService.mainApp.status == .enabled

    private var timer: Timer?

    init() {
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        try? enabled ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
        refresh()
    }

    func enableLaunchAtLoginOnFirstRun() {
        guard !UserDefaults.standard.bool(forKey: "loginItemConfigured") else { return }
        UserDefaults.standard.set(true, forKey: "loginItemConfigured")
        setLaunchAtLogin(true)
    }

    private func refresh() {
        accessibilityTrusted = Accessibility.isTrusted
        launchesAtLogin = SMAppService.mainApp.status == .enabled
    }
}
