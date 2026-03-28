// KineticTheme.swift — Design tokens for the Ghostty iOS app.
// Colors, typography, radii, gradients, and reusable modifiers.

import SwiftUI

// MARK: - Colors

enum KineticColor {
    // Surface hierarchy (dark → light)
    static let surface = Color(red: 14/255, green: 14/255, blue: 14/255)             // #0e0e0e
    static let surfaceContainerLowest = Color.black                                     // #000000
    static let surfaceContainerLow = Color(red: 19/255, green: 19/255, blue: 19/255)  // #131313
    static let surfaceContainer = Color(red: 26/255, green: 25/255, blue: 25/255)     // #1a1919
    static let surfaceContainerHigh = Color(red: 32/255, green: 31/255, blue: 31/255) // #201f1f
    static let surfaceContainerHighest = Color(red: 38/255, green: 38/255, blue: 38/255) // #262626

    // Primary (cyan accent)
    static let primary = Color(red: 105/255, green: 218/255, blue: 255/255)           // #69daff
    static let primaryContainer = Color(red: 0/255, green: 207/255, blue: 252/255)    // #00cffc
    static let primaryDim = Color(red: 0/255, green: 192/255, blue: 234/255)          // #00c0ea

    // Secondary (text)
    static let secondary = Color(red: 229/255, green: 226/255, blue: 225/255)         // #e5e2e1
    static let onSurface = Color.white
    static let onSurfaceVariant = Color(red: 173/255, green: 170/255, blue: 170/255)  // #adaaaa
    static let onPrimary = Color(red: 14/255, green: 14/255, blue: 14/255)            // #0e0e0e

    // Tertiary (blue accent for status)
    static let tertiary = Color(red: 118/255, green: 150/255, blue: 253/255)          // #7696fd

    // Success
    static let success = Color(red: 74/255, green: 222/255, blue: 128/255)            // #4ade80

    // Error
    static let error = Color(red: 255/255, green: 113/255, blue: 108/255)             // #ff716c
    static let onErrorContainer = Color(red: 255/255, green: 168/255, blue: 163/255)  // #ffa8a3

    // Outline
    static let outline = Color(red: 119/255, green: 117/255, blue: 117/255)           // #777575
    static let outlineVariant = Color(red: 73/255, green: 72/255, blue: 71/255)       // #494847
}

// MARK: - Gradients

enum KineticGradient {
    static let primary = LinearGradient(
        colors: [KineticColor.primary, KineticColor.primaryContainer],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let errorBanner = LinearGradient(
        colors: [KineticColor.error.opacity(0.9), KineticColor.error.opacity(0.7)],
        startPoint: .leading,
        endPoint: .trailing
    )
}

// MARK: - Typography

enum KineticFont {
    /// Hero titles — SF Pro Bold ~40pt
    static let heroTitle = Font.system(size: 40, weight: .black, design: .default)
    /// Section headers — SF Pro Bold 24pt
    static let headline = Font.system(size: 24, weight: .bold, design: .default)
    /// Section labels — SF Pro 11pt uppercase tracked
    static let sectionLabel = Font.system(size: 11, weight: .bold, design: .default)
    /// Body text — SF Pro 16pt
    static let body = Font.system(size: 16, weight: .medium, design: .default)
    /// Small body — SF Pro 14pt
    static let bodySmall = Font.system(size: 14, weight: .medium, design: .default)
    /// Caption — SF Pro 12pt
    static let caption = Font.system(size: 12, weight: .medium, design: .default)
    /// Monospace data — SF Mono 14pt
    static let monoData = Font.system(size: 14, weight: .regular, design: .monospaced)
    /// Monospace small — SF Mono 12pt
    static let monoSmall = Font.system(size: 12, weight: .regular, design: .monospaced)
    /// Monospace input — SF Mono 16pt
    static let monoInput = Font.system(size: 16, weight: .medium, design: .monospaced)
}

// MARK: - Corner Radii

enum KineticRadius {
    static let button: CGFloat = 8
    static let container: CGFloat = 16
    static let large: CGFloat = 24
    static let pill: CGFloat = 9999
}

// MARK: - Spacing

enum KineticSpacing {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 16
    static let lg: CGFloat = 24
    static let xl: CGFloat = 36
    static let xxl: CGFloat = 48
}

// MARK: - View Modifiers

struct GlassMorphismModifier: ViewModifier {
    var cornerRadius: CGFloat = KineticRadius.container

    func body(content: Content) -> some View {
        content
            .background(.ultraThinMaterial.opacity(0.65))
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }
}

struct ContainerCardModifier: ViewModifier {
    var color: Color = KineticColor.surfaceContainer
    var cornerRadius: CGFloat = KineticRadius.container

    func body(content: Content) -> some View {
        content
            .background(color)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }
}

// MARK: - Button Styles

struct KineticPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(KineticFont.body)
            .fontWeight(.black)
            .foregroundStyle(KineticColor.onPrimary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, KineticSpacing.md)
            .background(KineticGradient.primary)
            .clipShape(RoundedRectangle(cornerRadius: KineticRadius.large))
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

struct KineticSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(KineticFont.body)
            .fontWeight(.bold)
            .foregroundStyle(KineticColor.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, KineticSpacing.md)
            .background(KineticColor.surfaceContainerHighest)
            .clipShape(RoundedRectangle(cornerRadius: KineticRadius.large))
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

struct KineticSmallButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(KineticFont.caption)
            .fontWeight(.bold)
            .foregroundStyle(KineticColor.secondary)
            .padding(.horizontal, KineticSpacing.md)
            .padding(.vertical, KineticSpacing.sm)
            .background(KineticColor.surfaceContainerHighest.opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius: KineticRadius.button))
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

struct KineticOutlinedButtonStyle: ButtonStyle {
    var color: Color = KineticColor.primary

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(KineticFont.caption)
            .fontWeight(.bold)
            .foregroundStyle(color)
            .padding(.horizontal, KineticSpacing.md)
            .padding(.vertical, KineticSpacing.sm)
            .background(Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: KineticRadius.button))
            .overlay(
                RoundedRectangle(cornerRadius: KineticRadius.button)
                    .strokeBorder(color.opacity(0.6), lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

// MARK: - View Extensions

extension View {
    func glassMorphism(cornerRadius: CGFloat = KineticRadius.container) -> some View {
        modifier(GlassMorphismModifier(cornerRadius: cornerRadius))
    }

    func containerCard(color: Color = KineticColor.surfaceContainer, cornerRadius: CGFloat = KineticRadius.container) -> some View {
        modifier(ContainerCardModifier(color: color, cornerRadius: cornerRadius))
    }
}
