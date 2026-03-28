// KineticComponents.swift — Reusable UI building blocks for the Ghostty.

import SwiftUI

// MARK: - Tab Bar

enum KineticTab: String, CaseIterable {
    case sessions
    case history
    case settings

    var icon: String {
        switch self {
        case .sessions: "terminal"
        case .history: "clock.arrow.circlepath"
        case .settings: "gearshape"
        }
    }
}

struct KineticTabBar: View {
    @Binding var selectedTab: KineticTab

    var body: some View {
        HStack(spacing: KineticSpacing.xxl) {
            ForEach(KineticTab.allCases, id: \.self) { tab in
                Button {
                    selectedTab = tab
                } label: {
                    Image(systemName: tab.icon)
                        .font(.system(size: 22))
                        .foregroundStyle(selectedTab == tab ? KineticColor.primary : KineticColor.onSurfaceVariant)
                        .frame(width: 48, height: 48)
                        .background(
                            selectedTab == tab
                                ? KineticColor.primary.opacity(0.15)
                                : Color.clear
                        )
                        .clipShape(Circle())
                }
                .accessibilityIdentifier("tab-\(tab.rawValue)")
            }
        }
        .padding(.vertical, KineticSpacing.sm)
        .padding(.horizontal, KineticSpacing.xl)
        .background(KineticColor.surfaceContainerHigh.opacity(0.9))
        .clipShape(Capsule())
    }
}

// MARK: - Hero Header

struct KineticHeroHeader: View {
    let label: String
    let title: String
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: KineticSpacing.sm) {
            Text(label.uppercased())
                .font(KineticFont.sectionLabel)
                .tracking(3)
                .foregroundStyle(KineticColor.primary)

            Text(title)
                .font(KineticFont.heroTitle)
                .foregroundStyle(KineticColor.onSurface)
                .accessibilityIdentifier("hero-title")

            if let subtitle {
                Text(subtitle)
                    .font(KineticFont.body)
                    .foregroundStyle(KineticColor.onSurfaceVariant)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Feature Card

struct KineticFeatureCard: View {
    let icon: String
    let title: String
    let description: String
    var iconColor: Color = KineticColor.primary

    var body: some View {
        VStack(alignment: .leading, spacing: KineticSpacing.md) {
            Image(systemName: icon)
                .font(.system(size: 28))
                .foregroundStyle(iconColor)

            Text(title)
                .font(KineticFont.bodySmall)
                .fontWeight(.bold)
                .foregroundStyle(KineticColor.onSurface)

            Text(description)
                .font(KineticFont.caption)
                .foregroundStyle(KineticColor.onSurfaceVariant)
                .lineLimit(3)
        }
        .padding(KineticSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .containerCard(color: KineticColor.surfaceContainerHigh)
    }
}

// MARK: - Session Card

struct KineticSessionCard: View {
    let icon: String
    let name: String
    let idBadge: String
    var startedText: String? = nil
    var activityText: String? = nil
    var isIdle: Bool = false
    var onTap: (() -> Void)? = nil

    var body: some View {
        Button {
            onTap?()
        } label: {
            HStack(spacing: KineticSpacing.md) {
                Image(systemName: icon)
                    .font(.system(size: 24))
                    .foregroundStyle(KineticColor.onSurfaceVariant)
                    .frame(width: 44, height: 44)
                    .background(KineticColor.surfaceContainerHighest)
                    .clipShape(RoundedRectangle(cornerRadius: KineticRadius.button))

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(name)
                            .font(KineticFont.bodySmall)
                            .fontWeight(.bold)
                            .foregroundStyle(KineticColor.onSurface)

                        Text(idBadge)
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(KineticColor.primary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(KineticColor.primary.opacity(0.15))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }

                    if let startedText {
                        HStack(spacing: 4) {
                            Image(systemName: "clock")
                                .font(.system(size: 10))
                            Text(startedText)
                                .font(KineticFont.monoSmall)
                        }
                        .foregroundStyle(KineticColor.onSurfaceVariant)
                    }

                    if let activityText {
                        HStack(spacing: 4) {
                            if isIdle {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.system(size: 10))
                                    .foregroundStyle(KineticColor.error)
                            } else {
                                Image(systemName: "antenna.radiowaves.left.and.right")
                                    .font(.system(size: 10))
                            }
                            Text(activityText)
                                .font(KineticFont.monoSmall)
                        }
                        .foregroundStyle(isIdle ? KineticColor.error : KineticColor.onSurfaceVariant)
                    }
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(KineticColor.outlineVariant)
            }
            .padding(KineticSpacing.md)
            .containerCard()
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Input Field

struct KineticInputField: View {
    let placeholder: String
    @Binding var text: String
    var isSecure: Bool = false
    var icon: String? = nil
    var keyboardType: UIKeyboardType = .default

    var body: some View {
        HStack {
            if isSecure {
                SecureField(placeholder, text: $text)
                    .font(KineticFont.monoInput)
                    .foregroundStyle(KineticColor.secondary)
            } else {
                TextField(placeholder, text: $text)
                    .font(KineticFont.monoInput)
                    .foregroundStyle(KineticColor.secondary)
                    .keyboardType(keyboardType)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }

            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 18))
                    .foregroundStyle(KineticColor.outlineVariant)
            }
        }
        .padding(KineticSpacing.md)
        .background(KineticColor.surfaceContainerLowest)
        .clipShape(RoundedRectangle(cornerRadius: KineticRadius.container))
    }
}

// MARK: - Section Label

struct KineticSectionLabel: View {
    let text: String
    var trailing: AnyView? = nil

    var body: some View {
        HStack {
            Text(text.uppercased())
                .font(KineticFont.sectionLabel)
                .tracking(2)
                .foregroundStyle(KineticColor.onSurfaceVariant)

            Spacer()

            if let trailing {
                trailing
            }
        }
    }
}

// MARK: - Status Badge

struct KineticStatusBadge: View {
    let text: String
    var color: Color = KineticColor.tertiary

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .tracking(1)
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(color.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: KineticRadius.button))
    }
}

// MARK: - Top Bar

enum KineticTopBarMode {
    case standard
    case terminal(sessionName: String, rttMs: Int? = nil, lostPct: Double? = nil, isDisconnected: Bool = false)
}

struct KineticTopBar: View {
    var mode: KineticTopBarMode = .standard

    // Legacy convenience init
    var subtitle: String? = nil
    var trailing: AnyView? = nil

    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        switch mode {
        case .standard:
            standardBar
        case .terminal(let sessionName, let rttMs, let lostPct, let isDisconnected):
            terminalBar(sessionName: sessionName, rttMs: rttMs, lostPct: lostPct, isDisconnected: isDisconnected)
        }
    }

    private func logoView(subtitle: String?) -> some View {
        HStack(spacing: KineticSpacing.sm) {
            Image(systemName: "terminal")
                .font(.system(size: 20))
                .foregroundStyle(KineticColor.primary)

            VStack(alignment: .leading, spacing: 0) {
                Text("Ghostty")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(KineticColor.primary)

                if let subtitle {
                    Text(subtitle)
                        .font(KineticFont.monoSmall)
                        .foregroundStyle(KineticColor.onSurfaceVariant)
                }
            }
        }
    }

    private func barWrapper<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(.horizontal, KineticSpacing.md)
            .padding(.vertical, KineticSpacing.sm)
            .background(KineticColor.surface.opacity(0.7))
            .glassMorphism(cornerRadius: 0)
    }

    private var standardBar: some View {
        barWrapper {
            HStack {
                logoView(subtitle: subtitle)

                Spacer()

                if let trailing {
                    trailing
                } else {
                    HStack(spacing: KineticSpacing.md) {
                        if sizeClass == .regular {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 20))
                                .foregroundStyle(KineticColor.onSurfaceVariant)
                        }
                        Image(systemName: "person.circle")
                            .font(.system(size: 24))
                            .foregroundStyle(KineticColor.onSurfaceVariant)
                    }
                }
            }
        }
    }

    private func terminalBar(sessionName: String, rttMs: Int?, lostPct: Double?, isDisconnected: Bool) -> some View {
        barWrapper {
            HStack {
                logoView(subtitle: "SESSION: \(sessionName.uppercased())")

                Spacer()

                if sizeClass == .regular {
                    if isDisconnected {
                        KineticStatusBadge(text: "DISCONNECTED", color: KineticColor.error)
                    } else {
                        if let rtt = rttMs {
                            KineticStatusBadge(text: "RTT \(rtt)ms", color: KineticColor.primary)
                        }
                        if let lost = lostPct {
                            KineticStatusBadge(text: "LOST \(String(format: "%.2f", lost))%", color: KineticColor.onSurfaceVariant)
                        }
                    }
                }

                Image(systemName: "person.circle")
                    .font(.system(size: 24))
                    .foregroundStyle(KineticColor.onSurfaceVariant)
            }
        }
    }
}

// MARK: - Connection Info Bar

struct KineticConnectionInfoBar: View {
    var linkStrength: String = "STRONG"
    var bandwidth: String = "1.2 GBPS"
    var encryption: String = "AES-256-GCM"
    var protocolVersion: String = "mosh 1.4.0 [kinetic-prot-v2]"

    var body: some View {
        HStack(spacing: KineticSpacing.md) {
            HStack(spacing: KineticSpacing.xs) {
                Circle()
                    .fill(KineticColor.success)
                    .frame(width: 6, height: 6)
                Text("LINK: \(linkStrength)")
                    .font(KineticFont.monoSmall)
                    .foregroundStyle(KineticColor.success)
            }

            Text(bandwidth)
                .font(KineticFont.monoSmall)
                .foregroundStyle(KineticColor.onSurfaceVariant)

            Text(encryption)
                .font(KineticFont.monoSmall)
                .foregroundStyle(KineticColor.onSurfaceVariant)

            Spacer()

            Text(protocolVersion)
                .font(KineticFont.monoSmall)
                .foregroundStyle(KineticColor.outlineVariant)
        }
        .padding(.horizontal, KineticSpacing.md)
        .padding(.vertical, KineticSpacing.sm)
        .background(KineticColor.surfaceContainerHigh)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(KineticColor.outlineVariant.opacity(0.15))
                .frame(height: 1)
        }
    }
}

// MARK: - Circular Gauge

struct KineticCircularGauge: View {
    let label: String
    let value: String
    var progress: Double = 0
    var color: Color = KineticColor.primary

    var body: some View {
        VStack(spacing: KineticSpacing.xs) {
            ZStack {
                Circle()
                    .stroke(KineticColor.outlineVariant.opacity(0.2), lineWidth: 3)

                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))

                VStack(spacing: 0) {
                    Text(value)
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(KineticColor.onSurface)
                }
            }
            .frame(width: 52, height: 52)

            Text(label)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(KineticColor.onSurfaceVariant)
        }
    }
}

// MARK: - Metrics Sidebar

struct KineticMetricsSidebar: View {
    var latency: String = "24ms"
    var latencyProgress: Double = 0.24
    var cpuPercent: String = "75%"
    var cpuProgress: Double = 0.75
    var memPercent: String = "36%"
    var memProgress: Double = 0.36
    var isDisconnected: Bool = false

    var body: some View {
        VStack(spacing: KineticSpacing.lg) {
            KineticCircularGauge(
                label: "LAT",
                value: isDisconnected ? "ERR" : latency,
                progress: isDisconnected ? 0 : latencyProgress,
                color: KineticColor.primary
            )

            KineticCircularGauge(
                label: "CPU",
                value: cpuPercent,
                progress: cpuProgress,
                color: KineticColor.primaryContainer
            )

            KineticCircularGauge(
                label: "MEM",
                value: memPercent,
                progress: memProgress,
                color: KineticColor.tertiary
            )

            Spacer()

            Text("_OFF")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(KineticColor.outlineVariant)
                .padding(.bottom, KineticSpacing.sm)
        }
        .frame(width: 80)
        .padding(.vertical, KineticSpacing.md)
        .background(KineticColor.surfaceContainerLow)
    }
}

// MARK: - Command Bar

struct KineticCommandBar: View {
    @Binding var text: String
    var isDisabled: Bool = false
    var placeholder: String = "Type a command..."
    var onSubmit: () -> Void

    @Environment(\.horizontalSizeClass) private var sizeClass
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: KineticSpacing.sm) {
            Image(systemName: "terminal")
                .font(.system(size: 18))
                .foregroundStyle(KineticColor.onSurfaceVariant)

            TextField(placeholder, text: $text)
                .font(KineticFont.monoInput)
                .foregroundStyle(KineticColor.secondary)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .focused($isFocused)
                .disabled(isDisabled)
                .onSubmit { onSubmit() }

            if sizeClass == .regular {
                // Tablet: ENTER badge + RUN button
                Text("ENTER")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(KineticColor.outlineVariant)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(KineticColor.surfaceContainerHighest)
                    .clipShape(RoundedRectangle(cornerRadius: 4))

                Button {
                    onSubmit()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrowtriangle.right.fill")
                            .font(.system(size: 10))
                        Text(isDisabled ? "OFFLINE" : "RUN")
                            .font(.system(size: 11, weight: .bold))
                    }
                    .foregroundStyle(isDisabled ? KineticColor.onSurfaceVariant : KineticColor.onPrimary)
                    .padding(.horizontal, KineticSpacing.md)
                    .padding(.vertical, KineticSpacing.sm)
                    .background {
                        if isDisabled {
                            KineticColor.surfaceContainerHighest
                        } else {
                            KineticGradient.primary
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: KineticRadius.button))
                }
                .disabled(isDisabled || text.isEmpty)
            } else {
                // Mobile: cyan circular send button
                Button {
                    onSubmit()
                } label: {
                    Image(systemName: "arrowtriangle.right.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(isDisabled ? KineticColor.onSurfaceVariant : KineticColor.onPrimary)
                        .frame(width: 44, height: 44)
                        .background {
                            if isDisabled {
                                KineticColor.surfaceContainerHighest
                            } else {
                                KineticGradient.primary
                            }
                        }
                        .clipShape(Circle())
                }
                .disabled(isDisabled || text.isEmpty)
            }
        }
        .padding(.horizontal, KineticSpacing.md)
        .padding(.vertical, KineticSpacing.sm)
        .background(KineticColor.surfaceContainer)
        .onAppear { isFocused = true }
    }
}

// MARK: - Session History Row

struct KineticSessionHistoryRow: View {
    let icon: String
    let host: String
    let subtitle: String
    var onTap: (() -> Void)? = nil

    var body: some View {
        Button {
            onTap?()
        } label: {
            HStack(spacing: KineticSpacing.md) {
                Image(systemName: icon)
                    .font(.system(size: 18))
                    .foregroundStyle(KineticColor.onSurfaceVariant)
                    .frame(width: 40, height: 40)
                    .background(KineticColor.surfaceContainerHighest)
                    .clipShape(Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text(host)
                        .font(KineticFont.bodySmall)
                        .fontWeight(.bold)
                        .foregroundStyle(KineticColor.onSurface)

                    Text(subtitle)
                        .font(KineticFont.monoSmall)
                        .foregroundStyle(KineticColor.onSurfaceVariant)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(KineticColor.outlineVariant)
            }
            .padding(KineticSpacing.md)
            .containerCard()
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Cluster Status Card

struct KineticClusterStatusCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: KineticSpacing.md) {
            // Decorative waveform bars
            HStack(spacing: 3) {
                ForEach(0..<24, id: \.self) { i in
                    let height = waveformHeight(index: i)
                    RoundedRectangle(cornerRadius: 1)
                        .fill(KineticColor.onSurfaceVariant.opacity(0.3))
                        .frame(width: 3, height: height)
                }
            }
            .frame(height: 40)
            .frame(maxWidth: .infinity, alignment: .leading)

            Text("Cluster Status")
                .font(KineticFont.bodySmall)
                .fontWeight(.bold)
                .foregroundStyle(KineticColor.onSurface)

            HStack(spacing: KineticSpacing.xs) {
                Circle()
                    .fill(KineticColor.success)
                    .frame(width: 8, height: 8)
                Text("ALL SYSTEMS NOMINAL")
                    .font(KineticFont.monoSmall)
                    .foregroundStyle(KineticColor.success)
            }
        }
        .padding(KineticSpacing.md)
        .containerCard(color: KineticColor.surfaceContainerHigh)
    }

    private func waveformHeight(index: Int) -> CGFloat {
        // Pseudo-random waveform pattern
        let heights: [CGFloat] = [8, 14, 20, 28, 22, 16, 10, 24, 32, 18, 12, 26, 20, 14, 30, 16, 22, 10, 18, 28, 14, 20, 12, 24]
        return heights[index % heights.count]
    }
}

// MARK: - Modifier Key Button

struct ModifierKeyButton: View {
    let label: String
    var isActive: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(isActive ? KineticColor.onPrimary : KineticColor.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    isActive
                        ? AnyShapeStyle(KineticGradient.primary)
                        : AnyShapeStyle(KineticColor.surfaceContainerHighest.opacity(0.6))
                )
                .clipShape(RoundedRectangle(cornerRadius: KineticRadius.button))
                .overlay(
                    RoundedRectangle(cornerRadius: KineticRadius.button)
                        .strokeBorder(KineticColor.outlineVariant.opacity(0.2), lineWidth: 1)
                )
        }
    }
}
