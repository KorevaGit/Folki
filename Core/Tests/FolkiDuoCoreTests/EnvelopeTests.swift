import Foundation
import Testing
import FolkiDuoCore

struct EnvelopeTests {
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Europe/Moscow")!; return calendar
    }
    private func rub(_ value: Int64) -> Money { Money(minorUnits: value * 100) }
    private func envelope(_ name: String, size: Int64, day: Int, due: String, mandatory: Bool = true) throws -> RecurringEnvelope {
        try RecurringEnvelope(name: name, size: rub(size), dueDay: day, nextDue: date(due), isMandatory: mandatory)
    }

    @Test func dueDatesClampToShortMonthsAndMoveMonthly() throws {
        #expect(try EnvelopeSchedule.dueDate(day: 31, inMonthOf: date("2026-02-10T12:00:00Z"), calendar: calendar)
                == date("2026-02-27T21:00:00Z"))
        #expect(try EnvelopeSchedule.firstDue(day: 25, onOrAfter: date("2026-10-20T12:00:00Z"), calendar: calendar)
                == date("2026-10-24T21:00:00Z"))
        #expect(try EnvelopeSchedule.firstDue(day: 5, onOrAfter: date("2026-10-20T12:00:00Z"), calendar: calendar)
                == date("2026-11-04T21:00:00Z"))
        // January 31st → February 28th → March 31st: the chosen day survives a short month.
        let february = try EnvelopeSchedule.nextDue(after: date("2026-01-30T21:00:00Z"), day: 31, calendar: calendar)
        #expect(february == date("2026-02-27T21:00:00Z"))
        #expect(try EnvelopeSchedule.nextDue(after: february, day: 31, calendar: calendar) == date("2026-03-30T21:00:00Z"))
        #expect(throws: BudgetError.invalidPeriod) { try EnvelopeSchedule.dueDate(day: 0, inMonthOf: .now, calendar: calendar) }
    }

    @Test func urgencyFollowsDaysLeftOnlyWhileShort() throws {
        let rent = try envelope("Аренда", size: 25_000, day: 25, due: "2026-10-24T21:00:00Z")
        func urgency(_ now: String, balance: Int64) throws -> EnvelopeUrgency {
            try EnvelopeSchedule.urgency(of: rent, balance: rub(balance), now: date(now), calendar: calendar)
        }
        #expect(try urgency("2026-10-01T09:00:00Z", balance: 2_000) == .calm)
        #expect(try urgency("2026-10-17T09:00:00Z", balance: 2_000) == .calm)
        #expect(try urgency("2026-10-18T09:00:00Z", balance: 10_000) == .attention)
        #expect(try urgency("2026-10-22T09:00:00Z", balance: 10_000) == .attention)
        #expect(try urgency("2026-10-23T09:00:00Z", balance: 10_000) == .serious)
        #expect(try urgency("2026-10-27T09:00:00Z", balance: 10_000) == .serious)
        #expect(try urgency("2026-10-24T09:00:00Z", balance: 25_000) == .funded)
    }

    @Test func existingMoneyFundsOnlyUrgentMandatoryEnvelopesAndKeepsTheDaysBeforeThem() throws {
        // The audit case: 60 500 for 30 days, three envelopes due in four days, one of them a savings cushion.
        let now = date("2026-10-21T12:00:00Z"), end = date("2026-11-19T21:00:00Z")
        let housing = try envelope("Жильё", size: 20_000, day: 25, due: "2026-10-24T21:00:00Z")
        let phone = try envelope("Связь", size: 2_700, day: 25, due: "2026-10-24T21:00:00Z")
        let cushion = try envelope("Подушка", size: 18_000, day: 25, due: "2026-10-24T21:00:00Z", mandatory: false)
        let later = try envelope("Кредит", size: 9_000, day: 5, due: "2026-11-04T21:00:00Z")
        let split = try EnvelopeDistributor.distributeExisting(free: rub(60_500), envelopes: [housing, phone, cushion, later],
            balances: [:], periodEnd: end, dailyGuide: rub(2_033), now: now, calendar: calendar)
        #expect(split.fills[housing.id] == rub(20_000))
        #expect(split.fills[phone.id] == rub(2_700))
        // Optional envelopes and payments more than a week away wait for the user or the next income.
        #expect(split.fills[cushion.id] == nil)
        #expect(split.fills[later.id] == nil)
        #expect(split.living == rub(37_800))
    }

    @Test func existingMoneyNeverTakesTheDaysBeforeAnUrgentPayment() throws {
        let now = date("2026-10-21T12:00:00Z"), end = date("2026-11-19T21:00:00Z")
        let rent = try envelope("Аренда", size: 25_000, day: 24, due: "2026-10-23T21:00:00Z")
        // Three days until rent at 2 000 a day stay for living; only the rest goes to the envelope.
        let short = try EnvelopeDistributor.distributeExisting(free: rub(10_000), envelopes: [rent], balances: [:],
            periodEnd: end, dailyGuide: rub(2_000), now: now, calendar: calendar)
        #expect(short.fills[rent.id] == rub(4_000))
        #expect(short.living == rub(6_000))
        // What is already set aside counts; an overdue payment keeps one day.
        let overdue = try envelope("Аренда", size: 25_000, day: 20, due: "2026-10-19T21:00:00Z")
        let late = try EnvelopeDistributor.distributeExisting(free: rub(30_000), envelopes: [overdue],
            balances: [overdue.id: rub(20_000)], periodEnd: end, dailyGuide: rub(2_000), now: now, calendar: calendar)
        #expect(late.fills[overdue.id] == rub(5_000))
        // Nothing urgent: nothing moves.
        let calm = try EnvelopeDistributor.distributeExisting(free: rub(30_000), envelopes: [rent], balances: [rent.id: rub(25_000)],
            periodEnd: end, dailyGuide: rub(2_000), now: now, calendar: calendar)
        #expect(calm.fills.isEmpty)
    }

    @Test func incomeFillsDueEnvelopesNearestFirst() throws {
        let rent = try envelope("Аренда", size: 25_000, day: 25, due: "2026-10-24T21:00:00Z")
        let internet = try envelope("Интернет", size: 800, day: 15, due: "2026-11-14T21:00:00Z")
        let later = try envelope("Страховка", size: 9_000, day: 1, due: "2026-12-01T21:00:00Z")
        let periodEnd = date("2026-11-19T21:00:00Z")
        let split = try EnvelopeDistributor.distribute(incoming: rub(100_000), envelopes: [later, internet, rent],
            balances: [rent.id: rub(5_000)], periodEnd: periodEnd)
        #expect(split.fills == [rent.id: rub(20_000), internet.id: rub(800)])
        #expect(split.living == rub(79_200))

        let short = try EnvelopeDistributor.distribute(incoming: rub(10_000), envelopes: [internet, rent],
            balances: [:], periodEnd: periodEnd)
        // Not enough for both: rent on the 25th comes before internet on the 15th of next month.
        #expect(short.fills == [rent.id: rub(10_000)])
        #expect(short.living == rub(0))
    }

    @Test func mandatoryPaymentsComeBeforeOptionalOnesAndJarsComeLast() throws {
        let end = date("2026-11-19T21:00:00Z")
        let gym = try envelope("Спортзал", size: 3_000, day: 23, due: "2026-10-22T21:00:00Z", mandatory: false)
        let rent = try envelope("Аренда", size: 20_000, day: 5, due: "2026-11-04T21:00:00Z")
        let trip = try RecurringEnvelope(name: "Отпуск", size: rub(5_000), dueDay: 10, nextDue: date("2026-11-09T21:00:00Z"),
                                         isMandatory: false, kind: .savings, target: rub(60_000))
        let tight = try EnvelopeDistributor.distribute(incoming: rub(22_000), envelopes: [trip, gym, rent], balances: [:], periodEnd: end)
        #expect(tight.fills == [rent.id: rub(20_000), gym.id: rub(2_000)])
        let plenty = try EnvelopeDistributor.distribute(incoming: rub(40_000), envelopes: [trip, gym, rent], balances: [:], periodEnd: end)
        #expect(plenty.fills == [rent.id: rub(20_000), gym.id: rub(3_000), trip.id: rub(5_000)])
    }

    @Test func aJarGrowsOneContributionAtATimeUpToItsGoal() throws {
        let end = date("2026-11-19T21:00:00Z")
        let cushion = try RecurringEnvelope(name: "Подушка", size: rub(10_000), dueDay: 1, nextDue: date("2026-10-31T21:00:00Z"),
                                            isMandatory: false, kind: .savings, target: rub(25_000))
        // Unlike a bill, a jar keeps collecting after one contribution.
        #expect(try cushion.shortfall(balance: rub(10_000)) == rub(10_000))
        #expect(try cushion.shortfall(balance: rub(20_000)) == rub(5_000))
        #expect(try cushion.shortfall(balance: rub(25_000)) == rub(0))
        let split = try EnvelopeDistributor.distribute(incoming: rub(50_000), envelopes: [cushion],
            balances: [cushion.id: rub(20_000)], periodEnd: end)
        #expect(split.fills[cushion.id] == rub(5_000))
        // No date to miss: calm until full, never red.
        let now = date("2026-11-05T09:00:00Z")
        #expect(try EnvelopeSchedule.urgency(of: cushion, balance: rub(0), now: now, calendar: calendar) == .calm)
        #expect(try EnvelopeSchedule.urgency(of: cushion, balance: rub(25_000), now: now, calendar: calendar) == .funded)
        #expect(throws: BudgetError.invalidAmount) {
            try RecurringEnvelope(name: "Без цели", size: rub(1_000), dueDay: 1, nextDue: now, isMandatory: false, kind: .savings)
        }
    }

    @Test func aLatePaymentMovesToItsComingDate() throws {
        let missed = date("2026-08-24T21:00:00Z")
        #expect(try EnvelopeSchedule.nextDue(after: missed, day: 25, notBefore: date("2026-10-21T09:00:00Z"), calendar: calendar)
                == date("2026-10-24T21:00:00Z"))
        #expect(try EnvelopeSchedule.nextDue(after: missed, day: 25, notBefore: date("2026-10-26T09:00:00Z"), calendar: calendar)
                == date("2026-11-24T21:00:00Z"))
    }

    @Test func shortIncomeKeepsDailyLivingAndDoesNotDependOnCreationOrder() throws {
        let rent = try envelope("Аренда", size: 24_000, day: 25, due: "2026-10-24T21:00:00Z")
        let internet = try envelope("Интернет", size: 6_000, day: 25, due: "2026-10-24T21:00:00Z")
        let end = date("2026-11-19T21:00:00Z")
        let split = try EnvelopeDistributor.distribute(incoming: rub(10_000), envelopes: [rent, internet],
            balances: [:], periodEnd: end, minimumLiving: rub(1_000))
        #expect(split.fills == [rent.id: rub(7_200), internet.id: rub(1_800)])
        #expect(split.living == rub(1_000))
        #expect(try EnvelopeDistributor.distribute(incoming: rub(10_000), envelopes: [internet, rent],
            balances: [:], periodEnd: end, minimumLiving: rub(1_000)) == split)
        #expect(try EnvelopeDistributor.distribute(incoming: rub(500), envelopes: [rent, internet],
            balances: [:], periodEnd: end, minimumLiving: rub(1_000)).living == rub(500))
    }

    @Test func proportionalSplitPreservesKopecksAndHandlesLargeAmounts() throws {
        let first = try envelope("Первый", size: 1, day: 25, due: "2026-10-24T21:00:00Z")
        let second = try envelope("Второй", size: 1, day: 25, due: "2026-10-24T21:00:00Z")
        let end = date("2026-11-19T21:00:00Z")
        let small = try EnvelopeDistributor.distribute(incoming: Money(minorUnits: 3), envelopes: [first, second],
            balances: [:], periodEnd: end, minimumLiving: Money(minorUnits: 1))
        #expect(small.fills.values.reduce(0) { $0 + $1.minorUnits } == 2)
        #expect(small.fills[first.id]?.minorUnits == 1)
        #expect(small.living.minorUnits == 1)
        let odd = try EnvelopeDistributor.distribute(incoming: Money(minorUnits: 4), envelopes: [second, first],
            balances: [:], periodEnd: end, minimumLiving: Money(minorUnits: 1))
        #expect(odd.fills.values.map(\.minorUnits).sorted() == [1, 2])
        #expect(odd.living.minorUnits == 1)
        #expect(try EnvelopeDistributor.distribute(incoming: Money(minorUnits: 4), envelopes: [first, second],
            balances: [:], periodEnd: end, minimumLiving: Money(minorUnits: 1)) == odd)
        let large = try RecurringEnvelope(name: "Большой", size: Money(minorUnits: Int64.max), dueDay: 25,
            nextDue: first.nextDue, isMandatory: true)
        let split = try EnvelopeDistributor.distribute(incoming: Money(minorUnits: Int64.max), envelopes: [large],
            balances: [:], periodEnd: end, minimumLiving: Money(minorUnits: 1))
        #expect(split.fills[large.id]?.minorUnits == Int64.max - 1)
        #expect(split.living.minorUnits == 1)
    }

    @Test func slidersMoveMoneyOnlyBetweenTheEnvelopeAndLiving() throws {
        let rent = try envelope("Аренда", size: 25_000, day: 25, due: "2026-10-24T21:00:00Z")
        let internet = try envelope("Интернет", size: 800, day: 15, due: "2026-11-14T21:00:00Z")
        let split = try EnvelopeDistributor.distribute(incoming: rub(30_000), envelopes: [rent, internet],
            balances: [:], periodEnd: date("2026-11-19T21:00:00Z"))
        let less = try EnvelopeDistributor.adjusting(split, envelope: rent, balance: rub(0), to: rub(2_000))
        #expect(less.fills == [rent.id: rub(2_000), internet.id: rub(800)])
        #expect(less.living == rub(27_200))
        // Never past the envelope's size, never below zero.
        #expect(try EnvelopeDistributor.adjusting(less, envelope: rent, balance: rub(0), to: rub(90_000)).fills[rent.id] == rub(25_000))
        #expect(try EnvelopeDistributor.adjusting(less, envelope: rent, balance: rub(0), to: rub(-5)).fills[rent.id] == nil)
        // Never more than the income left by the other envelopes.
        let tight = try EnvelopeDistributor.distribute(incoming: rub(10_000), envelopes: [internet], balances: [:],
            periodEnd: date("2026-11-19T21:00:00Z"))
        #expect(try EnvelopeDistributor.adjusting(tight, envelope: rent, balance: rub(0), to: rub(25_000)).fills[rent.id] == rub(9_200))
    }

    @Test func contributionSuggestionAddsUrgentFamilyShortfalls() throws {
        #expect(try ContributionAdvisor.suggestion(topUp: rub(100_000), percent: 30, urgentFamilyShortfalls: []) == rub(30_000))
        #expect(try ContributionAdvisor.suggestion(topUp: Money(minorUnits: 3_333_33), percent: 30, urgentFamilyShortfalls: [])
                == rub(999))
        #expect(try ContributionAdvisor.suggestion(topUp: rub(100_000), percent: 30, urgentFamilyShortfalls: [rub(15_000)]) == rub(45_000))
        #expect(try ContributionAdvisor.suggestion(topUp: rub(10_000), percent: 30, urgentFamilyShortfalls: [rub(15_000)]) == rub(10_000))
        #expect(throws: BudgetError.invalidAmount) { try ContributionAdvisor.suggestion(topUp: rub(1), percent: 120, urgentFamilyShortfalls: []) }
        // Personal bills first: 30% of what 100 000 leaves after 40 000 of mandatory payments.
        #expect(try ContributionAdvisor.suggestion(topUp: rub(100_000), percent: 30, urgentFamilyShortfalls: [],
                                                   personalObligations: rub(40_000)) == rub(18_000))
        #expect(try ContributionAdvisor.suggestion(topUp: rub(30_000), percent: 30, urgentFamilyShortfalls: [rub(15_000)],
                                                   personalObligations: rub(40_000)) == rub(0))
    }
}
