import SwiftUI
import UIKit
import FolkiDuoCore

/// Folki colors: apricot is personal money, sage is family money, dark sage is the accent.
/// Red is reserved for overspending and is never used for anything else.
extension Color {
    static let folkiAccent = adaptive(light: (0.06, 0.43, 0.34), dark: (0.11, 0.62, 0.46))

    static func budget(_ scope: BudgetScope) -> Color { RingPalette.palette(for: scope).text }
    /// Main screen ground: white in light mode, black in dark.
    static let folkiBackground = Color(uiColor: .systemBackground)
    /// Cards and quiet buttons on that ground: warm light gray / dark gray.
    static let folkiSurface = adaptive(light: (0.945, 0.925, 0.898), dark: (0.11, 0.11, 0.118))
    static let folkiInk = adaptive(light: (0.086, 0.094, 0.106), dark: (0.965, 0.933, 0.894))

    static func adaptive(light: (Double, Double, Double), dark: (Double, Double, Double)) -> Color {
        Color(uiColor: UIColor { traits in
            let rgb = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
        })
    }
}

/// Liquid-glass ground: white or black with large, faint color fields pushed to the edges,
/// so nothing glows behind the rings. Peach and mint by day, amber and malachite by night.
struct FolkiBackground: View {
    @Environment(\.colorScheme) private var scheme
    private typealias Field = (color: Color, x: CGFloat, y: CGFloat, size: CGFloat, opacity: Double)
    private var fields: [Field] {
        scheme == .dark
            ? [(Color(red: 0.72, green: 0.43, blue: 0.08), -0.75, -0.15, 560, 0.22),
               (Color(red: 0.06, green: 0.48, blue: 0.34), 0.65, 0.38, 520, 0.20),
               (Color(red: 0.42, green: 0.25, blue: 0.05), -0.75, 0.70, 520, 0.18),
               (Color(red: 0.05, green: 0.35, blue: 0.26), 0.65, 0.95, 500, 0.20)]
            : [(Color(red: 1.0, green: 0.79, blue: 0.56), -0.65, -0.16, 520, 0.45),
               (Color(red: 0.62, green: 0.90, blue: 0.78), 0.62, 0.33, 480, 0.40),
               (Color(red: 1.0, green: 0.85, blue: 0.69), -0.70, 0.69, 520, 0.35),
               (Color(red: 0.72, green: 0.93, blue: 0.84), 0.62, 0.93, 480, 0.35)]
    }
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color(uiColor: .systemBackground)
                ForEach(Array(fields.enumerated()), id: \.offset) { _, field in
                    Circle().fill(field.color).opacity(field.opacity)
                        .frame(width: field.size, height: field.size)
                        .position(x: geometry.size.width * (0.5 + field.x), y: geometry.size.height * field.y)
                        .blur(radius: 110)
                }
            }
        }
        .ignoresSafeArea().accessibilityHidden(true)
    }
}

extension View {
    /// Frosted glass with a hairline edge: cards, the Add button, the header's icon group.
    func folkiGlass<S: InsettableShape>(_ shape: S) -> some View {
        background(.ultraThinMaterial, in: shape)
            .overlay { shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 1) }
    }
}

struct RingPalette {
    let start: Color
    let end: Color
    /// Readable on the grouped background in both themes.
    let text: Color

    static let personal = RingPalette(
        start: .adaptive(light: (0.91, 0.54, 0.10), dark: (0.95, 0.66, 0.23)),
        end: .adaptive(light: (0.96, 0.70, 0.29), dark: (0.98, 0.79, 0.47)),
        text: .adaptive(light: (0.52, 0.31, 0.04), dark: (0.98, 0.78, 0.46)))
    static let family = RingPalette(
        start: .adaptive(light: (0.07, 0.52, 0.37), dark: (0.18, 0.72, 0.55)),
        end: .adaptive(light: (0.18, 0.71, 0.54), dark: (0.44, 0.83, 0.68)),
        text: .adaptive(light: (0.06, 0.43, 0.34), dark: (0.36, 0.79, 0.65)))

    static func palette(for scope: BudgetScope) -> RingPalette { scope == .personal ? personal : family }
}
