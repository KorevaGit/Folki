import SwiftUI
import FolkiDuoCore

/// Family members as glass bubbles of different sizes, plus a bubble to invite someone.
/// Bubbles pop in one by one and drift slightly, like soap bubbles.
struct FamilyBubbles: View {
    let family: BudgetSession
    let invite: () -> Void
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Five places around the plus: size and centre as fractions of the area.
    private let slots: [(size: CGFloat, x: CGFloat, y: CGFloat)] = [
        (0.40, 0.64, 0.26), (0.27, 0.31, 0.22), (0.19, 0.47, 0.03), (0.18, 0.27, 0.56), (0.12, 0.70, 0.04)
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
                    bubble(member: index < members.count ? members[index] : nil, tint: tints[index], size: side * slot.size)
                        .position(x: geo.size.width / 2 + (slot.x - 0.5) * side, y: geo.size.height * slot.y + side * slot.size / 2)
                        .modifier(Pop(shown: shown || reduceMotion, delay: Double(index) * 0.08))
                        .modifier(Drift(seed: index, active: !reduceMotion))
                }
                Button(action: invite) {
                    Image(systemName: "plus").font(.system(size: side * 0.1, weight: .medium)).foregroundStyle(.white)
                        .frame(width: side * 0.3, height: side * 0.3)
                        .background(LinearGradient(colors: [Color(red: 0.78, green: 0.76, blue: 0.88), Color(red: 0.68, green: 0.68, blue: 0.78)],
                                                   startPoint: .topLeading, endPoint: .bottomTrailing), in: Circle())
                        .glassEffect(.regular.interactive(), in: Circle())
                }
                .buttonStyle(FolkiPressStyle(scale: 0.9))
                .position(x: geo.size.width / 2 + side * 0.03, y: geo.size.height - side * 0.2)
                .modifier(Pop(shown: shown || reduceMotion, delay: 0.45))
                .accessibilityLabel("Пригласить")
            }
        }
        .onAppear { shown = true }
    }

    @ViewBuilder private func bubble(member: Member?, tint: Color, size: CGFloat) -> some View {
        ZStack {
            Circle().fill(LinearGradient(colors: [tint.opacity(member == nil ? 0.18 : 0.95), tint.opacity(member == nil ? 0.08 : 0.6)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
            if let member {
                Text(initials(family.memberName(member.id)))
                    .font(.system(size: size * 0.36, weight: .bold, design: .rounded)).foregroundStyle(.white)
            } else {
                Image(systemName: "person.fill").font(.system(size: size * 0.32)).foregroundStyle(tint.opacity(0.35))
            }
        }
        .frame(width: size, height: size)
        // The glass rim and highlight make it read as a bubble.
        .glassEffect(.regular, in: Circle())
        .accessibilityElement()
        .accessibilityLabel(member.map { family.memberName($0.id) } ?? String(localized: "Свободное место"))
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
            .animation(.spring(duration: 0.7, bounce: 0.5).delay(delay), value: shown)
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
    }
}
