import SwiftUI
import FolkiDuoCore

/// Family members as glass bubbles of different sizes, plus a bubble to invite someone.
/// Bubbles pop in one by one and drift slightly, like soap bubbles.
struct FamilyBubbles: View {
    let family: BudgetSession
    /// Nil on the welcome screen: there the bubbles only illustrate, and the buttons below choose.
    var invite: (() -> Void)? = nil
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Five places around the plus: size and centre as fractions of the area.
    private let slots: [(size: CGFloat, x: CGFloat, y: CGFloat)] = [
        (0.53, 0.66, 0.24), (0.43, 0.22, 0.08), (0.23, 0.54, 0.0), (0.23, 0.17, 0.62), (0.18, 0.89, 0.02)
    ]
    private let tints: [Color] = [
        Color.budget(.family), Color.budget(.personal), Color(red: 0.55, green: 0.47, blue: 0.86),
        Color(red: 0.30, green: 0.56, blue: 0.86), Color(red: 0.86, green: 0.42, blue: 0.55)
    ]

    var body: some View {
        let members = Array(family.members.filter(\.isActive).prefix(5))
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height * 1.15)
            ZStack {
                ForEach(0..<slots.count, id: \.self) { index in
                    let slot = slots[index]
                    bubble(member: index < members.count ? members[index] : nil, tint: tints[index], size: side * slot.size, index: index)
                        .position(x: geo.size.width / 2 + (slot.x - 0.5) * side, y: geo.size.height * slot.y + side * slot.size / 2)
                        .modifier(Pop(shown: shown || reduceMotion, delay: Double(index) * 0.08))
                        .modifier(Drift(seed: index, active: !reduceMotion))
                }
                if let invite {
                Button(action: invite) {
                    Image(systemName: "plus").font(.system(size: side * 0.1, weight: .medium)).foregroundStyle(.white)
                        .frame(width: side * 0.26, height: side * 0.26)
                        .background(LinearGradient(colors: [Color(red: 0.78, green: 0.76, blue: 0.88), Color(red: 0.68, green: 0.68, blue: 0.78)],
                                                   startPoint: .topLeading, endPoint: .bottomTrailing), in: Circle())
                        .glassEffect(.regular.interactive(), in: Circle())
                }
                .buttonStyle(FolkiPressStyle(scale: 0.9))
                .position(x: geo.size.width / 2 - side * 0.17, y: geo.size.height - side * 0.13)
                .modifier(Pop(shown: shown || reduceMotion, delay: 0.45))
                .accessibilityLabel("Пригласить")
                }
            }
        }
        .onAppear { shown = true }
    }

    @ViewBuilder private func bubble(member: Member?, tint: Color, size: CGFloat, index: Int) -> some View {
        ZStack {
            Circle().fill(LinearGradient(colors: [tint.opacity(member == nil ? 0.18 : 0.95), tint.opacity(member == nil ? 0.08 : 0.6)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
            if let member {
                VStack(spacing: 4) {
                    Text(initials(family.memberName(member.id))).font(.system(size: size * 0.22, weight: .bold, design: .rounded))
                    if size > 105 {
                        Text(family.memberName(member.id)).font(.system(size: 12, weight: .semibold))
                        Text("Траты \(total(for: member, kind: .expense))").font(.system(size: 10))
                        Text("Взносы \(total(for: member, kind: .contributionIn))").font(.system(size: 10))
                    }
                }.foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.65).padding(10)
            } else {
                VStack(spacing: 6) {
                    Image(systemName: index == 0 ? "basket.fill" : index == 1 ? "heart.fill" : "person.fill")
                        .font(.system(size: size * 0.23))
                    if size > 105 { Text(index == 0 ? "Общие траты" : "Взносы в бюджет")
                        .font(.system(size: 12, weight: .semibold)).multilineTextAlignment(.center) }
                }.foregroundStyle(tint.opacity(0.8)).padding(12)
            }
        }
        .frame(width: size, height: size)
        // The glass rim and highlight make it read as a bubble.
        .glassEffect(.regular, in: Circle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(member.map { family.memberName($0.id) } ?? (index == 0 ? String(localized: "Общие траты") : index == 1 ? String(localized: "Взносы в бюджет") : String(localized: "Свободное место")))
    }

    private func total(for member: Member, kind: TransactionKind) -> String {
        let records = family.records.filter { $0.transaction.payerID == member.id && $0.transaction.kind == kind }
        let total = try? records.reduce(Money(minorUnits: 0)) { try $0.adding($1.transaction.amount) }
        return total.map(MoneyText.whole) ?? "—"
    }

    private func initials(_ name: String) -> String {
        let letters = name.split(whereSeparator: \.isWhitespace).prefix(2).compactMap(\.first)
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }
}

/// Scales a bubble in with a bouncy spring.
private struct Pop: ViewModifier {
    let shown: Bool
    let delay: Double
    func body(content: Content) -> some View {
        content.scaleEffect(shown ? 1 : 0.2).opacity(shown ? 1 : 0)
            .animation(FolkiMotion.ring.delay(delay), value: shown)
    }
}

/// A slow drift so the cluster feels alive.
private struct Drift: ViewModifier {
    let seed: Int
    let active: Bool
    @State private var up = false
    func body(content: Content) -> some View {
        content.offset(x: up ? CGFloat(seed % 2 == 0 ? 3 : -3) : 0, y: up ? -5 : 5)
            .onAppear {
                guard active else { return }
                withAnimation(.easeInOut(duration: 2.2 + Double(seed) * 0.35).repeatForever(autoreverses: true)) { up = true }
            }
            .onDisappear { var t = Transaction(animation: nil); t.disablesAnimations = true; withTransaction(t) { up = false } }
    }
}
