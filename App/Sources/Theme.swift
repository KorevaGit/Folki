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

/// Plain white by day; by night black with faint amber and malachite fields at the edges.
struct FolkiBackground: View {
    @Environment(\.colorScheme) private var scheme
    private typealias Field = (color: Color, x: CGFloat, y: CGFloat, size: CGFloat, opacity: Double)
    private var fields: [Field] {
        scheme == .dark
            ? [(Color(red: 0.72, green: 0.43, blue: 0.08), -0.75, -0.15, 640, 0.34),
               (Color(red: 0.06, green: 0.48, blue: 0.34), 0.65, 0.38, 570, 0.25),
               (Color(red: 0.42, green: 0.25, blue: 0.05), -0.75, 0.70, 610, 0.29),
               (Color(red: 0.05, green: 0.35, blue: 0.26), 0.65, 0.95, 550, 0.24)]
            : [] // Plain white by day: tinted fields on white read as dirt.
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
        start: .adaptive(light: (0.91, 0.54, 0.10), dark: (0.95, 0.66, 0.23)),
        end: .adaptive(light: (0.96, 0.70, 0.29), dark: (0.98, 0.79, 0.47)),
        text: .adaptive(light: (0.52, 0.31, 0.04), dark: (0.98, 0.78, 0.46)))
    static let family = RingPalette(
        start: .adaptive(light: (0.07, 0.52, 0.37), dark: (0.18, 0.72, 0.55)),
        end: .adaptive(light: (0.18, 0.71, 0.54), dark: (0.44, 0.83, 0.68)),
        text: .adaptive(light: (0.06, 0.43, 0.34), dark: (0.36, 0.79, 0.65)))

    static func palette(for scope: BudgetScope) -> RingPalette { scope == .personal ? personal : family }
}

/// A native segmented control with comfortable height, shared across budget screens.
struct FolkiSegmentedPicker<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [(String, Value)]
    var minimumHeight: CGFloat = 52
    @ScaledMetric(relativeTo: .body) private var height: CGFloat = 52

    var body: some View {
        FolkiNativeSegments(title: title, selection: $selection, options: options)
            .frame(maxWidth: .infinity).frame(height: max(minimumHeight, height))
    }
}

private struct FolkiNativeSegments<Value: Hashable>: UIViewRepresentable {
    let title: String
    @Binding var selection: Value
    let options: [(String, Value)]

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeUIView(context: Context) -> UISegmentedControl {
        let control = UISegmentedControl(items: options.map(\.0))
        control.addAction(UIAction { [weak control, weak coordinator = context.coordinator] _ in
            guard let control, let coordinator,
                  coordinator.parent.options.indices.contains(control.selectedSegmentIndex) else { return }
            FolkiFeedback.selection()
            coordinator.parent.selection = coordinator.parent.options[control.selectedSegmentIndex].1
        }, for: .valueChanged)
        return control
    }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UISegmentedControl, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? uiView.intrinsicContentSize.width, height: proposal.height ?? 52)
    }
    func updateUIView(_ control: UISegmentedControl, context: Context) {
        context.coordinator.parent = self
        if control.numberOfSegments != options.count || options.indices.contains(where: { control.titleForSegment(at: $0) != options[$0].0 }) {
            control.removeAllSegments()
            for (index, item) in options.enumerated() { control.insertSegment(withTitle: item.0, at: index, animated: false) }
        }
        control.selectedSegmentIndex = options.firstIndex(where: { $0.1 == selection }) ?? UISegmentedControl.noSegment
        control.setTitleTextAttributes([.font: UIFont.preferredFont(forTextStyle: .body)], for: .normal)
        control.accessibilityLabel = title
    }
    final class Coordinator {
        var parent: FolkiNativeSegments
        init(parent: FolkiNativeSegments) { self.parent = parent }
    }
}

/// Shared page grid. Cards add their own 16-point content inset inside these margins.
enum FolkiSpacing {
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


/// Distinct feedback for selection, the calendar boundary, and successful saves.
/// One place for haptics. Generators are kept and prepared so taps answer without delay.
@MainActor enum FolkiFeedback {
    private static let selector = UISelectionFeedbackGenerator()
    private static let soft = UIImpactFeedbackGenerator(style: .soft)
    private static let light = UIImpactFeedbackGenerator(style: .light)
    private static let medium = UIImpactFeedbackGenerator(style: .medium)
    private static let rigid = UIImpactFeedbackGenerator(style: .rigid)
    private static let notifier = UINotificationFeedbackGenerator()

    static func saved(overspending: Bool = false) {
        if overspending { notifier.notificationOccurred(.warning) }
        else { light.impactOccurred(intensity: 0.8); light.prepare() }
    }
    /// A light tick for picking values: days, colors, segments, categories.
    static func selection() { selector.selectionChanged(); selector.prepare() }
    /// A soft key press, like a real keyboard.
    static func key() { soft.impactOccurred(intensity: 0.55); soft.prepare() }
    /// A key that did nothing: a third decimal, a second comma, an empty delete.
    static func refused() { rigid.impactOccurred(intensity: 0.4); rigid.prepare() }
    /// Opening a main action.
    static func tap() { light.impactOccurred(intensity: 0.7); light.prepare() }
    /// A firm click when the rings switch between day and month.
    static func toggle() { medium.impactOccurred(intensity: 1); medium.prepare() }
    /// A soft bump when a swipe hits today.
    static func boundary() { soft.impactOccurred(intensity: 0.9); soft.prepare() }
    static func prepare() { selector.prepare(); soft.prepare(); light.prepare() }
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
            .font(.footnote).foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
    }
}
