import SwiftUI

enum TimenBarTheme {
    static let accent = Color(red: 1.0, green: 0.39, blue: 0.05)
    static let accentLight = Color(red: 1.0, green: 0.55, blue: 0.12)
    static let panel = Color(nsColor: .windowBackgroundColor)
    static let raised = Color(nsColor: .controlBackgroundColor)
    static let separator = Color.primary.opacity(0.12)

    static let headerGradient = LinearGradient(
        colors: [accentLight, accent],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
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

