// ConnectionLostBanner — Red overlay banner for connection loss state.

import SwiftUI

struct ConnectionLostBanner: View {
    let reason: String
    var onReconnect: () -> Void
    var onSettings: () -> Void

    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        if sizeClass == .regular {
            tabletBanner
        } else {
            mobileBanner
        }
    }

    // MARK: - Mobile

    private var mobileBanner: some View {
        HStack(spacing: KineticSpacing.md) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.white)

            Text("CONNECTION LOST — \(reason)")
                .font(.system(size: 12, weight: .black, design: .monospaced))
                .foregroundStyle(.white)
                .lineLimit(1)

            Spacer()

            Button("Reconnect") {
                onReconnect()
            }
            .buttonStyle(KineticSmallButtonStyle())

            Button("Settings") {
                onSettings()
            }
            .buttonStyle(KineticSmallButtonStyle())
        }
        .padding(.horizontal, KineticSpacing.md)
        .padding(.vertical, KineticSpacing.sm)
        .background(KineticGradient.errorBanner)
    }

    // MARK: - Tablet

    private var tabletBanner: some View {
        HStack(spacing: KineticSpacing.md) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(.white)

            VStack(alignment: .leading, spacing: 2) {
                Text("CONNECTION LOST")
                    .font(.system(size: 12, weight: .black, design: .monospaced))
                    .foregroundStyle(.white)

                Text(reason)
                    .font(KineticFont.monoSmall)
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(1)
            }

            Spacer()

            Button {
                onReconnect()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 12))
                    Text("RECONNECT")
                }
            }
            .buttonStyle(KineticOutlinedButtonStyle(color: KineticColor.primary))

            Button {
                onSettings()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 12))
                    Text("SETTINGS")
                }
            }
            .buttonStyle(KineticOutlinedButtonStyle(color: .white))
        }
        .padding(.horizontal, KineticSpacing.md)
        .padding(.vertical, KineticSpacing.sm)
        .background(KineticGradient.errorBanner)
    }
}
