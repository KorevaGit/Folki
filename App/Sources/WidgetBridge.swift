import Foundation
import WidgetKit
import AppIntents
import FolkiDuoCore

/// Publishes today's figures for the widgets and reloads them only when something changed.
@MainActor enum WidgetBridge {
    static func publish(personal: BudgetSession, family: BudgetSession) {
        func budget(_ session: BudgetSession) -> FolkiWidgetSnapshot.Budget? {
            guard let result = session.result, session.hasFunding, let end = session.household?.period.endExclusive else { return nil }
            return .init(today: result.todayRemaining.minorUnits, guide: result.todayGuide.minorUnits,
                         tomorrow: result.futureAllocation?.firstDayAmount.minorUnits, periodEnd: end)
        }
        let previous = FolkiWidgetSnapshot.load()
        var next = FolkiWidgetSnapshot(day: personal.calendar.startOfDay(for: personal.referenceDate),
                                       personal: budget(personal), family: family.household == nil ? nil : budget(family),
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
