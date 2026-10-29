import SwiftUI

struct FixView: View {
    @ObservedObject var controller: FixController

    var body: some View {
        content
            .padding(14)
            .frame(width: 460, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
    }

    @ViewBuilder
    private var content: some View {
        switch controller.state {
        case .checking:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Checking…").foregroundStyle(.secondary)
            }
        case .loadingModel:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Loading the model into memory…").foregroundStyle(.secondary)
            }
        case .noSelection:
            message("text.cursor", "Select some text first, then press ⌥⌘G.")
        case .needsAccess:
            message(
                "lock.shield",
                "Allow Local Grammar in System Settings → Privacy & Security → Accessibility, then try again."
            )
        case .copied:
            message(
                "doc.on.clipboard.fill",
                "This app doesn't let me check your selection, so the fix is copied — press ⌘V to paste it.",
                tint: .blue
            )
        case .replaced:
            message("checkmark.circle.fill", "Replaced · ⌘Z to undo", tint: .green)
        case .unchanged:
            message("checkmark.circle.fill", "Looks good — no changes needed.", tint: .green)
        case .failed(let reason):
            message("exclamationmark.triangle.fill", reason, tint: .orange)
        case .reviewing:
            EmptyView()
        }
    }

    private func message(_ symbol: String, _ text: String, tint: Color = .secondary) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}
