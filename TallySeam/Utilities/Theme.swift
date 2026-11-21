import SwiftUI
import UIKit

/// The app's look, taken from the icon: deep teal, clean white, and a dashed "seam" stitch.
enum Theme {
    static let spacing: CGFloat = 16
    static let cornerRadius: CGFloat = 18

    /// Icon teal (15, 118, 110); brighter in dark mode so it stays readable.
    static let brand = dynamic(light: (15, 118, 110), dark: (45, 190, 175))
    /// Darker teal for the hero gradient's far end.
    static let brandDeep = dynamic(light: (8, 82, 76), dark: (10, 70, 65))
    /// Screen background: white with a faint teal cast; near-black teal in dark mode.
    static let background = dynamic(light: (243, 247, 246), dark: (8, 14, 13))
    /// Card surface.
    static let surface = dynamic(light: (255, 255, 255), dark: (20, 30, 29))
    /// Stitch colour on cards.
    static let stitch = dynamic(light: (15, 118, 110, 0.22), dark: (45, 190, 175, 0.28))

    static let income = dynamic(light: (16, 140, 96), dark: (70, 205, 150))
    static let expense = dynamic(light: (214, 72, 64), dark: (255, 120, 108))
    static let net = brand

    static let heroGradient = LinearGradient(colors: [brand, brandDeep], startPoint: .topLeading, endPoint: .bottomTrailing)

    static func color(_ identifier: String) -> Color {
        switch identifier {
        case "blue": .blue
        case "green": .green
        case "orange": .orange
        case "red": .red
        case "purple": .purple
        case "pink": .pink
        case "teal": brand
        case "indigo": .indigo
        case "yellow": .yellow
        case "mint": .mint
        case "cyan": .cyan
        case "brown": .brown
        default: .gray
        }
    }

    private static func dynamic(light: (Int, Int, Int), dark: (Int, Int, Int)) -> Color {
        dynamic(light: (light.0, light.1, light.2, 1), dark: (dark.0, dark.1, dark.2, 1))
    }

    private static func dynamic(light: (Int, Int, Int, Double), dark: (Int, Int, Int, Double)) -> Color {
        func ui(_ c: (Int, Int, Int, Double)) -> UIColor {
            UIColor(red: CGFloat(c.0) / 255, green: CGFloat(c.1) / 255, blue: CGFloat(c.2) / 255, alpha: c.3)
        }
        return Color(UIColor { $0.userInterfaceStyle == .dark ? ui(dark) : ui(light) })
    }
}

/// A dashed stitch just inside a rounded rectangle, like the seam on the icon's T.
struct SeamStitch: View {
    var color: Color = Theme.stitch
    var inset: CGFloat = 5
    var cornerRadius: CGFloat = Theme.cornerRadius

    var body: some View {
        RoundedRectangle(cornerRadius: max(cornerRadius - inset, 4), style: .continuous)
            .inset(by: inset)
            .stroke(color, style: StrokeStyle(lineWidth: 1.2, lineCap: .round, dash: [6, 5]))
            .accessibilityHidden(true)
    }
}

struct CardBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(Theme.spacing)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                    .fill(Theme.surface)
                    .shadow(color: Theme.brandDeep.opacity(0.08), radius: 8, y: 3)
            }
            .overlay { SeamStitch() }
    }
}

/// Teal hero panel with a white stitch, for the top of a screen.
struct HeroBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(Theme.spacing)
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(.white)
            .tint(.white)
            .background(Theme.heroGradient, in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
            .overlay { SeamStitch(color: .white.opacity(0.45)) }
    }
}

extension View {
    func card() -> some View { modifier(CardBackground()) }
    func hero() -> some View { modifier(HeroBackground()) }

    /// App-wide brand styling: teal tint and the tinted background behind lists and forms.
    func brandScreen() -> some View {
        self
            .scrollContentBackground(.hidden)
            .background(Theme.background.ignoresSafeArea())
    }
}
