import SwiftUI
import Observation
import FolkiDuoCore

@MainActor @Observable
final class CurrencyDisplay {
    static let shared = CurrencyDisplay()
    static let currencies = ["RUB", "USD", "EUR", "GBP", "CNY", "KZT", "TRY", "AED", "JPY"]
    private(set) var activeQuote: CurrencyQuote?
    private(set) var rates: ExchangeRates?
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private let defaults = UserDefaults.standard

    private init() {
        if let data = defaults.data(forKey: "FolkiDisplayCurrency"),
           let quote = try? JSONDecoder().decode(CurrencyQuote.self, from: data),
           Self.currencies.contains(quote.code), quote.code != "RUB" { activeQuote = quote }
        if let data = defaults.data(forKey: "FolkiExchangeRates") {
            rates = try? JSONDecoder().decode(ExchangeRates.self, from: data)
        }
    }
    var code: String { activeQuote?.code ?? "RUB" }
    var currency: Currency { activeQuote?.currency ?? .rub }
    var symbol: String {
        ["RUB": "₽", "USD": "$", "EUR": "€", "GBP": "£", "CNY": "¥", "KZT": "₸", "TRY": "₺", "AED": "AED", "JPY": "¥"][code] ?? code
    }
    func apply(_ quote: CurrencyQuote?) {
        activeQuote = quote
        if let quote, let data = try? JSONEncoder().encode(quote) { defaults.set(data, forKey: "FolkiDisplayCurrency") }
        else { defaults.removeObject(forKey: "FolkiDisplayCurrency") }
    }
    func refreshRates() async {
        guard !isLoading else { return }
        isLoading = true; errorMessage = nil
        defer { isLoading = false }
        do {
            var request = URLRequest(url: URL(string: "https://www.cbr.ru/scripts/XML_daily.asp")!)
            request.timeoutInterval = 20
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200, data.count < 1_000_000 else {
                throw ExchangeRateError.invalidFeed
            }
            let fetched = try ExchangeRates.parseCBR(data)
            rates = fetched
            if let data = try? JSONEncoder().encode(fetched) { defaults.set(data, forKey: "FolkiExchangeRates") }
        } catch {
            errorMessage = "Курсы не обновлены. Можно использовать сохранённый курс или указать свой."
        }
    }
}

struct BudgetSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    let personal: BudgetSession
    let family: BudgetSession
    @State private var display = CurrencyDisplay.shared
    @State private var selectedCode = CurrencyDisplay.shared.code
    @State private var manual = false
    @State private var manualRate = ""
    @State private var setupScope: BudgetScope?

    init(personal: BudgetSession, family: BudgetSession) {
        self.personal = personal; self.family = family
        let active = CurrencyDisplay.shared.activeQuote
        _manual = State(initialValue: active?.isManual ?? false)
        _manualRate = State(initialValue: active.map { NSDecimalNumber(decimal: $0.rublesPerUnit).stringValue } ?? "")
    }
    private var quote: CurrencyQuote? {
        guard selectedCode != "RUB" else { return nil }
        if manual {
            let text = manualRate.replacingOccurrences(of: ",", with: ".")
            guard text.range(of: "^[0-9]+(?:\\.[0-9]{1,8})?$", options: .regularExpression) != nil,
                  let value = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")) else { return nil }
            if let active = display.activeQuote, active.isManual, active.code == selectedCode,
               active.rublesPerUnit == value { return active }
            return try? CurrencyQuote(code: selectedCode, rublesPerUnit: value, date: .now, isManual: true)
        }
        return (try? display.rates?.quote(for: selectedCode)) ?? (display.activeQuote?.code == selectedCode ? display.activeQuote : nil)
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Валюта", selection: $selectedCode) {
                        ForEach(CurrencyDisplay.currencies, id: \.self) { code in
                            Text("\(code) · \(Locale(identifier: "ru_RU").localizedString(forCurrencyCode: code) ?? code)").tag(code)
                        }
                    }
                    if selectedCode != "RUB" {
                        Toggle("Указать курс вручную", isOn: $manual)
                        if manual {
                            TextField("Рублей за 1 \(selectedCode)", text: $manualRate).keyboardType(.decimalPad)
                        }
                        if let quote {
                            LabeledContent("Курс", value: "1 \(quote.code) = \(rateText(quote.rublesPerUnit)) ₽")
                            LabeledContent(quote.isManual ? "Свой курс от" : "Курс ЦБ от") {
                                Text(quote.date, format: .dateTime.day().month(.wide).year())
                            }
                            Text("Для истории тоже используется этот курс. Суммы округляются до минимальной единицы выбранной валюты.")
                                .font(.footnote).foregroundStyle(.secondary)
                        } else {
                            Text("Загрузите курс или введите свой, чтобы включить конвертацию.")
                                .foregroundStyle(.secondary)
                        }
                    }
                    Button { Task { await display.refreshRates() } } label: {
                        HStack { Text("Обновить курсы ЦБ"); Spacer(); if display.isLoading { ProgressView() } }
                    }.disabled(display.isLoading)
                    if let error = display.errorMessage { Text(error).font(.footnote).foregroundStyle(.secondary) }
                    Link("Источник курсов — Банк России", destination: URL(string: "https://www.cbr.ru/development/sxml/")!)
                        .font(.footnote)
                } header: { Text("Валюта на этом устройстве") } footer: {
                    Text("Валюта применяется к обоим бюджетам, истории и накоплениям. Новые суммы можно вводить в выбранной валюте. Исходные записи сохраняются в рублях; смена валюты их не перезаписывает.")
                }
                if selectedCode == "RUB" || quote != nil {
                    Section("После применения") {
                        preview(personal, title: "Личный · месяц")
                        preview(family, title: "Семейный · месяц")
                        Button("Применить валюту") { display.apply(quote); dismiss() }
                    }
                }
                Section("Планы бюджета") {
                    plan(personal)
                    plan(family)
                }
            }
            .navigationTitle("Настройки бюджета").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } } }
            .onChange(of: selectedCode) { manual = false; manualRate = "" }
            .task { if display.rates == nil { await display.refreshRates() } }
            .sheet(item: $setupScope) { scope in BudgetSetupView(session: scope == .personal ? personal : family) }
        }
    }
    @ViewBuilder private func preview(_ session: BudgetSession, title: String) -> some View {
        if let money = session.result?.monthlyRemaining {
            LabeledContent(title, value: MoneyText.string(money, quote: quote))
        }
    }
    @ViewBuilder private func plan(_ session: BudgetSession) -> some View {
        if let result = session.result {
            LabeledContent(session.scope.title + " лимит", value: MoneyText.string(result.monthlyPlan))
        } else {
            Button("Настроить \(session.scope == .personal ? "личный" : "семейный") план") { setupScope = session.scope }
        }
    }
    private func rateText(_ value: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "ru_RU"); formatter.maximumFractionDigits = 8
        return formatter.string(from: NSDecimalNumber(decimal: value)) ?? "—"
    }
}

extension Color {
    static var folkiAccent: Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.38, green: 0.74, blue: 0.89, alpha: 1)
                : UIColor(red: 0.16, green: 0.30, blue: 0.55, alpha: 1)
        })
    }
}
