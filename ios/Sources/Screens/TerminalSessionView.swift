// TerminalSessionView — Terminal view when attached to a remote session.

import SwiftUI

struct TerminalSessionView: View {
    @ObservedObject var client: GSPClient
    @ObservedObject var monitor: ConnectionMonitor
    @Binding var selectedTab: KineticTab

    @State private var inputText = ""
    @State private var ctrlActive = false
    @State private var altActive = false

    @Environment(\.horizontalSizeClass) private var sizeClass

    private var sessionName: String {
        guard let sessionId = client.attachedSessionId else { return "—" }
        if let session = client.sessions.first(where: { $0.id == sessionId }) {
            if !session.name.isEmpty { return session.name }
            if !session.title.isEmpty { return session.title }
        }
        return "Session \(sessionId)"
    }

    private var isConnectionLost: Bool {
        if case .connectionLost = monitor.status { return true }
        return false
    }

    var body: some View {
        VStack(spacing: 0) {
            // Top bar with session info
            KineticTopBar(mode: .terminal(
                sessionName: sessionName,
                isDisconnected: isConnectionLost
            ))

            // Connection info bar (tablet only)
            if sizeClass == .regular {
                KineticConnectionInfoBar()
            }

            // Connection lost banner
            if case .connectionLost(let reason) = monitor.status {
                ConnectionLostBanner(
                    reason: reason,
                    onReconnect: { monitor.reconnect() },
                    onSettings: { selectedTab = .settings }
                )
            }

            // Terminal + optional metrics sidebar
            HStack(spacing: 0) {
                RemoteTerminalView(screen: client.screen) { cols, rows in
                    client.sendResize(cols: cols, rows: rows)
                }
                .opacity(isConnectionLost ? 0.4 : 1.0)
                .ignoresSafeArea(.keyboard)

                if sizeClass == .regular {
                    KineticMetricsSidebar(isDisconnected: isConnectionLost)
                }
            }

            // Modifier key bar
            modifierKeyBar

            // Command input bar
            KineticCommandBar(
                text: $inputText,
                isDisabled: isConnectionLost,
                placeholder: isConnectionLost
                    ? (sizeClass == .regular ? "Reconnecting..." : "Connection lost...")
                    : (sizeClass == .regular ? "Execute command..." : "Type a command..."),
                onSubmit: { sendCommand() }
            )
        }
        .background(KineticColor.surface)
    }

    // MARK: - Modifier Key Bar

    private var modifierKeyBar: some View {
        HStack(spacing: KineticSpacing.sm) {
            if sizeClass == .regular {
                // Tablet: ESC, CTRL, ALT, TAB + arrows
                ModifierKeyButton(label: "ESC") {
                    client.sendInputBytes(Data([0x1b]))
                }
            }

            ModifierKeyButton(label: "CTRL", isActive: ctrlActive) {
                ctrlActive.toggle()
            }

            ModifierKeyButton(label: "ALT", isActive: altActive) {
                altActive.toggle()
            }

            ModifierKeyButton(label: "TAB") {
                client.sendInputBytes(Data([0x09]))
            }

            Spacer()

            ModifierKeyButton(label: "\u{2191}") {
                client.sendInputBytes(Data([0x1b, 0x5b, 0x41])) // Up
            }

            ModifierKeyButton(label: "\u{2193}") {
                client.sendInputBytes(Data([0x1b, 0x5b, 0x42])) // Down
            }

            if sizeClass != .regular {
                // Mobile: add back arrow
                ModifierKeyButton(label: "\u{2190}") {
                    client.sendInputBytes(Data([0x1b, 0x5b, 0x44])) // Left
                }
            }
        }
        .padding(.horizontal, KineticSpacing.md)
        .padding(.vertical, KineticSpacing.sm)
        .background(KineticColor.surfaceContainerHighest.opacity(0.6))
        .glassMorphism(cornerRadius: 0)
    }

    // MARK: - Command Handling

    private func sendCommand() {
        guard !inputText.isEmpty else { return }

        var text = inputText
        if ctrlActive {
            if let first = text.first, first.isLetter {
                let code = UInt8(first.uppercased().first!.asciiValue! - 64)
                client.sendInputBytes(Data([code]))
                ctrlActive = false
                inputText = ""
                return
            }
        }

        if altActive {
            text = "\u{1b}" + text
            altActive = false
        }

        client.sendInput(text + "\r")
        inputText = ""
    }
}
