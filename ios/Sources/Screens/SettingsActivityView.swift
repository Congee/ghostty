// SettingsActivityView — Settings and activity tab.

import SwiftUI

struct SettingsActivityView: View {
    @ObservedObject var store: ConnectionStore
    @ObservedObject var monitor: ConnectionMonitor

    @State private var showAddNode = false
    @State private var newNodeName = ""
    @State private var newNodeHost = ""
    @State private var newNodePort = "7337"

    var body: some View {
        VStack(spacing: 0) {
            KineticTopBar(mode: .standard)

            ScrollView {
                settingsContent
            }
        }
        .background(KineticColor.surface)
        .sheet(isPresented: $showAddNode) {
            addNodeSheet
        }
    }

    private var settingsContent: some View {
        VStack(alignment: .leading, spacing: KineticSpacing.xl) {
            KineticHeroHeader(
                label: "",
                title: "Settings &\nActivity",
                subtitle: "Manage your nodes, keys, and session history."
            )

                // Saved Nodes
                VStack(alignment: .leading, spacing: KineticSpacing.sm) {
                    KineticSectionLabel(text: "Saved Nodes")

                    ForEach(store.savedNodes) { node in
                        HStack {
                            Image(systemName: "server.rack")
                                .font(.system(size: 20))
                                .foregroundStyle(KineticColor.primary)
                                .frame(width: 40, height: 40)
                                .background(KineticColor.surfaceContainerHighest)
                                .clipShape(RoundedRectangle(cornerRadius: KineticRadius.button))

                            VStack(alignment: .leading, spacing: 2) {
                                Text(node.name)
                                    .font(KineticFont.bodySmall)
                                    .fontWeight(.bold)
                                    .foregroundStyle(KineticColor.onSurface)
                                Text("\(node.host):\(node.port)")
                                    .font(KineticFont.monoSmall)
                                    .foregroundStyle(KineticColor.onSurfaceVariant)
                            }

                            Spacer()

                            Image(systemName: "chevron.right")
                                .font(.system(size: 14))
                                .foregroundStyle(KineticColor.outlineVariant)
                        }
                        .padding(KineticSpacing.md)
                        .containerCard()
                    }

                    Button {
                        showAddNode = true
                    } label: {
                        HStack {
                            Image(systemName: "plus")
                                .foregroundStyle(KineticColor.primary)
                            Text("Register New Node")
                                .font(KineticFont.bodySmall)
                                .foregroundStyle(KineticColor.primary)
                        }
                    }
                    .accessibilityIdentifier("add-node-button")
                    .padding(.top, KineticSpacing.xs)
                }

                // Security & Preferences
                VStack(alignment: .leading, spacing: KineticSpacing.sm) {
                    KineticSectionLabel(text: "Security & Preferences")

                    settingsRow(icon: "key.fill", title: "SSH Key Management", subtitle: "2 keys active")
                    settingsRow(icon: "paintbrush.fill", title: "Appearance", subtitle: "Monolithic Dark")
                    settingsRow(icon: "bell.fill", title: "Notifications", subtitle: "Alerts for failed sessions", hasToggle: true)
                }

                // Recent History
                if !store.history.isEmpty {
                    VStack(alignment: .leading, spacing: KineticSpacing.sm) {
                        KineticSectionLabel(
                            text: "Recent History",
                            trailing: AnyView(
                                Button("Clear All") {
                                    store.clearHistory()
                                }
                                .font(KineticFont.caption)
                                .fontWeight(.bold)
                                .foregroundStyle(KineticColor.primary)
                            )
                        )

                        ForEach(store.history.prefix(5)) { entry in
                            VStack(alignment: .leading, spacing: KineticSpacing.xs) {
                                HStack {
                                    Circle()
                                        .fill(historyDotColor(entry))
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

                                if entry.status == .timedOut {
                                    HStack {
                                        Text("STATUS")
                                            .font(KineticFont.sectionLabel)
                                            .foregroundStyle(KineticColor.onSurfaceVariant)

                                        Text("Timed Out")
                                            .font(.system(size: 20, weight: .bold, design: .monospaced))
                                            .foregroundStyle(KineticColor.error)

                                        Spacer()

                                        Button("DETAILS") {}
                                            .buttonStyle(KineticSmallButtonStyle())
                                    }
                                } else {
                                    HStack {
                                        Text("DURATION")
                                            .font(KineticFont.sectionLabel)
                                            .foregroundStyle(KineticColor.onSurfaceVariant)

                                        Text(entry.durationString)
                                            .font(.system(size: 20, weight: .bold, design: .monospaced))
                                            .foregroundStyle(KineticColor.onSurface)
                                    }
                                }
                            }
                            .padding(KineticSpacing.md)
                            .containerCard()
                        }

                        if store.history.count > 5 {
                            Text("VIEW FULL LOGS (\(store.history.count))")
                                .font(KineticFont.sectionLabel)
                                .tracking(2)
                                .foregroundStyle(KineticColor.onSurfaceVariant)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, KineticSpacing.md)
                        }
                    }
                }

                // System Control
                VStack(alignment: .leading, spacing: KineticSpacing.sm) {
                    KineticSectionLabel(text: "System Control")

                    Button {
                        store.clearHistory()
                    } label: {
                        HStack {
                            Image(systemName: "arrow.counterclockwise")
                                .foregroundStyle(KineticColor.primary)
                            Text("Flush All Connection Tokens")
                                .font(KineticFont.bodySmall)
                                .foregroundStyle(KineticColor.primary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundStyle(KineticColor.outlineVariant)
                        }
                        .padding(KineticSpacing.md)
                        .containerCard(color: KineticColor.surfaceContainerHigh)
                    }
                    .accessibilityIdentifier("flush-tokens-button")

                    Button {
                        monitor.disconnect()
                    } label: {
                        HStack {
                            Image(systemName: "rectangle.portrait.and.arrow.right")
                                .foregroundStyle(KineticColor.error)
                            Text("Sign Out of Ghostty")
                                .font(KineticFont.bodySmall)
                                .foregroundStyle(KineticColor.error)
                            Spacer()
                        }
                        .padding(KineticSpacing.md)
                        .containerCard(color: KineticColor.surfaceContainerHigh)
                    }
                    .accessibilityIdentifier("sign-out-button")
                }

                Spacer().frame(height: KineticSpacing.xxl)
            }
            .padding(.horizontal, KineticSpacing.md)
        }

    private func historyDotColor(_ entry: ConnectionHistoryEntry) -> Color {
        if entry.status == .timedOut { return KineticColor.error }
        if entry.endTime == nil { return KineticColor.tertiary }  // active
        return KineticColor.onSurfaceVariant  // completed
    }

    private func settingsRow(icon: String, title: String, subtitle: String, hasToggle: Bool = false) -> some View {
        HStack {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundStyle(KineticColor.onSurfaceVariant)
                .frame(width: 40, height: 40)
                .background(KineticColor.surfaceContainerHighest)
                .clipShape(RoundedRectangle(cornerRadius: KineticRadius.button))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(KineticFont.bodySmall)
                    .foregroundStyle(KineticColor.onSurface)
                Text(subtitle)
                    .font(KineticFont.caption)
                    .foregroundStyle(KineticColor.onSurfaceVariant)
            }

            Spacer()

            if hasToggle {
                Toggle("", isOn: .constant(true))
                    .tint(KineticColor.primary)
                    .labelsHidden()
            } else {
                Image(systemName: "chevron.right")
                    .font(.system(size: 14))
                    .foregroundStyle(KineticColor.outlineVariant)
            }
        }
        .padding(KineticSpacing.md)
        .containerCard()
    }

    private var addNodeSheet: some View {
        NavigationStack {
            VStack(spacing: KineticSpacing.md) {
                KineticInputField(placeholder: "Node name", text: $newNodeName)
                KineticInputField(placeholder: "Host (e.g. 192.168.1.105)", text: $newNodeHost)
                KineticInputField(placeholder: "Port", text: $newNodePort, keyboardType: .numberPad)

                Button("Save Node") {
                    let node = SavedNode(
                        name: newNodeName,
                        host: newNodeHost,
                        port: UInt16(newNodePort) ?? 7337
                    )
                    store.addNode(node)
                    showAddNode = false
                    newNodeName = ""
                    newNodeHost = ""
                    newNodePort = "7337"
                }
                .buttonStyle(KineticPrimaryButtonStyle())
                .disabled(newNodeName.isEmpty || newNodeHost.isEmpty)

                Spacer()
            }
            .padding(KineticSpacing.md)
            .background(KineticColor.surface)
            .navigationTitle("Add Node")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showAddNode = false }
                        .foregroundStyle(KineticColor.primary)
                }
            }
        }
        .presentationDetents([.medium])
    }
}
