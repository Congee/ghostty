// ActiveSessionsView — Session picker after connecting to a daemon.

import SwiftUI

struct ActiveSessionsView: View {
    @ObservedObject var client: GSPClient
    @ObservedObject var monitor: ConnectionMonitor
    @Binding var selectedTab: KineticTab

    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        VStack(spacing: 0) {
            KineticTopBar(mode: .standard)

            ScrollView {
                VStack(alignment: .leading, spacing: KineticSpacing.xl) {
                    // Node badge + hero header
                    VStack(alignment: .center, spacing: KineticSpacing.md) {
                        if let host = monitor.lastHost {
                            KineticStatusBadge(
                                text: "Remote Node: \(host)",
                                color: KineticColor.tertiary
                            )
                        }

                        KineticHeroHeader(
                            label: "",
                            title: "Active Sessions",
                            subtitle: "Multiple active environments detected. Select a process to attach or initiate a fresh container."
                        )
                    }

                    // Session list
                    if client.sessions.isEmpty {
                        VStack(spacing: KineticSpacing.md) {
                            Image(systemName: "terminal")
                                .font(.system(size: 40))
                                .foregroundStyle(KineticColor.outlineVariant)
                            Text("No active sessions")
                                .font(KineticFont.body)
                                .foregroundStyle(KineticColor.onSurfaceVariant)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, KineticSpacing.xxl)
                    } else {
                        sessionCards
                    }

                    // Action cards
                    actionCards

                    // Disconnect (mobile only)
                    if sizeClass != .regular {
                        Button {
                            monitor.disconnect()
                        } label: {
                            Text("Disconnect")
                                .font(KineticFont.body)
                                .fontWeight(.bold)
                                .foregroundStyle(KineticColor.error)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, KineticSpacing.md)
                        }
                    }

                    Spacer().frame(height: KineticSpacing.xxl)
                }
                .padding(.horizontal, KineticSpacing.md)
            }
        }
        .background(KineticColor.surface)
        .onAppear { client.listSessions() }
    }

    // MARK: - Session Cards

    @ViewBuilder
    private var sessionCards: some View {
        if sizeClass == .regular {
            LazyVGrid(columns: [
                GridItem(.flexible()),
                GridItem(.flexible()),
                GridItem(.flexible())
            ], spacing: KineticSpacing.sm) {
                ForEach(client.sessions) { session in
                    sessionCard(session)
                }
            }
        } else {
            VStack(spacing: KineticSpacing.sm) {
                ForEach(client.sessions) { session in
                    sessionCard(session)
                }
            }
        }
    }

    private func sessionCard(_ session: SessionInfo) -> some View {
        let name = !session.name.isEmpty ? session.name
            : !session.title.isEmpty ? session.title
            : "Session \(session.id)"

        return KineticSessionCard(
            icon: sessionIcon(session),
            name: name,
            idBadge: "PID: \(session.id)",
            startedText: session.pwd.isEmpty ? nil : session.pwd,
            activityText: session.childExited ? "Idle" : nil,
            isIdle: session.childExited,
            onTap: {
                client.attach(sessionId: session.id)
            }
        )
    }

    // MARK: - Action Cards

    @ViewBuilder
    private var actionCards: some View {
        let newSessionCard = VStack(alignment: .leading, spacing: KineticSpacing.md) {
            Image(systemName: "plus.square.fill")
                .font(.system(size: 28))
                .foregroundStyle(KineticColor.primary)

            Text("New Terminal Session")
                .font(KineticFont.bodySmall)
                .fontWeight(.bold)
                .foregroundStyle(KineticColor.onSurface)

            Text("Initialize a fresh environment with default configurations.")
                .font(KineticFont.caption)
                .foregroundStyle(KineticColor.onSurfaceVariant)

            Button("Create Container") {
                client.createSession()
            }
            .buttonStyle(KineticSecondaryButtonStyle())
        }
        .padding(KineticSpacing.md)
        .containerCard(color: KineticColor.surfaceContainerLow)

        let connectionSettingsCard = VStack(alignment: .leading, spacing: KineticSpacing.md) {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 28))
                .foregroundStyle(KineticColor.tertiary)

            Text("Connection Settings")
                .font(KineticFont.bodySmall)
                .fontWeight(.bold)
                .foregroundStyle(KineticColor.onSurface)

            Text("Configure SSH protocols, port forwarding, and auth keys.")
                .font(KineticFont.caption)
                .foregroundStyle(KineticColor.onSurfaceVariant)

            Button("Node Config") {
                selectedTab = .settings
            }
            .buttonStyle(KineticSecondaryButtonStyle())
        }
        .padding(KineticSpacing.md)
        .containerCard(color: KineticColor.surfaceContainerLow)

        if sizeClass == .regular {
            HStack(alignment: .top, spacing: KineticSpacing.sm) {
                newSessionCard
                connectionSettingsCard
            }
        } else {
            VStack(spacing: KineticSpacing.sm) {
                newSessionCard
                connectionSettingsCard
            }
        }
    }

    private func sessionIcon(_ session: SessionInfo) -> String {
        if session.childExited { return "terminal" }
        if session.attached { return "link" }
        return "terminal.fill"
    }
}
