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

    @Test func incomeFillsNearestEnvelopesDueThisPeriodFirst() throws {
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
        #expect(short.fills == [rent.id: rub(10_000)])
        #expect(short.living == rub(0))
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
    }
}
