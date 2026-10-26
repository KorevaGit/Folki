import Foundation
import Testing
@testable import FolkiDuoCore

struct LedgerCSVTests {
    private let moscow = TimeZone(identifier: "Europe/Moscow")!

    @Test(arguments: [(Int64(-123450), "-1234,50"), (5, "0,05"), (100_000, "1000,00"), (0, "0,00")])
    func amountsUseDecimalCommaWithoutGrouping(minor: Int64, expected: String) {
        #expect(LedgerCSV.amountText(Money(minorUnits: minor)) == expected)
    }

    @Test func fieldsWithSeparatorsAreQuotedAndFormulasDefused() {
        #expect(LedgerCSV.field("Кафе; бар") == "\"Кафе; бар\"")
        #expect(LedgerCSV.field("Сказал \"да\"") == "\"Сказал \"\"да\"\"\"")
        #expect(LedgerCSV.field("=HYPERLINK(1)") == "'=HYPERLINK(1)")
        #expect(LedgerCSV.field("-350,00") == "-350,00")
    }

    @Test func rowsGoOldestFirstAfterHeaderWithBOM() {
        let later = Date(timeIntervalSince1970: 1_792_000_000)
        let earlier = later.addingTimeInterval(-86_400)
        let rows = [
            LedgerCSV.Row(date: later, budget: "Личный", kind: "Трата", category: "Кафе", amount: Money(minorUnits: -35000), author: "Я", title: ""),
            LedgerCSV.Row(date: earlier, budget: "Личный", kind: "Поступление", category: "", amount: Money(minorUnits: 4_500_000), author: "Я", title: "Зарплата")
        ]
        let text = LedgerCSV.make(header: ["Дата", "Бюджет", "Тип", "Категория", "Сумма", "Кто", "Описание"], rows: rows, timeZone: moscow)
        #expect(text.hasPrefix("\u{FEFF}Дата;Бюджет;"))
        let lines = text.dropFirst().split(separator: "\r\n")
        #expect(lines.count == 3)
        #expect(lines[1].contains("Поступление;;45000,00;Я;Зарплата"))
        #expect(lines[2].hasSuffix("Трата;Кафе;-350,00;Я;"))
    }
}
