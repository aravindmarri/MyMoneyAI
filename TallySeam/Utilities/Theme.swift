import SwiftUI

enum Theme {
    static let spacing: CGFloat = 16
    static let cornerRadius: CGFloat = 18
    static let income = Color.green
    static let expense = Color.red
    static let net = Color.blue

    static func color(_ identifier: String) -> Color {
        switch identifier {
        case "blue": .blue
        case "green": .green
        case "orange": .orange
        case "red": .red
        case "purple": .purple
        case "pink": .pink
        case "teal": .teal
        case "indigo": .indigo
        case "yellow": .yellow
        case "mint": .mint
        case "cyan": .cyan
        case "brown": .brown
        default: .gray
        }
    }
}

struct CardBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(Theme.spacing)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
    }
}

extension View {
    func card() -> some View { modifier(CardBackground()) }
}
