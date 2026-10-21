import SwiftUI
import UIKit
import FolkiDuoCore

extension CategoryColor {
    var title: String {
        switch self {
        case .blue: String(localized: "Синий"); case .sky: String(localized: "Голубой"); case .cyan: String(localized: "Бирюзовый")
        case .indigo: String(localized: "Индиго"); case .purple: String(localized: "Фиолетовый"); case .lavender: String(localized: "Лавандовый")
        case .pink: String(localized: "Розовый"); case .plum: String(localized: "Сливовый"); case .brown: String(localized: "Коричневый")
        case .slate: String(localized: "Серо-синий"); case .gray: String(localized: "Серый")
        }
    }

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
    static func title(for symbol: String) -> String { titles[symbol] ?? String(localized: "Значок категории") }
    private static let titles = [
        "cart.fill": String(localized: "Продуктовая тележка"), "basket.fill": String(localized: "Корзина"), "fork.knife": String(localized: "Еда"), "cup.and.saucer.fill": String(localized: "Кофе"),
        "takeoutbag.and.cup.and.straw.fill": String(localized: "Еда с собой"), "birthday.cake.fill": String(localized: "Торт"), "wineglass.fill": String(localized: "Бокал"),
        "carrot.fill": String(localized: "Овощи"), "fish.fill": String(localized: "Рыба"), "house.fill": String(localized: "Дом"), "sofa.fill": String(localized: "Мебель"), "bed.double.fill": String(localized: "Кровать"),
        "lightbulb.fill": String(localized: "Электричество"), "drop.fill": String(localized: "Вода"), "flame.fill": String(localized: "Отопление"), "wrench.and.screwdriver.fill": String(localized: "Ремонт"),
        "washer.fill": String(localized: "Бытовая техника"), "key.fill": String(localized: "Ключи"), "car.fill": String(localized: "Автомобиль"), "bus.fill": String(localized: "Автобус"),
        "tram.fill": String(localized: "Трамвай"), "bicycle": String(localized: "Велосипед"), "fuelpump.fill": String(localized: "Топливо"), "airplane": String(localized: "Самолёт"), "ferry.fill": String(localized: "Паром"),
        "parkingsign": String(localized: "Парковка"), "cross.case.fill": String(localized: "Медицина"), "pills.fill": String(localized: "Лекарства"), "heart.fill": String(localized: "Здоровье"),
        "stethoscope": String(localized: "Врач"), "dumbbell.fill": String(localized: "Спортзал"), "figure.run": String(localized: "Бег"), "figure.yoga": String(localized: "Йога"),
        "figure.and.child.holdinghands": String(localized: "Семья"), "stroller.fill": String(localized: "Коляска"), "teddybear.fill": String(localized: "Игрушки"),
        "graduationcap.fill": String(localized: "Образование"), "book.fill": String(localized: "Книги"), "pawprint.fill": String(localized: "Животные"), "gift.fill": String(localized: "Подарки"),
        "person.2.fill": String(localized: "Люди"), "theatermasks.fill": String(localized: "Театр"), "film.fill": String(localized: "Кино"), "gamecontroller.fill": String(localized: "Игры"),
        "music.note": String(localized: "Музыка"), "ticket.fill": String(localized: "Билеты"), "beach.umbrella.fill": String(localized: "Пляж"), "tent.fill": String(localized: "Поход"),
        "camera.fill": String(localized: "Фото"), "paintpalette.fill": String(localized: "Творчество"), "bag.fill": String(localized: "Покупки"), "tshirt.fill": String(localized: "Одежда"),
        "shoe.fill": String(localized: "Обувь"), "sparkles": String(localized: "Уход за собой"), "scissors": String(localized: "Парикмахерская"), "eyeglasses": String(localized: "Очки"),
        "laptopcomputer": String(localized: "Компьютер"), "iphone": String(localized: "Телефон"), "headphones": String(localized: "Наушники"), "creditcard.fill": String(localized: "Банковская карта"),
        "banknote.fill": String(localized: "Наличные"), "building.columns.fill": String(localized: "Банк"), "chart.line.uptrend.xyaxis": String(localized: "Финансы"),
        "percent": String(localized: "Проценты"), "doc.text.fill": String(localized: "Документы"), "wifi": String(localized: "Интернет"), "tv.fill": String(localized: "Телевидение"),
        "phone.fill": String(localized: "Связь"), "tag.fill": String(localized: "Категория"), "ellipsis": String(localized: "Другое")
    ]

    static let groups: [(String, [String])] = [
        (String(localized: "Еда"), ["cart.fill", "basket.fill", "fork.knife", "cup.and.saucer.fill", "takeoutbag.and.cup.and.straw.fill",
                 "birthday.cake.fill", "wineglass.fill", "carrot.fill", "fish.fill"]),
        (String(localized: "Дом"), ["house.fill", "sofa.fill", "bed.double.fill", "lightbulb.fill", "drop.fill", "flame.fill",
                 "wrench.and.screwdriver.fill", "washer.fill", "key.fill"]),
        (String(localized: "Транспорт"), ["car.fill", "bus.fill", "tram.fill", "bicycle", "fuelpump.fill", "airplane", "ferry.fill", "parkingsign"]),
        (String(localized: "Здоровье"), ["cross.case.fill", "pills.fill", "heart.fill", "stethoscope", "dumbbell.fill", "figure.run", "figure.yoga"]),
        (String(localized: "Дети и семья"), ["figure.and.child.holdinghands", "stroller.fill", "teddybear.fill", "graduationcap.fill",
                          "book.fill", "pawprint.fill", "gift.fill", "person.2.fill"]),
        (String(localized: "Отдых"), ["theatermasks.fill", "film.fill", "gamecontroller.fill", "music.note", "ticket.fill",
                   "beach.umbrella.fill", "tent.fill", "camera.fill", "paintpalette.fill"]),
        (String(localized: "Покупки"), ["bag.fill", "tshirt.fill", "shoe.fill", "sparkles", "scissors", "eyeglasses", "laptopcomputer",
                     "iphone", "headphones"]),
        (String(localized: "Финансы и связь"), ["creditcard.fill", "banknote.fill", "building.columns.fill", "chart.line.uptrend.xyaxis",
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
                Text(session.scope == .personal ? String(localized: "Их видишь только ты 🤫") : String(localized: "Их видит вся семья 💚"))
            }
            // Built-ins grouped by kind, so the tag on every row is not needed.
            Section("Используются") {
                ForEach(session.catalog.enabledBuiltIns, id: \.self) { builtIn in
                    row(builtIn.category).swipeActions { Button("Убрать", role: .destructive) { setBuiltIn(builtIn, false) } }
                }
            }
            let available = session.catalog.availableBuiltIns
            if !available.isEmpty {
                Section("Можно добавить") {
                    ForEach(available, id: \.self) { builtIn in
                        Button { setBuiltIn(builtIn, true) } label: {
                            HStack { row(builtIn.category); Image(systemName: "plus.circle.fill").foregroundStyle(Color.folkiAccent) }
                        }.buttonStyle(.plain)
                    }
                }
            }
            let archived = custom.filter(\.isArchived)
            if !archived.isEmpty {
                Section {
                    ForEach(archived) { category in
                        row(category).swipeActions { Button("Вернуть") { setArchived(category, false) }.tint(Color.folkiAccent) }
                    }
                } header: { Text("Архив") } footer: {
                    Text("Старые записи с ними никуда не денутся 📦")
                }
            }
            if let errorMessage { FolkiErrorMessage(message: errorMessage) }
        }
        .folkiFormLayout()
        .navigationTitle(session.scope == .personal ? String(localized: "Личные категории") : String(localized: "Семейные категории"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $creating) { CategoryEditorView(session: session, category: nil) }
        .sheet(item: $editing) { CategoryEditorView(session: session, category: $0) }
    }

    private func row(_ category: SpendingCategory, showsKind: Bool = true) -> some View {
        HStack(spacing: 12) {
            CategoryIcon(category: category, size: 30)
            Text(category.name)
            Spacer()
            if showsKind {
                Text(category.isEssential ? String(localized: "обязательное") : String(localized: "желание")).font(.caption).foregroundStyle(.secondary)
            }
        }.frame(minHeight: 40).contentShape(Rectangle())
    }

    private func setBuiltIn(_ builtIn: BuiltInCategory, _ enabled: Bool) {
        do { try session.setBuiltInCategory(builtIn, enabled: enabled); FolkiFeedback.selection(); errorMessage = nil }
        catch { errorMessage = String(localized: "Не получилось изменить категорию. Обнови экран и попробуй снова.") }
    }

    private func setArchived(_ category: SpendingCategory, _ archived: Bool) {
        do { try session.setCategoryArchived(category, archived: archived); errorMessage = nil }
        catch LedgerError.duplicateCategory { errorMessage = String(localized: "Активная категория с таким названием уже есть. Переименуй её, чтобы вернуть эту.") }
        catch { errorMessage = String(localized: "Не получилось изменить категорию. Обнови экран и попробуй снова.") }
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
                // A big preview, like Reminders lists.
                Section {
                    VStack(spacing: 14) {
                        CategoryIcon(symbol: symbol, color: color.color, size: 76)
                            .animation(FolkiMotion.quick, value: symbol)
                        TextField("Название", text: $name)
                            .font(.system(.title2, design: .rounded, weight: .bold)).multilineTextAlignment(.center)
                            .padding(.vertical, 10).padding(.horizontal, 14)
                            .background(Color.folkiSoft, in: RoundedRectangle(cornerRadius: FolkiSpacing.controlRadius, style: .continuous))
                    }.frame(maxWidth: .infinity).padding(.vertical, 8)
                }
                Section {
                    Toggle("Обязательная трата", isOn: $isEssential).sensoryFeedback(.selection, trigger: isEssential)
                } footer: {
                    Text("Обязательное — жильё, еда, лечение. Остальное — желания 🎈")
                }
                Section("Цвет") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 44), spacing: 12)], spacing: 12) {
                        ForEach(CategoryColor.allCases) { item in
                            Button { color = item; FolkiFeedback.selection() } label: {
                                Circle().fill(item.color).frame(width: 44, height: 44)
                                    .overlay { if item == color { Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(.white) } }
                            }.buttonStyle(.plain)
                                .accessibilityLabel(item.title).accessibilityAddTraits(item == color ? .isSelected : [])
                        }
                    }.padding(.vertical, 4)
                }
                ForEach(CategorySymbols.groups, id: \.0) { group in
                    Section(group.0) {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 44), spacing: 12)], spacing: 12) {
                            ForEach(group.1, id: \.self) { item in
                                Button { symbol = item; FolkiFeedback.selection() } label: {
                                    Image(systemName: item).font(.title3)
                                        .foregroundStyle(item == symbol ? .white : .primary)
                                        .frame(width: 44, height: 44)
                                        .background(item == symbol ? color.color : Color(uiColor: .tertiarySystemFill), in: Circle())
                                }.buttonStyle(.plain)
                                    .accessibilityLabel(CategorySymbols.title(for: item))
                                    .accessibilityAddTraits(item == symbol ? .isSelected : [])
                            }
                        }.padding(.vertical, 4)
                    }
                }
                if let errorMessage { FolkiErrorMessage(message: errorMessage) }
            }
            .folkiFormLayout()
            .navigationTitle(category == nil ? String(localized: "Новая категория") : String(localized: "Категория")).toolbarTitleDisplayMode(.inlineLarge)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { FolkiCloseButton { dismiss() } }
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
            FolkiFeedback.saved()
            dismiss()
        } catch LedgerError.duplicateCategory { errorMessage = String(localized: "Категория с таким названием уже есть.") }
        catch LedgerError.conflict { errorMessage = String(localized: "Категорию уже изменили на другом устройстве. Закрой и открой её снова.") }
        catch { errorMessage = String(localized: "Не получилось сохранить категорию. Попробуй снова.") }
    }
}
