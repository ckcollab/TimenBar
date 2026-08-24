import AppKit
import SwiftUI

enum TimenBarTheme {
    static let panel = Color(nsColor: .windowBackgroundColor)
    static let raised = Color(nsColor: .controlBackgroundColor)
    static let separator = Color.primary.opacity(0.12)
}

extension TimenTheme {
    var accent: Color {
        switch self {
        case .standard: Color(red: 43 / 255, green: 127 / 255, blue: 255 / 255)
        case .blue: Color(red: 3 / 255, green: 169 / 255, blue: 244 / 255)
        case .purple: Color(red: 183 / 255, green: 68 / 255, blue: 171 / 255)
        case .orange: Color(red: 250 / 255, green: 93 / 255, blue: 0)
        }
    }

    var accentHover: Color {
        switch self {
        case .standard: Color(red: 21 / 255, green: 93 / 255, blue: 252 / 255)
        case .blue: Color(red: 2 / 255, green: 136 / 255, blue: 209 / 255)
        case .purple: Color(red: 99 / 255, green: 52 / 255, blue: 93 / 255)
        case .orange: Color(red: 217 / 255, green: 79 / 255, blue: 0)
        }
    }

    var accentForeground: Color {
        switch self {
        case .standard: Color(red: 20 / 255, green: 71 / 255, blue: 230 / 255)
        case .blue: Color(red: 2 / 255, green: 110 / 255, blue: 174 / 255)
        case .purple: Color(red: 175 / 255, green: 65 / 255, blue: 163 / 255)
        case .orange: Color(red: 191 / 255, green: 59 / 255, blue: 0)
        }
    }

    var accentMuted: Color {
        switch self {
        case .standard: Color(red: 239 / 255, green: 246 / 255, blue: 255 / 255)
        case .blue: Color(red: 228 / 255, green: 234 / 255, blue: 238 / 255)
        case .purple: Color(red: 251 / 255, green: 236 / 255, blue: 251 / 255)
        case .orange: Color(red: 255 / 255, green: 231 / 255, blue: 217 / 255)
        }
    }

    var headerGradient: LinearGradient {
        LinearGradient(
            colors: [accent, accentHover],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    var appKitAccent: NSColor {
        switch self {
        case .standard: NSColor(srgbRed: 43 / 255, green: 127 / 255, blue: 255 / 255, alpha: 1)
        case .blue: NSColor(srgbRed: 3 / 255, green: 169 / 255, blue: 244 / 255, alpha: 1)
        case .purple: NSColor(srgbRed: 183 / 255, green: 68 / 255, blue: 171 / 255, alpha: 1)
        case .orange: NSColor(srgbRed: 250 / 255, green: 93 / 255, blue: 0, alpha: 1)
        }
    }
}

struct CardStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(TimenBarTheme.raised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08))
            }
    }
}

extension View {
    func timenCard() -> some View { modifier(CardStyle()) }
}
