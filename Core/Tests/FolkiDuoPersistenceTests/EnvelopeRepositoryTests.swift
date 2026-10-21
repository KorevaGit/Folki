import Foundation
import CoreData
import Testing
import FolkiDuoCore
@testable import FolkiDuoPersistence

@MainActor struct EnvelopeRepositoryTests {
    private let now = ISO8601DateFormatter().date(from: "2026-10-20T12:00:00Z")!
    private let rentDue = ISO8601DateFormatter().date(from: "2026-10-24T21:00:00Z")!
    private func rub(_ value: Int64) -> Money { Money(minorUnits: value * 100) }

    private func open() async throws -> (BudgetRepository, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let repo = try await BudgetRepository.open(directory: directory, localMemberID: UUID())
        try repo.createPlan(monthlyPlan: rub(60_000), available: rub(60_000), asOf: now, timeZone: "Europe/Moscow",
            scope: .personal, payday: now.addingTimeInterval(30 * 86400))
        return (repo, directory)
    }
    private func budget(_ repo: BudgetRepository) throws -> StoredBudget { try #require(try repo.load(asOf: now, scope: .personal)) }
    private func result(_ repo: BudgetRepository) throws -> DailyBudgetSnapshot {
        try DailyBudgetCalculator.calculate(budget(repo).snapshot, asOf: now)
    }

    @Test func redistributeAfterResetPreservesActualMoneyAndDoesNotAddIncome() async throws {
        let (repo, directory) = try await open(); defer { try? FileManager.default.removeItem(at: directory) }
        let old = try repo.createEnvelope(name: "Старый план", size: rub(25_000), dueDay: 25, nextDue: rentDue,
            isMandatory: true, in: budget(repo), asOf: now, initialFunding: rub(15_000))
        try repo.archiveEnvelope(old.id, in: budget(repo), asOf: now)
        #expect(try result(repo).monthlyRemaining == rub(60_000))
        let rent = try repo.createEnvelope(name: "Аренда", size: rub(25_000), dueDay: 25, nextDue: rentDue,
            isMandatory: true, in: budget(repo), asOf: now)
        let food = try repo.createEnvelope(name: "Запас", size: rub(10_000), dueDay: 25, nextDue: rentDue,
            isMandatory: false, in: budget(repo), asOf: now)
        let operation = UUID()
        let fills = [rent.id: rub(20_000), food.id: rub(5_000)]
        try repo.distributeAvailable(fills, in: budget(repo), asOf: now, operationID: operation)
        let after = try result(repo)
        #expect(after.totalFunds == rub(60_000))
        #expect(after.monthlyRemaining == rub(35_000))
        #expect(after.reserveBalances[rent.id] == rub(20_000))
        #expect(after.reserveBalances[food.id] == rub(5_000))
        #expect(try repo.history(scope: .personal).allSatisfy { $0.transaction.kind != .income })
        try repo.distributeAvailable(fills, in: budget(repo), asOf: now, operationID: operation)
        #expect(try result(repo) == after)
        try repo.close()
    }

    @Test func availableDistributionRollsBackEveryEnvelopeWhenFundsAreInsufficient() async throws {
        let (repo, directory) = try await open(); defer { try? FileManager.default.removeItem(at: directory) }
        let a = try repo.createEnvelope(name: "Первый", size: rub(40_000), dueDay: 25, nextDue: rentDue,
            isMandatory: true, in: budget(repo), asOf: now)
        let b = try repo.createEnvelope(name: "Второй", size: rub(40_000), dueDay: 25, nextDue: rentDue,
            isMandatory: true, in: budget(repo), asOf: now)
        let before = try result(repo)
        #expect(throws: BudgetError.insufficientReserve) {
            try repo.distributeAvailable([a.id: rub(40_000), b.id: rub(40_000)], in: budget(repo), asOf: now, operationID: UUID())
        }
        #expect(try result(repo) == before)
        #expect(try repo.history(scope: .personal).isEmpty)
        try repo.close()
    }

    @Test func depositMatchesPreviewAndRetryDoesNotDuplicateAnySide() async throws {
        let (repo, directory) = try await open(); defer { try? FileManager.default.removeItem(at: directory) }
        try repo.createPlan(monthlyPlan: rub(0), available: rub(0), asOf: now, timeZone: "Europe/Moscow", scope: .family)
        let rent = try repo.createEnvelope(name: "Аренда", size: rub(25_000), dueDay: 25, nextDue: rentDue,
            isMandatory: true, in: budget(repo), asOf: now)
        let before = try budget(repo)
        let family = try #require(try repo.load(asOf: now, scope: .family))
        let operation = UUID()
        let preview = try FundingPlan.applying(to: before.snapshot, incoming: rub(10_000), fills: [rent.id: rub(4_000)],
            familyShare: rub(3_000), now: now, author: repo.authorID(in: before), operationID: operation)
        try repo.deposit(rub(10_000), fills: [rent.id: rub(4_000)], familyShare: rub(3_000), in: before,
            family: family, asOf: now, operationID: operation)
        let after = try result(repo)
        #expect(after == (try DailyBudgetCalculator.calculate(preview, asOf: now)))
        #expect(after.monthlyRemaining == rub(63_000))
        #expect(after.reserveBalances[rent.id] == rub(4_000))
        #expect(try DailyBudgetCalculator.calculate(try #require(try repo.load(asOf: now, scope: .family)).snapshot, asOf: now).monthlyRemaining == rub(3_000))
        try repo.deposit(rub(10_000), fills: [rent.id: rub(4_000)], familyShare: rub(3_000), in: budget(repo),
            family: family, asOf: now, operationID: operation)
        #expect(try result(repo) == after)
        #expect(try repo.history(scope: .personal).count == 3)
        #expect(try repo.history(scope: .family).count == 1)
        try repo.close()
    }

    @Test func failedFamilySideRollsBackIncomeAndEnvelopeFillTogether() async throws {
        let (repo, directory) = try await open(); defer { try? FileManager.default.removeItem(at: directory) }
        let rent = try repo.createEnvelope(name: "Аренда", size: rub(25_000), dueDay: 25, nextDue: rentDue,
            isMandatory: true, in: budget(repo), asOf: now)
        let before = try result(repo)
        #expect(throws: LedgerError.accessDenied) {
            try repo.deposit(rub(10_000), fills: [rent.id: rub(4_000)], familyShare: rub(3_000), in: budget(repo),
                asOf: now, operationID: UUID())
        }
        #expect(try result(repo) == before)
        #expect(try repo.history(scope: .personal).isEmpty)
        #expect(throws: BudgetError.insufficientReserve) {
            try repo.deposit(rub(1_000), fills: [rent.id: rub(2_000)], familyShare: rub(0), in: budget(repo), asOf: now, operationID: UUID())
        }
        #expect(try result(repo) == before)
        try repo.close()
    }

    @Test func initialFundingIsExplicitAndCreationRollsBackIfItCannotBeFunded() async throws {
        let (repo, directory) = try await open(); defer { try? FileManager.default.removeItem(at: directory) }
        #expect(throws: BudgetError.insufficientReserve) {
            try repo.createEnvelope(name: "Слишком много", size: rub(100_000), dueDay: 25, nextDue: rentDue,
                isMandatory: true, in: budget(repo), asOf: now, initialFunding: rub(70_000))
        }
        #expect(try repo.envelopes(scope: .personal).isEmpty)
        #expect(try result(repo).monthlyRemaining == rub(60_000))
        let rent = try repo.createEnvelope(name: "Аренда", size: rub(25_000), dueDay: 25, nextDue: rentDue,
            isMandatory: true, in: budget(repo), asOf: now, initialFunding: rub(6_000))
        #expect(try result(repo).monthlyRemaining == rub(54_000))
        #expect(try result(repo).reserveBalances[rent.id] == rub(6_000))
        try repo.close()
    }

    @Test func envelopeHoldsMoneyOutsideLivingAndSurvivesReopening() async throws {
        let (repo, directory) = try await open(); defer { try? FileManager.default.removeItem(at: directory) }
        let rent = try repo.createEnvelope(name: " Аренда ", size: rub(25_000), dueDay: 25, nextDue: rentDue, isMandatory: true,
                                           in: budget(repo), asOf: now)
        #expect(try repo.envelopes(scope: .personal).map(\.name) == ["Аренда"])
        #expect(try result(repo).reserveBalances[rent.id] == rub(0))

        try repo.fundEnvelope(rent.id, amount: rub(10_000), in: budget(repo), asOf: now)
        #expect(try result(repo).reserveBalances[rent.id] == rub(10_000))
        #expect(try result(repo).monthlyRemaining == rub(50_000))
        // Not more than the living money left.
        #expect(throws: BudgetError.insufficientReserve) {
            try repo.fundEnvelope(rent.id, amount: rub(50_001), in: budget(repo), asOf: now)
        }
        try repo.close()
        let reopened = try await BudgetRepository.open(directory: directory, localMemberID: UUID())
        #expect(try reopened.envelopes(scope: .personal).first?.size == rub(25_000))
        #expect(try DailyBudgetCalculator.calculate(try #require(try reopened.load(asOf: now, scope: .personal)).snapshot, asOf: now)
                .reserveBalances[rent.id] == rub(10_000))
        try reopened.close()
    }

    @Test func fundingTwiceWithOneOperationIsCountedOnce() async throws {
        let (repo, directory) = try await open(); defer { try? FileManager.default.removeItem(at: directory) }
        let rent = try repo.createEnvelope(name: "Аренда", size: rub(25_000), dueDay: 25, nextDue: rentDue, isMandatory: true,
                                           in: budget(repo), asOf: now)
        let operation = UUID()
        try repo.fundEnvelope(rent.id, amount: rub(5_000), in: budget(repo), asOf: now, operationID: operation)
        try repo.fundEnvelope(rent.id, amount: rub(5_000), in: budget(repo), asOf: now, operationID: operation)
        #expect(try result(repo).reserveBalances[rent.id] == rub(5_000))
        try repo.close()
    }

    @Test func everydayCategoryDoesNotConsumeEnvelopeAndExplicitSpendUsesTheChosenEnvelope() async throws {
        let (repo, directory) = try await open(); defer { try? FileManager.default.removeItem(at: directory) }
        let a = try repo.createEnvelope(name: "Первый", size: rub(5_000), dueDay: 25, nextDue: rentDue,
            isMandatory: true, categoryID: BuiltInCategory.groceries.id, in: budget(repo), asOf: now, initialFunding: rub(2_000))
        let b = try repo.createEnvelope(name: "Второй", size: rub(5_000), dueDay: 25, nextDue: rentDue,
            isMandatory: true, categoryID: BuiltInCategory.groceries.id, in: budget(repo), asOf: now, initialFunding: rub(1_000))
        let author = try repo.authorID(in: budget(repo))
        let everyday = LedgerRecord(transaction: TransactionSnapshot(amount: rub(300), kind: .expense,
            funding: .flexible, date: now, authorID: author, payerID: author), title: "", categoryID: BuiltInCategory.groceries.id)
        try repo.save(everyday, in: budget(repo), expectedRevision: nil, asOf: now)
        #expect(try result(repo).reserveBalances[a.id] == rub(2_000))
        #expect(try result(repo).reserveBalances[b.id] == rub(1_000))
        let operation = UUID()
        try repo.spendFromEnvelope(b.id, amount: rub(1_200), in: budget(repo), asOf: now, operationID: operation)
        #expect(try result(repo).reserveBalances[a.id] == rub(2_000))
        #expect(try result(repo).reserveBalances[b.id] == rub(0))
        let stats = try BudgetAnalytics.calculate(records: repo.history(scope: .personal), period: .day,
            anchor: now, asOf: now, calendar: budget(repo).snapshot.period.calendar)
        #expect(stats.envelopeNetSpending == rub(1_000))
        #expect(stats.flexibleNetSpending == rub(500))
        #expect(try stats.netSpending == rub(1_500))
        try repo.spendFromEnvelope(b.id, amount: rub(1_200), in: budget(repo), asOf: now, operationID: operation)
        #expect(try result(repo).totalFunds == rub(58_500))
        try repo.close()
    }

    @Test func biggerBillTakesTheDifferenceFromLivingAndMovesToNextMonth() async throws {
        let (repo, directory) = try await open(); defer { try? FileManager.default.removeItem(at: directory) }
        let internet = try repo.createEnvelope(name: "Интернет", size: rub(800), dueDay: 25, nextDue: rentDue, isMandatory: true,
                                               in: budget(repo), asOf: now)
        try repo.fundEnvelope(internet.id, amount: rub(800), in: budget(repo), asOf: now)
        try repo.payEnvelope(internet.id, amount: rub(870), in: budget(repo), asOf: now)
        #expect(try result(repo).reserveBalances[internet.id] == rub(0))
        #expect(try result(repo).monthlyRemaining == rub(59_130))
        #expect(try repo.envelopes(scope: .personal).first?.nextDue == ISO8601DateFormatter().date(from: "2026-11-24T21:00:00Z"))
        try repo.close()
    }

    @Test func smallerBillReturnsTheRemainderAndEmptyEnvelopeStillPays() async throws {
        let (repo, directory) = try await open(); defer { try? FileManager.default.removeItem(at: directory) }
        let utilities = try repo.createEnvelope(name: "Коммуналка", size: rub(5_000), dueDay: 25, nextDue: rentDue, isMandatory: true,
                                                in: budget(repo), asOf: now)
        try repo.fundEnvelope(utilities.id, amount: rub(5_000), in: budget(repo), asOf: now)
        try repo.payEnvelope(utilities.id, amount: rub(4_200), in: budget(repo), asOf: now)
        #expect(try result(repo).reserveBalances[utilities.id] == rub(0))
        #expect(try result(repo).monthlyRemaining == rub(55_800))

        // Next month's bill is paid before anything was put aside: all of it comes from living money.
        try repo.payEnvelope(utilities.id, amount: rub(5_000), in: budget(repo), asOf: now)
        #expect(try result(repo).monthlyRemaining == rub(50_800))
        try repo.close()
    }

    @Test func archivingReturnsTheBalanceAndHidesTheEnvelope() async throws {
        let (repo, directory) = try await open(); defer { try? FileManager.default.removeItem(at: directory) }
        let gym = try repo.createEnvelope(name: "Спортзал", size: rub(3_000), dueDay: 1, nextDue: rentDue, isMandatory: false,
                                          in: budget(repo), asOf: now)
        try repo.fundEnvelope(gym.id, amount: rub(1_000), in: budget(repo), asOf: now)
        try repo.archiveEnvelope(gym.id, in: budget(repo), asOf: now)
        #expect(try repo.envelopes(scope: .personal).isEmpty)
        #expect(try result(repo).monthlyRemaining == rub(60_000))
        try repo.close()
    }

    @Test func iconAndColourSurviveEditsAndReopening() async throws {
        let (repo, directory) = try await open(); defer { try? FileManager.default.removeItem(at: directory) }
        let gym = try repo.createEnvelope(name: "Спортзал", size: rub(3_000), dueDay: 1, nextDue: rentDue, isMandatory: false,
                                          symbol: "dumbbell.fill", color: .purple, in: budget(repo), asOf: now)
        try repo.updateEnvelope(gym.with(size: rub(3_500), color: .pink), in: budget(repo), asOf: now)
        try repo.close()
        let reopened = try await BudgetRepository.open(directory: directory, localMemberID: UUID())
        let stored = try #require(try reopened.envelopes(scope: .personal).first)
        #expect(stored.symbol == "dumbbell.fill" && stored.color == .pink && stored.size == rub(3_500))
        try reopened.close()
    }

    @Test func invalidEnvelopesAreRejected() async throws {
        let (repo, directory) = try await open(); defer { try? FileManager.default.removeItem(at: directory) }
        #expect(throws: BudgetError.invalidPlan) {
            try repo.createEnvelope(name: "  ", size: rub(100), dueDay: 1, nextDue: rentDue, isMandatory: true, in: budget(repo), asOf: now)
        }
        #expect(throws: BudgetError.invalidAmount) {
            try repo.createEnvelope(name: "Ноль", size: rub(0), dueDay: 1, nextDue: rentDue, isMandatory: true, in: budget(repo), asOf: now)
        }
        #expect(throws: BudgetError.invalidPeriod) {
            try repo.createEnvelope(name: "День", size: rub(100), dueDay: 32, nextDue: rentDue, isMandatory: true, in: budget(repo), asOf: now)
        }
        #expect(try repo.envelopes(scope: .personal).isEmpty)
        try repo.close()
    }
}

@MainActor struct ContributionPercentTests {
    private let now = ISO8601DateFormatter().date(from: "2026-10-20T12:00:00Z")!

    @Test func familyDefaultAndPersonalOverride() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repo = try await BudgetRepository.open(directory: directory, localMemberID: UUID())
        try repo.createPlan(monthlyPlan: Money(minorUnits: 0), available: Money(minorUnits: 0), asOf: now, timeZone: "Europe/Moscow", scope: .family)
        var family = try #require(try repo.load(asOf: now, scope: .family))
        #expect(try repo.effectiveContributionPercent(in: family) == 30)
        try repo.setFamilyContributionPercent(25, in: family, asOf: now)
        family = try #require(try repo.load(asOf: now, scope: .family))
        #expect(try repo.contributionPercents(in: family) == (25, nil))
        try repo.setMyContributionPercent(10, in: family, asOf: now)
        #expect(try repo.effectiveContributionPercent(in: family) == 10)
        try repo.setMyContributionPercent(nil, in: family, asOf: now)
        #expect(try repo.effectiveContributionPercent(in: family) == 25)
        #expect(throws: BudgetError.invalidAmount) { try repo.setFamilyContributionPercent(101, in: family, asOf: now) }
        let personal = try { try repo.createPlan(monthlyPlan: Money(minorUnits: 0), available: Money(minorUnits: 0), asOf: now,
            timeZone: "Europe/Moscow", scope: .personal); return try #require(try repo.load(asOf: now, scope: .personal)) }()
        #expect(throws: LedgerError.accessDenied) { try repo.contributionPercents(in: personal) }
        try repo.close()
    }
}
