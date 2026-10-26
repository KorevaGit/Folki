import SwiftUI
import UIKit
import FolkiDuoCore

/// Folki colors: apricot is personal money, berry is family money, dark sage is the accent.
/// Amber marks an envelope due in 3–7 days. Red is reserved for overspending and envelopes due in 0–2 days.
extension Color {
    static let folkiAccent = adaptive(light: (0.06, 0.43, 0.34), dark: (0.11, 0.62, 0.46))

    /// Envelope short of money, 3–7 days before payment: text and fill on its soft ground.
    static let folkiWarning = adaptive(light: (0.729, 0.459, 0.090), dark: (0.980, 0.780, 0.459))
    static let folkiWarningGround = adaptive(light: (0.980, 0.933, 0.855), dark: (0.255, 0.141, 0.008))

    static func budget(_ scope: BudgetScope) -> Color { RingPalette.palette(for: scope).text }
    /// Main screen ground: white in light mode, black in dark.
    static let folkiBackground = Color(uiColor: .systemBackground)
    /// Cards and quiet buttons on that ground: warm light gray / dark gray.
    static let folkiSurface = adaptive(light: (0.945, 0.925, 0.898), dark: (0.11, 0.11, 0.118))
    /// Overspending and anything past a limit: one red for every "too much".
    static let folkiOver = Color(uiColor: .systemRed)
    static let folkiInk = adaptive(light: (0.086, 0.094, 0.106), dark: (0.965, 0.933, 0.894))

    static func adaptive(light: (Double, Double, Double), dark: (Double, Double, Double)) -> Color {
        Color(uiColor: UIColor { traits in
            let rgb = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
        })
    }
}

/// Plain white by day; by night black with faint apricot and berry fields at the edges.
struct FolkiBackground: View {
    @Environment(\.colorScheme) private var scheme
    private typealias Field = (color: Color, x: CGFloat, y: CGFloat, size: CGFloat, opacity: Double)
    private var fields: [Field] {
        scheme == .dark
            ? [(Color(red: 0.72, green: 0.43, blue: 0.08), -0.75, -0.15, 640, 0.34),
               (Color(red: 0.62, green: 0.22, blue: 0.38), 0.65, 0.38, 570, 0.25),
               (Color(red: 0.42, green: 0.25, blue: 0.05), -0.75, 0.70, 610, 0.29),
               (Color(red: 0.42, green: 0.14, blue: 0.26), 0.65, 0.95, 550, 0.24)]
            : [] // Plain white by day: tinted fields on white read as dirt.
    }
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color(uiColor: .systemBackground)
                // Radial gradients look like the blurred circles they replace, without a live blur
                // that every glass surface above has to sample again on each frame.
                ForEach(Array(fields.enumerated()), id: \.offset) { _, field in
                    RadialGradient(colors: [field.color.opacity(field.opacity), field.color.opacity(field.opacity * 0.5), .clear],
                                   center: UnitPoint(x: 0.5 + field.x, y: field.y),
                                   startRadius: 0, endRadius: field.size / 2 + 110)
                }
            }
        }
        .drawingGroup()
        .ignoresSafeArea().accessibilityHidden(true)
    }
}

extension View {
    /// Cards, the Add button, the month line: a quiet solid tint by day, frosted glass by night. No outlines.
    func folkiGlass<S: Shape>(_ shape: S) -> some View {
        modifier(FolkiSurface(shape: shape))
    }
}

private struct FolkiSurface<S: Shape>: ViewModifier {
    let shape: S
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    func body(content: Content) -> some View {
        if reduceTransparency || contrast == .increased {
            content.background(Color(uiColor: .secondarySystemBackground), in: shape)
        } else if scheme == .dark {
            content.background(.ultraThinMaterial, in: shape)
        } else {
            content.background(Color(red: 0.957, green: 0.949, blue: 0.937), in: shape)
        }
    }
}

struct RingPalette {
    let start: Color
    let end: Color
    /// Readable on the grouped background in both themes.
    let text: Color

    static let personal = RingPalette(
        start: .adaptive(light: (0.937, 0.624, 0.153), dark: (0.95, 0.66, 0.23)), // #EF9F27 by day
        end: .adaptive(light: (0.96, 0.70, 0.29), dark: (0.98, 0.79, 0.47)),
        text: .adaptive(light: (0.52, 0.31, 0.04), dark: (0.98, 0.78, 0.46)))
    /// Berry #D4537E by day, #ED93B1 by night.
    static let family = RingPalette(
        start: .adaptive(light: (0.831, 0.325, 0.494), dark: (0.929, 0.576, 0.694)),
        end: .adaptive(light: (0.929, 0.576, 0.694), dark: (0.957, 0.753, 0.820)),
        text: .adaptive(light: (0.600, 0.208, 0.337), dark: (0.957, 0.753, 0.820)))

    static func palette(for scope: BudgetScope) -> RingPalette { scope == .personal ? personal : family }
}

/// The one switch of Folki: a compact capsule, the chosen option on a glass pill that slides to it.
/// Budget options carry their colour dot, so the switch says which money it is without more words.
struct FolkiSegmentedPicker<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [(String, Value)]
    /// Kept for call sites written for the old full-width control; the capsule sizes itself.
    var minimumHeight: CGFloat = 36
    /// A colour dot before each option, nil for none.
    var dots: [Color?] = []
    @Namespace private var pill
    @ScaledMetric(relativeTo: .subheadline) private var height: CGFloat = 34
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { index in
                let option = options[index]
                let selected = option.1 == selection
                Button {
                    guard !selected else { return }
                    FolkiFeedback.selection()
                    withAnimation(FolkiMotion.resolved(FolkiMotion.quick, reduceMotion: reduceMotion)) { selection = option.1 }
                } label: {
                    HStack(spacing: 6) {
                        if index < dots.count, let dot = dots[index] { Circle().fill(dot).frame(width: 7, height: 7) }
                        Text(option.0).lineLimit(1)
                    }
                    .font(FolkiFont.label)
                    .foregroundStyle(selected ? Color.folkiInk : Color.folkiSecondary)
                    .padding(.horizontal, FolkiSpacing.card).frame(minHeight: height)
                    .background {
                        if selected {
                            Color.clear.glassEffect(.regular, in: Capsule())
                                .matchedGeometryEffect(id: "pill", in: pill)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Color.folkiTile, in: Capsule())
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

/// Shared page grid on a 4-point scale: 4 · 8 · 12 · 16 · 20 · 24 · 32 · 48. No other numbers.
/// Cards add their own 16-point content inset inside these margins.
enum FolkiSpacing {
    static let xxs: CGFloat = 4
    static let xs: CGFloat = 8
    static let large: CGFloat = 32
    static let huge: CGFloat = 48
    /// Card corners; liquid glass likes large radii.
    static let cardRadius: CGFloat = 24
    /// Fields, chips and rows inside a card.
    static let controlRadius: CGFloat = 14
    /// Height of the main action of a screen.
    static let primaryButton: CGFloat = 60
    static let page: CGFloat = 20
    static let card: CGFloat = 16
    static let section: CGFloat = 24
    static let item: CGFloat = 12
    static let maxWidth: CGFloat = 680
}

extension View {
    func folkiPagePadding(top: CGFloat = FolkiSpacing.card) -> some View {
        padding(.horizontal, FolkiSpacing.page).padding(.top, top).padding(.bottom, FolkiSpacing.card)
            .frame(maxWidth: FolkiSpacing.maxWidth).frame(maxWidth: .infinity)
    }

    func folkiFormLayout() -> some View {
        contentMargins(.horizontal, FolkiSpacing.page, for: .scrollContent)
            .contentMargins(.vertical, FolkiSpacing.card, for: .scrollContent)
            .environment(\.defaultMinListRowHeight, 52)
            .listSectionSpacing(FolkiSpacing.section)
            .scrollContentBackground(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .background { FolkiBackground() }
    }
}

/// On short screens or with accessibility text, let fields and keypad scroll together.
/// On taller screens the keypad stays at the bottom, with fields filling the space above.
struct FolkiEntryLayout<Fields: View, Keypad: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var fullHeight: CGFloat = 0
    var hidesKeypad = false
    @ViewBuilder let fields: (CGFloat) -> Fields
    @ViewBuilder let keypad: () -> Keypad

    var body: some View {
        GeometryReader { geometry in
            // Keyboard appearance must not move the focused field into a new view tree.
            if max(fullHeight, geometry.size.height) < 560 || dynamicTypeSize.isAccessibilitySize {
                ScrollView {
                    VStack(spacing: FolkiSpacing.item) {
                        fields(0)
                        if !hidesKeypad { keypad() }
                    }.padding(.top, FolkiSpacing.card)
                }.scrollBounceBehavior(.basedOnSize).scrollDismissesKeyboard(.interactively)
            } else {
                VStack(spacing: FolkiSpacing.item) {
                    GeometryReader { available in
                        ScrollView {
                            fields(max(0, available.size.height - 8)).padding(.bottom, 8)
                        }.scrollBounceBehavior(.basedOnSize).scrollDismissesKeyboard(.interactively)
                    }
                    if !hidesKeypad { keypad() }
                }.padding(.top, FolkiSpacing.card)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
            fullHeight = max(fullHeight, height)
        }
        .frame(maxWidth: FolkiSpacing.maxWidth).frame(maxWidth: .infinity)
    }
}


/// The five haptics of Folki. Plain button taps stay silent: when everything buzzes, nothing means anything.
/// Generators are kept and prepared so taps answer without delay.
@MainActor enum FolkiFeedback {
    private static let selector = UISelectionFeedbackGenerator()
    private static let soft = UIImpactFeedbackGenerator(style: .soft)
    private static let light = UIImpactFeedbackGenerator(style: .light)
    private static let rigid = UIImpactFeedbackGenerator(style: .rigid)
    private static let notifier = UINotificationFeedbackGenerator()

    /// Picking a value: chips, toggles, days, segments.
    static func selection() { selector.selectionChanged(); selector.prepare() }
    /// A digit on the Folki keypad: quiet, like the system keyboard.
    static func key() { soft.impactOccurred(intensity: 0.4); soft.prepare() }
    /// A saved spend, top-up or payment. `crossedIntoMinus` turns it into the warning.
    static func saved(crossedIntoMinus: Bool = false) {
        if crossedIntoMinus { warning() } else { light.impactOccurred(intensity: 0.8); light.prepare() }
    }
    /// Today went from plus to minus. Only on the crossing, never for every spend while already negative.
    static func warning() { notifier.notificationOccurred(.warning); notifier.prepare() }
    /// Something that cannot be done: a future day, a slider past its envelope, an empty amount.
    static func boundary() { rigid.impactOccurred(intensity: 0.4); rigid.prepare() }
    static func prepare() { selector.prepare(); soft.prepare(); light.prepare() }

    /// Whether a save moves today's remainder from zero-or-more to below zero.
    static func crossesIntoMinus(before: Money?, after: Money?) -> Bool {
        guard let before, let after else { return false }
        return before.minorUnits >= 0 && after.minorUnits < 0
    }
}

/// The four curves of Folki. Sheets, navigation and the tab bar keep their system motion.
enum FolkiMotion {
    /// Digits while typing, chips, rows appearing.
    static let quick = Animation.snappy(duration: 0.25)
    /// Onboarding pages, history, switching days.
    static let standard = Animation.smooth(duration: 0.4)
    /// Rings filling and changing.
    static let ring = Animation.spring(duration: 0.9, bounce: 0.15)
    /// One-off moments, such as the first main screen after onboarding.
    static let hero = Animation.spring(duration: 1.2, bounce: 0.1)
    /// Delay between items of a cascade.
    static let cascadeStep = 0.08
    /// Reduce Motion replaces every animation with this fade.
    static let reduced = Animation.easeInOut(duration: 0.2)

    static func resolved(_ animation: Animation, reduceMotion: Bool) -> Animation {
        reduceMotion ? reduced : animation
    }
}

/// A soft tint of the text color for quiet fills.
extension Color {
    static let folkiSoft = Color.primary.opacity(0.07)
}

/// Secondary buttons: clear liquid glass, accent text.
struct FolkiSoftButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(FolkiFont.headline).foregroundStyle(Color.folkiAccent)
            .padding(.horizontal, 16).padding(.vertical, FolkiSpacing.item).frame(minHeight: 44)
            .glassEffect(.regular.interactive(), in: Capsule())
            .opacity(isEnabled ? 1 : 0.4)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
            .animation(.spring(duration: 0.25, bounce: 0.35), value: configuration.isPressed)
    }
}

/// The main action of a screen: accent-tinted liquid glass, white text.
struct FolkiPrimaryButtonStyle: ButtonStyle {
    var fullWidth = false
    var minHeight: CGFloat = FolkiSpacing.primaryButton
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(FolkiFont.primaryButton).foregroundStyle(.white)
            .padding(.horizontal, 20).frame(maxWidth: fullWidth ? .infinity : nil, minHeight: minHeight)
            .glassEffect(.regular.tint(Color.folkiAccent.opacity(isEnabled ? 1 : 0.35)).interactive(), in: Capsule())
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(.spring(duration: 0.25, bounce: 0.35), value: configuration.isPressed)
    }
}

/// Buttons that give a little under the finger.
struct FolkiPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var scale: CGFloat = 0.96
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? scale : 1)
            .animation(.spring(duration: 0.25, bounce: 0.35), value: configuration.isPressed)
    }
}

struct FolkiErrorMessage: View {
    let message: String
    var body: some View {
        Label(message, systemImage: "exclamationmark.circle")
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .font(FolkiFont.footnote).foregroundStyle(Color.folkiInk)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
    }
}

/// Cards rise in gently, one after another, the first time a screen appears.
private struct FolkiAppear: ViewModifier {
    let order: Int
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content
            .opacity(shown || reduceMotion ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : 14)
            .onAppear {
                guard !shown else { return }
                withAnimation(.spring(duration: 0.5, bounce: 0.2).delay(0.05 * Double(order))) { shown = true }
            }
    }
}

extension View {
    func folkiAppear(_ order: Int = 0) -> some View { modifier(FolkiAppear(order: order)) }
}

/// Closes an entry sheet without saving: one cross everywhere instead of a mix of words and icons.
struct FolkiCloseButton: View {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    var body: some View {
        Button(action: action) { Image(systemName: "xmark") }.accessibilityLabel("Закрыть")
    }
}
