import SwiftUI

/// The Folki type scale. Screens use these roles and nothing else, so the same kind of text
/// looks the same on every screen. Money is SF Pro Rounded with digits of one width; words are SF Pro.
/// Every role follows Dynamic Type.
enum FolkiFont {
    // MARK: Words
    /// The question or title of a screen: "Сколько денег на жизнь?". 34.
    static let title = Font.largeTitle.bold()
    /// A section or sheet heading: "Траты за период". 22.
    static let section = Font.title2.bold()
    /// A card, tile or row that leads: an envelope's name, a day. 17 semibold.
    static let headline = Font.headline
    /// Running text and row names. 17.
    static let body = Font.body
    /// Chips, small buttons and links. 15 semibold.
    static let label = Font.subheadline.weight(.semibold)
    /// The line under a title, explaining it in a few words. 15.
    static let caption = Font.subheadline
    /// Times, hints, legends. 13.
    static let footnote = Font.footnote
    /// The small tag at the top of a tile: "Только ты", "Напоминания". 12 semibold.
    static let tag = Font.caption.weight(.semibold)
    /// An SF Symbol standing alone, beside a line of text.
    static let icon = Font.title3

    // MARK: Money
    /// The remaining amount in the rings.
    static let heroSize: CGFloat = 56
    /// The amount being typed on the Folki keypad.
    static let inputSize: CGFloat = 52
    /// A big figure that is not typed: an envelope's balance, a period's result. 34.
    static let moneyLarge = Font.system(.largeTitle, design: .rounded, weight: .bold)
    /// Totals on cards and tiles: a day, a period, "≈ 1 451 ₽". 22.
    static let moneyCard = Font.system(.title2, design: .rounded, weight: .bold)
    /// Amounts in lists. 17.
    static let moneyRow = Font.system(.body, design: .rounded, weight: .semibold)
    /// Figures inside chips and short lines. 15.
    static let moneySmall = Font.system(.subheadline, design: .rounded, weight: .semibold)
    /// A money size that the caller scales itself, with `@ScaledMetric`.
    static func money(_ size: CGFloat) -> Font { .system(size: size, weight: .bold, design: .rounded) }

    // MARK: Components
    /// The main action of a screen: «Записать», «Продолжить».
    static let primaryButton = Font.system(.title3, design: .rounded, weight: .bold)
    /// Digits on the Folki keypad.
    static let keypad = Font.system(.title2, design: .rounded, weight: .medium)
    /// The week strip: weekday letters and day numbers.
    static let calendarWeekday = Font.system(.caption2, design: .rounded, weight: .semibold)
    static let calendarDay = Font.system(.footnote, design: .rounded, weight: .heavy)
    /// A number inside a small dot, such as a day on the reminders line. 11.
    static let dot = Font.system(size: 11, weight: .bold, design: .rounded)
    /// A large symbol that illustrates a state: a done check, an empty list.
    static func symbol(_ size: CGFloat, weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight) }
}

/// Colours by meaning. Screens name what a colour is for, not what it looks like.
extension Color {
    /// Personal money: apricot.
    static let folkiPersonal = RingPalette.personal.start
    /// Family money: berry.
    static let folkiFamily = RingPalette.family.start
    /// Content tiles and quiet fills: a soft tint of the text colour.
    static let folkiTile = Color.folkiSoft
    /// Text under a title, times, hints.
    static let folkiSecondary = Color.secondary
    /// Chevrons, disabled hints: the quietest text.
    static let folkiTertiary = Color(uiColor: .tertiaryLabel)
}

/// Text in a role: its font and its colour together.
enum FolkiTextRole {
    case title, section, headline, body, label, caption, footnote, tag

    var font: Font {
        switch self {
        case .title: FolkiFont.title
        case .section: FolkiFont.section
        case .headline: FolkiFont.headline
        case .body: FolkiFont.body
        case .label: FolkiFont.label
        case .caption: FolkiFont.caption
        case .footnote: FolkiFont.footnote
        case .tag: FolkiFont.tag
        }
    }
    var color: Color {
        switch self {
        case .title, .section, .headline, .body, .label: Color.folkiInk
        case .caption, .footnote, .tag: Color.folkiSecondary
        }
    }
}

extension View {
    /// Font and colour of a text role.
    func folkiText(_ role: FolkiTextRole) -> some View {
        font(role.font).foregroundStyle(role.color)
    }

    /// Two surfaces only. A tile holds content: lists, settings, history days, plan cards.
    func folkiTileBackground(_ radius: CGFloat = FolkiSpacing.cardRadius) -> some View {
        background(Color.folkiTile, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }

    /// Glass floats above content or answers an action at once: impact lines, amount cards, buttons.
    func folkiGlassBackground(_ radius: CGFloat = FolkiSpacing.cardRadius) -> some View {
        glassEffect(.regular, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }

    /// A content tile with the standard inset.
    func folkiTile(padding: CGFloat = FolkiSpacing.card) -> some View {
        self.padding(padding).frame(maxWidth: .infinity, alignment: .leading).folkiTileBackground()
    }
}
