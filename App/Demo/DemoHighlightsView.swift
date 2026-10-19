#if FOLKI_DEMO
import SwiftUI

struct DemoHighlightsView: View {
    let showAwards: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Накопления").font(.title2.bold()).padding(.top, 14)
            VStack(alignment: .leading, spacing: 12) {
                Label("Общая цель", systemImage: "flag.fill").font(.subheadline).foregroundStyle(Color.folkiAccent)
                Text("Путешествие").font(.headline)
                Text("48 000 ₽").font(.title2.bold())
                Text("из 80 000 ₽ · демонстрация").font(.caption).foregroundStyle(.secondary)
                ProgressView(value: 0.6).tint(Color.folkiAccent)
            }.budgetCard()
            HStack {
                Text("Награды").font(.title2.bold())
                Spacer()
                Button("Показать все", action: showAwards).font(.subheadline)
            }.padding(.top, 14)
            Button(action: showAwards) {
                HStack(spacing: 14) {
                    Image(systemName: "person.2.fill").font(.title2).foregroundStyle(Color.folkiAccent)
                        .frame(width: 50, height: 50).background(.quaternary, in: Circle())
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Планируем вдвоём").font(.headline)
                        Text("Пример достижения").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                }.budgetCard()
            }.buttonStyle(.plain)
        }
    }
}

struct DemoAwardsView: View {
    @State private var selected: DemoAward?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Примеры наград · правила будут подключены позже")
                    .font(.subheadline).foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    ForEach(DemoAward.all) { award in
                        Button { selected = award } label: {
                            VStack(spacing: 12) {
                                Image(systemName: award.symbol).font(.title2)
                                    .foregroundStyle(award.locked ? .secondary : Color.folkiAccent)
                                    .frame(width: 62, height: 62).background(.quaternary, in: Circle())
                                Text(award.name).font(.subheadline.weight(.semibold))
                                Text(award.subtitle).font(.caption).foregroundStyle(.secondary)
                                if award.locked { ProgressView(value: 5, total: 7).tint(Color.folkiAccent) }
                                Spacer(minLength: 0)
                            }.multilineTextAlignment(.center).frame(maxWidth: .infinity, minHeight: 170).budgetCard()
                        }.buttonStyle(.plain)
                    }
                }
            }.padding(16)
        }
        .background(Color(uiColor: .systemGroupedBackground)).navigationTitle("Награды")
        .sheet(item: $selected) { award in
            NavigationStack {
                Text(award.subtitle).padding(24).navigationTitle(award.name)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Готово") { selected = nil } } }
            }.presentationDetents([.medium])
        }
    }
}

private struct DemoAward: Identifiable {
    var id: String { name }
    let name: String
    let symbol: String
    let subtitle: String
    var locked = false
    static let all = [
        DemoAward(name: "Планируем вдвоём", symbol: "person.2.fill", subtitle: "Оба участвуют в бюджете"),
        DemoAward(name: "Первый шаг", symbol: "flag.fill", subtitle: "5 000 ₽ к общей цели"),
        DemoAward(name: "Ясный план", symbol: "checkmark.seal.fill", subtitle: "Платежи учтены"),
        DemoAward(name: "Неделя в ритме", symbol: "calendar.badge.checkmark", subtitle: "5 из 7 дней", locked: true)
    ]
}
#endif
