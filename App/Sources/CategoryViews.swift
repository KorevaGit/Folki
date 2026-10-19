import SwiftUI
import UIKit
import FolkiDuoCore

extension CategoryColor {
    var color: Color {
        switch self {
        case .blue: Color(red: 0.22, green: 0.54, blue: 0.87)
        case .sky: Color(red: 0.35, green: 0.66, blue: 0.90)
        case .cyan: Color(red: 0.12, green: 0.64, blue: 0.77)
        case .indigo: Color(red: 0.35, green: 0.34, blue: 0.84)
        case .purple: Color(red: 0.56, green: 0.36, blue: 0.85)
        case .lavender: Color(red: 0.66, green: 0.61, blue: 0.91)
        case .pink: Color(red: 0.85, green: 0.42, blue: 0.63)
        case .plum: Color(red: 0.56, green: 0.23, blue: 0.43)
        case .brown: Color(red: 0.61, green: 0.42, blue: 0.25)
        case .slate: Color(red: 0.37, green: 0.45, blue: 0.52)
        case .gray: Color(red: 0.56, green: 0.56, blue: 0.58)
        }
    }
}

/// A colored circle with a white symbol, as list icons in Reminders.
struct CategoryIcon: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 28

    init(category: SpendingCategory, size: CGFloat = 28) {
        symbol = category.symbol; color = category.color.color; self.size = size
    }
    init(symbol: String, color: Color, size: CGFloat = 28) {
        self.symbol = symbol; self.color = color; self.size = size
    }

    var body: some View {
        Image(systemName: UIImage(systemName: symbol) == nil ? "tag.fill" : symbol)
            .font(.system(size: size * 0.48, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(color, in: Circle())
            .accessibilityHidden(true)
    }
}

enum CategorySymbols {
    static let groups: [(String, [String])] = [
        ("Еда", ["cart.fill", "basket.fill", "fork.knife", "cup.and.saucer.fill", "takeoutbag.and.cup.and.straw.fill",
                 "birthday.cake.fill", "wineglass.fill", "carrot.fill", "fish.fill"]),
        ("Дом", ["house.fill", "sofa.fill", "bed.double.fill", "lightbulb.fill", "drop.fill", "flame.fill",
                 "wrench.and.screwdriver.fill", "washer.fill", "key.fill"]),
        ("Транспорт", ["car.fill", "bus.fill", "tram.fill", "bicycle", "fuelpump.fill", "airplane", "ferry.fill", "parkingsign"]),
        ("Здоровье", ["cross.case.fill", "pills.fill", "heart.fill", "stethoscope", "dumbbell.fill", "figure.run", "figure.yoga"]),
        ("Дети и семья", ["figure.and.child.holdinghands", "stroller.fill", "teddybear.fill", "graduationcap.fill",
                          "book.fill", "pawprint.fill", "gift.fill", "person.2.fill"]),
        ("Отдых", ["theatermasks.fill", "film.fill", "gamecontroller.fill", "music.note", "ticket.fill",
                   "beach.umbrella.fill", "tent.fill", "camera.fill", "paintpalette.fill"]),
        ("Покупки", ["bag.fill", "tshirt.fill", "shoe.fill", "sparkles", "scissors", "eyeglasses", "laptopcomputer",
                     "iphone", "headphones"]),
        ("Финансы и связь", ["creditcard.fill", "banknote.fill", "building.columns.fill", "chart.line.uptrend.xyaxis",
                             "percent", "doc.text.fill", "wifi", "tv.fill", "phone.fill", "tag.fill", "ellipsis"])
    ].map { ($0.0, $0.1.filter { UIImage(systemName: $0) != nil }) }
}

/// Built-in categories plus the budget's own ones; own ones can be edited and archived.
struct CategoriesView: View {
    let session: BudgetSession
    @State private var editing: SpendingCategory?
    @State private var creating = false
    @State private var errorMessage: String?
    private var custom: [SpendingCategory] { session.catalog.all.filter { !$0.isBuiltIn } }

    var body: some View {
        List {
            Section {
                ForEach(custom.filter { !$0.isArchived }) { category in
                    Button { editing = category } label: { row(category) }.buttonStyle(.plain)
                        .swipeActions { Button("В архив") { setArchived(category, true) }.tint(.gray) }
                }
                Button("Новая категория", systemImage: "plus.circle.fill") { creating = true }
                    .disabled(session.result == nil || session.isDemo)
            } header: { Text("Свои") } footer: {
                Text(session.scope == .personal ? "Личные категории видишь только ты." : "Семейные категории видят все участники семьи.")
            }
            Section("Базовые") {
                ForEach(BuiltInCategory.all) { row($0) }
            }
            let archived = custom.filter(\.isArchived)
            if !archived.isEmpty {
                Section {
                    ForEach(archived) { category in
                        row(category).swipeActions { Button("Вернуть") { setArchived(category, false) }.tint(Color.folkiAccent) }
                    }
                } header: { Text("Архив") } footer: {
                    Text("Категории из архива нельзя выбрать для новых записей, но старые записи и аналитика их сохраняют.")
                }
            }
            if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
        }
        .navigationTitle(session.scope == .personal ? "Личные категории" : "Семейные категории")
        .sheet(isPresented: $creating) { CategoryEditorView(session: session, category: nil) }
        .sheet(item: $editing) { CategoryEditorView(session: session, category: $0) }
    }

    private func row(_ category: SpendingCategory) -> some View {
        HStack(spacing: 12) {
            CategoryIcon(category: category)
            Text(category.name)
            Spacer()
            Text(category.isEssential ? "Обязательная" : "Желание").font(.caption).foregroundStyle(.secondary)
        }.contentShape(Rectangle())
    }

    private func setArchived(_ category: SpendingCategory, _ archived: Bool) {
        do { try session.setCategoryArchived(category, archived: archived); errorMessage = nil }
        catch LedgerError.duplicateCategory { errorMessage = "Активная категория с таким названием уже есть. Переименуй её, чтобы вернуть эту." }
        catch { errorMessage = "Не удалось изменить категорию. Обнови экран и попробуй снова." }
    }
}

struct CategoryEditorView: View {
    @Environment(\.dismiss) private var dismiss
    let session: BudgetSession
    let category: SpendingCategory?
    @State private var name: String
    @State private var symbol: String
    @State private var color: CategoryColor
    @State private var isEssential: Bool
    @State private var errorMessage: String?

    init(session: BudgetSession, category: SpendingCategory?) {
        self.session = session; self.category = category
        _name = State(initialValue: category?.name ?? "")
        _symbol = State(initialValue: category?.symbol ?? "tag.fill")
        _color = State(initialValue: category?.color ?? .blue)
        _isEssential = State(initialValue: category?.isEssential ?? false)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 12) {
                        CategoryIcon(symbol: symbol, color: color.color, size: 44)
                        TextField("Название", text: $name).font(.title3)
                    }
                    Toggle("Обязательная трата", isOn: $isEssential)
                } footer: {
                    Text("Обязательные — то, без чего не обойтись: жильё, еда, лечение. Остальное — желания. В аналитике видно, как делятся траты.")
                }
                Section("Цвет") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 12) {
                        ForEach(CategoryColor.allCases) { item in
                            Circle().fill(item.color).frame(width: 34, height: 34)
                                .overlay { if item == color { Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(.white) } }
                                .onTapGesture { color = item }
                                .accessibilityLabel(item.rawValue).accessibilityAddTraits(item == color ? .isSelected : [])
                        }
                    }.padding(.vertical, 4)
                }
                ForEach(CategorySymbols.groups, id: \.0) { group in
                    Section(group.0) {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 12) {
                            ForEach(group.1, id: \.self) { item in
                                Image(systemName: item).font(.title3)
                                    .foregroundStyle(item == symbol ? .white : .primary)
                                    .frame(width: 40, height: 40)
                                    .background(item == symbol ? color.color : Color(uiColor: .tertiarySystemFill), in: Circle())
                                    .onTapGesture { symbol = item }
                                    .accessibilityLabel(item).accessibilityAddTraits(item == symbol ? .isSelected : [])
                            }
                        }.padding(.vertical, 4)
                    }
                }
                if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            }
            .navigationTitle(category == nil ? "Новая категория" : "Категория").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить", action: save).disabled(SpendingCategory.validName(name) == nil)
                }
            }
        }
    }

    private func save() {
        do {
            if let category {
                try session.updateCategory(category, name: name, symbol: symbol, color: color, isEssential: isEssential)
            } else {
                try session.createCategory(name: name, symbol: symbol, color: color, isEssential: isEssential)
            }
            dismiss()
        } catch LedgerError.duplicateCategory { errorMessage = "Категория с таким названием уже есть." }
        catch LedgerError.conflict { errorMessage = "Категорию уже изменили на другом устройстве. Закрой и открой её снова." }
        catch { errorMessage = "Не удалось сохранить категорию. Попробуй снова." }
    }
}
