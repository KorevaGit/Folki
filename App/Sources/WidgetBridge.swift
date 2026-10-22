import Foundation
import SwiftUI
import UIKit
import WidgetKit
import AppIntents
import FolkiDuoCore

/// Publishes today's figures for the widgets and reloads them only when something changed.
@MainActor enum WidgetBridge {
    static func publish(personal: BudgetSession, family: BudgetSession) {
        func budget(_ session: BudgetSession, requiresFunding: Bool = true) -> FolkiWidgetSnapshot.Budget? {
            guard let result = session.result, !requiresFunding || session.hasFunding,
                  let end = session.household?.period.endExclusive else { return nil }
            return .init(today: result.todayRemaining.minorUnits, guide: result.todayGuide.minorUnits,
                         tomorrow: result.futureAllocation?.firstDayAmount.minorUnits, periodEnd: end)
        }
        // The short envelope due soonest across both budgets, the way the main screen's banner picks it.
        let short = [personal, family].flatMap { session in
            session.payments.compactMap { envelope -> (BudgetSession, RecurringEnvelope)? in
                session.envelopeUrgency(envelope) == .funded ? nil : (session, envelope)
            }
        }.min { $0.1.nextDue < $1.1.nextDue }
        let envelope = short.map { session, envelope -> FolkiWidgetSnapshot.Envelope in
            let category = session.catalog.category(for: envelope.categoryID ?? BuiltInCategory.other.id)
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            UIColor((envelope.color ?? category.color).color).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
            return .init(id: envelope.id, name: envelope.name, symbol: envelope.symbol ?? category.symbol,
                         red: red, green: green, blue: blue, size: envelope.size.minorUnits,
                         saved: session.envelopeBalance(envelope).minorUnits, due: envelope.nextDue)
        }
        let calendar = personal.calendar
        let today = calendar.startOfDay(for: personal.referenceDate)
        func history(_ session: BudgetSession) -> [FolkiWidgetSnapshot.Day] {
            (-7...0).compactMap { offset in
                guard let date = calendar.date(byAdding: .day, value: offset, to: today),
                      let result = session.overview(on: date).result else { return nil }
                return .init(date: date, remaining: result.todayRemaining.minorUnits, guide: result.todayGuide.minorUnits)
            }
        }
        let days = history(personal)
        let familyDays = family.household == nil ? [] : history(family)
        let previous = FolkiWidgetSnapshot.load()
        var next = FolkiWidgetSnapshot(familyDays: familyDays, days: days, day: personal.calendar.startOfDay(for: personal.referenceDate),
                                       personal: budget(personal), family: family.household == nil ? nil : budget(family, requiresFunding: false),
                                       envelope: envelope,
                                       updated: previous?.updated ?? .now)
        if var old = previous {
            old.updated = next.updated
            guard old != next else { return }
        }
        next.updated = .now
        next.save()
        WidgetCenter.shared.reloadAllTimelines()
    }
}

/// "Записать трату в Folki" for Siri, Spotlight and the Shortcuts app.
struct FolkiShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: SpendIntent(), phrases: ["Записать трату в \(.applicationName)", "Потратить в \(.applicationName)"],
                    shortTitle: "Записать трату", systemImageName: "minus.circle.fill")
    }
}
