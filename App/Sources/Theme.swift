import SwiftUI
import UIKit
import FolkiDuoCore

/// Folki colors: apricot is personal money, sage is family money, dark sage is the accent.
/// Red is reserved for overspending and is never used for anything else.
extension Color {
    static let folkiAccent = adaptive(light: (0.06, 0.43, 0.34), dark: (0.36, 0.79, 0.65))

    static func budget(_ scope: BudgetScope) -> Color { RingPalette.palette(for: scope).text }

    static func adaptive(light: (Double, Double, Double), dark: (Double, Double, Double)) -> Color {
        Color(uiColor: UIColor { traits in
            let rgb = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
        })
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
