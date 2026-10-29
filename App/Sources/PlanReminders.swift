import Foundation
import UserNotifications
import FolkiDuoCore

/// The reminder part of the financial plan. Stored on this device: reminders are personal.
struct PlanSettings: Codable, Equatable {
    enum Income: Codable, Equatable {
        case off
        /// Days of the month, 1…31: salary and advance, for example. 29–31 fall on the last day of a short month.
        case monthly([Int])
        /// Calendar weekday, 1 = Sunday.
        case weekly(Int)
    }
    var income: Income = .off
    var hour = 10
    var minute = 0
    var paymentReminders = true
    /// Days before a payment; 0 means only on the day.
    var daysBefore = 2
    var onDueDay = true

    private static let key = "FolkiPlanSettings"
    static func load() -> PlanSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let settings = try? JSONDecoder().decode(PlanSettings.self, from: data) else { return PlanSettings() }
        return settings
    }
    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.key) }
    }

    var usesNotifications: Bool { income != .off || paymentReminders }
}

/// Local notifications for the plan: when to add money and which payments are coming.
/// Everything is rebuilt from the current envelopes, so a reschedule is always safe.
@MainActor enum PlanReminders {
    private static let prefix = "folki.plan."

    static func requestPermission() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    static func reschedule(_ settings: PlanSettings, sessions: [BudgetSession]) async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(prefix) }
        center.removePendingNotificationRequests(withIdentifiers: pending)
        guard await center.notificationSettings().authorizationStatus == .authorized else { return }

        switch settings.income {
        case .off: break
        case .monthly(let days):
            for day in days where day <= 28 {
                var when = DateComponents(); when.day = day; when.hour = settings.hour; when.minute = settings.minute
                await add(id: "income.\(day)", title: String(localized: "Пришли деньги?"),
                          body: String(localized: "Внеси их в Folki — я разложу по конвертам и посчитаю день"),
                          trigger: UNCalendarNotificationTrigger(dateMatching: when, repeats: true))
            }
            // 29–31 do not exist in every month: in a short month the reminder comes on its last day.
            let calendar = Calendar.current
            for day in days where day > 28 {
                for offset in 0..<12 {
                    guard let month = calendar.date(byAdding: .month, value: offset, to: .now),
                          let length = calendar.range(of: .day, in: .month, for: month)?.count else { continue }
                    var when = calendar.dateComponents([.year, .month], from: month)
                    when.day = min(day, length); when.hour = settings.hour; when.minute = settings.minute
                    guard let date = calendar.date(from: when), date > .now else { continue }
                    await add(id: "income.\(day).\(offset)", title: String(localized: "Пришли деньги?"),
                              body: String(localized: "Внеси их в Folki — я разложу по конвертам и посчитаю день"),
                              trigger: UNCalendarNotificationTrigger(dateMatching: when, repeats: false))
                }
            }
        case .weekly(let weekday):
            var when = DateComponents(); when.weekday = weekday; when.hour = settings.hour; when.minute = settings.minute
            await add(id: "income.week", title: String(localized: "Пришли деньги?"),
                      body: String(localized: "Внеси их в Folki — я разложу по конвертам и посчитаю день"),
                      trigger: UNCalendarNotificationTrigger(dateMatching: when, repeats: true))
        }

        guard settings.paymentReminders else { return }
        for session in sessions {
            let calendar = session.calendar
            for envelope in session.payments {
                let missing = (try? envelope.shortfall(balance: session.envelopeBalance(envelope))) ?? envelope.size
                let amount = MoneyText.whole(envelope.size)
                var offsets: [Int] = []
                if settings.daysBefore > 0 { offsets.append(settings.daysBefore) }
                if settings.onDueDay { offsets.append(0) }
                for offset in offsets {
                    guard let day = calendar.date(byAdding: .day, value: -offset, to: envelope.nextDue),
                          let fire = calendar.date(bySettingHour: settings.hour, minute: settings.minute, second: 0, of: day),
                          fire > .now else { continue }
                    let when = offset == 0 ? String(localized: "сегодня")
                        : String(localized: "через \(offset) дн.")
                    let body = missing.minorUnits > 0
                        ? String(localized: "Не хватает \(MoneyText.whole(missing.roundedUpToWholeUnits)) — переложи из денег на жизнь")
                        : String(localized: "В конверте всё собрано")
                    await add(id: "payment.\(envelope.id.uuidString).\(offset)",
                              title: String(localized: "\(envelope.name) — \(amount) \(when)"), body: body,
                              trigger: UNCalendarNotificationTrigger(
                                dateMatching: calendar.dateComponents([.year, .month, .day, .hour, .minute], from: fire), repeats: false))
                }
            }
        }
    }

    private static func add(id: String, title: String, body: String, trigger: UNNotificationTrigger) async {
        let content = UNMutableNotificationContent()
        content.title = title; content.body = body; content.sound = .default
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: prefix + id, content: content, trigger: trigger))
    }
}
