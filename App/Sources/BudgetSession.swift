import Foundation
import Observation
import FolkiDuoCore

struct Member: Identifiable {
    let id: UUID
    let name: String
}

struct LedgerRecord: Identifiable {
    let transaction: TransactionSnapshot
    let title: String
    let symbol: String
    var id: UUID { transaction.id }
}

@MainActor @Observable
final class BudgetSession {
    private(set) var household: HouseholdSnapshot?
    private(set) var result: DailyBudgetSnapshot?
    private(set) var records: [LedgerRecord]
    private(set) var errorMessage: String?
    let members: [Member]
    let demoDate: Date?
    var referenceDate: Date { demoDate ?? .now }
    var isDemo: Bool { demoDate != nil }

    init(household: HouseholdSnapshot? = nil, records: [LedgerRecord] = [],
         members: [Member] = [Member(id: UUID(), name: "Я"), Member(id: UUID(), name: "Партнёр")],
         demoDate: Date? = nil) {
        self.household = household
        self.records = records
        self.members = members
        self.demoDate = demoDate
        refresh()
    }

    func refresh() {
        guard let household else { result = nil; errorMessage = nil; return }
        do {
            result = try DailyBudgetCalculator.calculate(household, asOf: referenceDate)
            errorMessage = nil
        } catch BudgetError.dateOutsidePeriod {
            result = nil
            errorMessage = "Период закончился. Создайте новый план месяца."
        } catch {
            result = nil
            errorMessage = "Не удалось рассчитать бюджет. Проверьте суммы и резервы."
        }
    }

    func createPlan(monthlyPlan: Money, available: Money) throws {
        guard monthlyPlan.minorUnits > 0, available.minorUnits >= 0 else { throw BudgetError.invalidPlan }
        let period = try BudgetPeriodResolver.month(containing: referenceDate, timeZoneIdentifier: TimeZone.current.identifier)
        let candidate = HouseholdSnapshot(period: period, monthlyFreePlan: monthlyPlan, openingFunds: available)
        let calculated = try DailyBudgetCalculator.calculate(candidate, asOf: referenceDate)
        household = candidate
        result = calculated
        records = []
        errorMessage = nil
    }

    func addExpense(amount: Money, title: String, payerID: UUID) throws {
        guard let household, amount.minorUnits > 0,
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              members.contains(where: { $0.id == payerID }), let author = members.first else {
            throw BudgetError.invalidTransaction
        }
        let entry = TransactionSnapshot(amount: amount, kind: .expense, date: referenceDate,
                                        authorID: author.id, payerID: payerID)
        let candidate = HouseholdSnapshot(id: household.id, period: household.period,
            monthlyFreePlan: household.monthlyFreePlan, openingFunds: household.openingFunds,
            reserves: household.reserves, transactions: household.transactions + [entry])
        let calculated = try DailyBudgetCalculator.calculate(candidate, asOf: referenceDate)
        self.household = candidate
        result = calculated
        records.append(LedgerRecord(transaction: entry, title: title.trimmingCharacters(in: .whitespacesAndNewlines), symbol: "receipt.fill"))
    }

    func payerName(for record: LedgerRecord) -> String {
        members.first(where: { $0.id == record.transaction.payerID })?.name ?? "Участник"
    }
}

enum MoneyText {
    static func string(_ money: Money) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.numberStyle = .currency
        formatter.currencyCode = money.currency.code
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = money.currency.fractionDigits
        return formatter.string(from: NSDecimalNumber(decimal: money.decimalValue)) ?? "—"
    }
}
