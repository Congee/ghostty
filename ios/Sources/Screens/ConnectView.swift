// ConnectView — "Connect to Server" entry screen.

import SwiftUI
import Network

struct ConnectView: View {
    @ObservedObject var client: GSPClient
    @ObservedObject var browser: BonjourBrowser
    @ObservedObject var store: ConnectionStore
    @ObservedObject var monitor: ConnectionMonitor

    @Binding var selectedTab: KineticTab
    @State private var host = ""
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        VStack(spacing: 0) {
            KineticTopBar(mode: .standard)

            ScrollView {
                if sizeClass == .regular {
                    tabletLayout
                } else {
                    mobileLayout
                }
            }
        }
        .background(KineticColor.surface)
        .onAppear { browser.startBrowsing() }
        .onDisappear { browser.stopBrowsing() }
    }

    // MARK: - Mobile Layout

    private var mobileLayout: some View {
        VStack(alignment: .leading, spacing: KineticSpacing.xl) {
            heroSection
            inputSection
            errorBanner
            buttonSection
            featureCards

            recentConnectionsSection
            bonjourSection
            KineticClusterStatusCard()

            Spacer().frame(height: KineticSpacing.xxl)
        }
        .padding(.horizontal, KineticSpacing.md)
    }

    // MARK: - Tablet Layout

    private var tabletLayout: some View {
        HStack(alignment: .top, spacing: KineticSpacing.lg) {
            // Left column: hero + input + buttons + features
            VStack(alignment: .leading, spacing: KineticSpacing.xl) {
                heroSection
                inputSection
                errorBanner
                buttonSection
                featureCards
                bonjourSection
            }
            .frame(maxWidth: .infinity)

            // Right column: session history + cluster status
            VStack(alignment: .leading, spacing: KineticSpacing.xl) {
                sessionHistoryPanel
                KineticClusterStatusCard()
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, KineticSpacing.md)
        .padding(.top, KineticSpacing.md)
    }

    // MARK: - Shared Sections

    private var heroSection: some View {
        KineticHeroHeader(
            label: "System Ready",
            title: "Connect to\nServer",
            subtitle: "Establish a secure SSH tunneling protocol to your remote infrastructure via the monolithic interface."
        )
    }

    private var inputSection: some View {
        VStack(alignment: .leading, spacing: KineticSpacing.sm) {
            KineticSectionLabel(text: "Machine Address")

            KineticInputField(
                placeholder: "user@192.168.1.1 or hostname",
                text: $host,
                icon: "qrcode.viewfinder"
            )
            .accessibilityIdentifier("connect-host-input")
        }
    }

    @ViewBuilder
    private var errorBanner: some View {
        if let error = client.lastError {
            Text(error)
                .font(KineticFont.monoSmall)
                .foregroundStyle(KineticColor.error)
                .padding(KineticSpacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(KineticColor.error.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: KineticRadius.button))
        }
    }

    private var buttonSection: some View {
        VStack(spacing: KineticSpacing.sm) {
            Button {
                connectManual()
            } label: {
                HStack {
                    Text("Connect")
                    Image(systemName: "arrow.right")
                }
            }
            .buttonStyle(KineticPrimaryButtonStyle())
            .disabled(host.isEmpty)
            .opacity(host.isEmpty ? 0.5 : 1.0)
            .accessibilityIdentifier("connect-button")

            Button("Settings") {
                selectedTab = .settings
            }
            .buttonStyle(KineticSecondaryButtonStyle())
            .accessibilityIdentifier("settings-button")
        }
    }

    private var featureCards: some View {
        HStack(spacing: KineticSpacing.sm) {
            KineticFeatureCard(
                icon: "shield.checkered",
                title: "Encrypted Tunnel",
                description: "AES-256-GCM encryption layers applied to all outgoing terminal packets automatically."
            )

            KineticFeatureCard(
                icon: "bolt.fill",
                title: "Low Latency",
                description: "Optimized buffer handling for real-time visual feedback and command execution.",
                iconColor: KineticColor.primaryContainer
            )
        }
    }

    @ViewBuilder
    private var recentConnectionsSection: some View {
        if !store.history.isEmpty {
            connectionHistorySection(title: "Recent Connections", limit: 3)
        }
    }

    private var sessionHistoryPanel: some View {
        connectionHistorySection(title: "Session History", limit: 5, showEmptyState: true)
    }

    private func connectionHistorySection(title: String, limit: Int, showEmptyState: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: KineticSpacing.sm) {
            KineticSectionLabel(
                text: title,
                trailing: AnyView(
                    Button("Clear All") {
                        store.clearHistory()
                    }
                    .font(KineticFont.caption)
                    .fontWeight(.bold)
                    .foregroundStyle(KineticColor.primary)
                )
            )

            if store.history.isEmpty && showEmptyState {
                Text("No recent connections")
                    .font(KineticFont.caption)
                    .foregroundStyle(KineticColor.onSurfaceVariant)
                    .padding(.vertical, KineticSpacing.md)
            } else {
                ForEach(store.history.prefix(limit)) { entry in
                    KineticSessionHistoryRow(
                        icon: "server.rack",
                        host: entry.host,
                        subtitle: "Connected \(entry.relativeTimeString)",
                        onTap: {
                            host = entry.host
                            connectManual()
                        }
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var bonjourSection: some View {
        if !browser.daemons.isEmpty || browser.isSearching {
            VStack(alignment: .leading, spacing: KineticSpacing.sm) {
                KineticSectionLabel(text: "Discovered on Network")

                if browser.isSearching && browser.daemons.isEmpty {
                    HStack(spacing: KineticSpacing.sm) {
                        ProgressView()
                            .tint(KineticColor.primary)
                        Text("Searching...")
                            .font(KineticFont.caption)
                            .foregroundStyle(KineticColor.onSurfaceVariant)
                    }
                    .padding(KineticSpacing.md)
                }

                ForEach(browser.daemons) { daemon in
                    KineticSessionHistoryRow(
                        icon: "terminal",
                        host: daemon.name,
                        subtitle: "LAN · Tap to connect",
                        onTap: {
                            connectToEndpoint(daemon.endpoint)
                        }
                    )
                }
            }
        }
    }

    // MARK: - Actions

    private func connectManual() {
        guard !host.isEmpty else { return }
        // Parse host:port from single field
        var targetHost = host
        var targetPort: UInt16 = 7337
        if let colonIndex = host.lastIndex(of: ":"),
           let port = UInt16(host[host.index(after: colonIndex)...]) {
            targetHost = String(host[..<colonIndex])
            targetPort = port
        }
        monitor.connect(host: targetHost, port: targetPort, authKey: "")
        _ = store.recordConnection(nodeName: targetHost, host: targetHost)
    }

    private func connectToEndpoint(_ endpoint: NWEndpoint) {
        let params = NWParameters.tcp
        let conn = NWConnection(to: endpoint, using: params)
        conn.stateUpdateHandler = { [weak monitor] state in
            if case .ready = state {
                if let path = conn.currentPath,
                   let remoteEndpoint = path.remoteEndpoint,
                   case .hostPort(let h, let p) = remoteEndpoint {
                    conn.cancel()
                    Task { @MainActor in
                        monitor?.connect(host: "\(h)", port: p.rawValue, authKey: "")
                    }
                }
            }
        }
        conn.start(queue: DispatchQueue(label: "resolve"))
    }
}
