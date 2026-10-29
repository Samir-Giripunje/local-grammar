import AppKit
import SwiftUI

struct ChipButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        ChipBody(configuration: configuration, prominent: prominent)
    }

    private struct ChipBody: View {
        let configuration: Configuration
        let prominent: Bool
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(prominent ? .body.weight(.semibold) : .callout)
                .padding(.horizontal, prominent ? 13 : 10)
                .padding(.vertical, prominent ? 5 : 3)
                .foregroundStyle(prominent ? Color.white : Color.primary)
                .background(RoundedRectangle(cornerRadius: 7).fill(fill))
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(Color.accentColor.opacity(hovering ? 0.9 : 0), lineWidth: 1.5)
                )
                .scaleEffect(configuration.isPressed ? 0.96 : hovering ? 1.05 : 1)
                .opacity(isEnabled ? 1 : 0.5)
                .animation(.easeOut(duration: 0.12), value: hovering)
                .pointingHand(hovering: $hovering)
        }

        private var fill: Color {
            prominent ? Color.accentColor.opacity(hovering ? 1 : 0.85) : Color.primary.opacity(hovering ? 0.2 : 0.1)
        }
    }
}

struct HoverLinkStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        LinkBody(configuration: configuration)
    }

    private struct LinkBody: View {
        let configuration: Configuration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.caption)
                .foregroundStyle(Color.accentColor.opacity(configuration.isPressed ? 0.6 : 1))
                .underline(hovering)
                .pointingHand(hovering: $hovering)
        }
    }
}

extension View {
    func pointingHand(hovering: Binding<Bool>) -> some View {
        onHover { inside in
            guard inside != hovering.wrappedValue else { return }
            hovering.wrappedValue = inside
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }
}
