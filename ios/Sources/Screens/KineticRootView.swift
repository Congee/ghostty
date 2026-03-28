// KineticRootView — Top-level coordinator with tab bar and state management.

import SwiftUI

struct KineticRootView: View {
    @StateObject private var client = GSPClient()
    @StateObject private var browser = BonjourBrowser()
    @StateObject private var store = ConnectionStore()
    @State private var selectedTab: KineticTab = .sessions
    @State private var monitor: ConnectionMonitor?

    private var activeMonitor: ConnectionMonitor {
        if let monitor { return monitor }
        let m = ConnectionMonitor(client: client)
        DispatchQueue.main.async { self.monitor = m }
        return m
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            // accessibility root
            Color.clear.accessibilityIdentifier("kinetic-root")
            // Main content
            Group {
                if client.attachedSessionId != nil {
                    TerminalSessionView(
                        client: client,
                        monitor: activeMonitor,
                        selectedTab: $selectedTab
                    )
                } else {
                    tabContent
                }
            }

            // Tab bar (hidden when in terminal)
            if client.attachedSessionId == nil {
                KineticTabBar(selectedTab: $selectedTab)
                    .padding(.bottom, KineticSpacing.md)
            }
        }
        .background(KineticColor.surface)
        .preferredColorScheme(.dark)
        .onAppear {
            if monitor == nil {
                monitor = ConnectionMonitor(client: client)
            }
        }
    }

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .sessions:
            sessionsContent

        case .history:
            VStack(spacing: 0) {
                KineticTopBar(mode: .standard)

                ScrollView {
                    VStack(alignment: .leading, spacing: KineticSpacing.xl) {
                        KineticHeroHeader(
                            label: "",
                            title: "History",
                            subtitle: "Recent connection activity."
                        )

                    if store.history.isEmpty {
                        VStack(spacing: KineticSpacing.md) {
                            Image(systemName: "clock.arrow.circlepath")
                                .font(.system(size: 40))
                                .foregroundStyle(KineticColor.outlineVariant)
                            Text("No connection history")
                                .font(KineticFont.body)
                                .foregroundStyle(KineticColor.onSurfaceVariant)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, KineticSpacing.xxl)
                    } else {
                        ForEach(store.history) { entry in
                            historyCard(entry)
                        }
                    }

                    Spacer().frame(height: 100)
                }
                    .padding(.horizontal, KineticSpacing.md)
                }
            }
            .background(KineticColor.surface)

        case .settings:
            SettingsActivityView(
                store: store,
                monitor: activeMonitor
            )
        }
    }

    @ViewBuilder
    private var sessionsContent: some View {
        if client.connected && client.authenticated {
            ActiveSessionsView(
                client: client,
                monitor: activeMonitor,
                selectedTab: $selectedTab
            )
        } else {
            ConnectView(
                client: client,
                browser: browser,
                store: store,
                monitor: activeMonitor,
                selectedTab: $selectedTab
            )
        }
    }

    private func historyCard(_ entry: ConnectionHistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: KineticSpacing.xs) {
            HStack {
                Circle()
                    .fill(entry.endTime != nil ? KineticColor.onSurfaceVariant : KineticColor.primary)
                    .frame(width: 8, height: 8)

                Text(entry.nodeName)
                    .font(KineticFont.bodySmall)
                    .fontWeight(.bold)
                    .foregroundStyle(KineticColor.onSurface)

                Spacer()

                Text(entry.relativeTimeString)
                    .font(KineticFont.monoSmall)
                    .foregroundStyle(KineticColor.onSurfaceVariant)
            }

            Text(entry.durationString)
                .font(.system(size: 18, weight: .bold, design: .monospaced))
                .foregroundStyle(KineticColor.onSurface)
        }
        .padding(KineticSpacing.md)
        .containerCard()
    }
}
