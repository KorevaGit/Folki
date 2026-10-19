import SwiftUI

/// A Monday-first week; selection is independent of the live ledger's clock.
struct BudgetWeekCalendar: View {
    @Binding var selection: Date?
    let today: Date
    let calendar: Calendar
    @State private var showingMonth = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private var selected: Date { selection ?? today }
    private var weekStart: Date {
        let start = calendar.startOfDay(for: selected)
        let offset = (calendar.component(.weekday, from: start) + 5) % 7
        return calendar.date(byAdding: .day, value: -offset, to: start) ?? start
    }
    private var isCurrentWeek: Bool {
        guard let end = calendar.date(byAdding: .day, value: 7, to: weekStart) else { return true }
        return today < end
    }
    private var dateBinding: Binding<Date> {
        Binding(get: { selected }, set: { select($0) })
    }

    var body: some View {
        VStack(spacing: 6) {
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 4) {
                        monthButton
                        HStack { todayButton; Spacer(); weekButtons }
                    }
                } else {
                    HStack(spacing: 4) {
                        monthButton
                        Spacer(minLength: 4)
                        todayButton
                        weekButtons
                    }
                }
            }.foregroundStyle(.secondary)
            HStack(spacing: 4) {
                ForEach(0..<7, id: \.self) { offset in
                    if let date = calendar.date(byAdding: .day, value: offset, to: weekStart) {
                        day(date)
                    }
                }
            }
            .simultaneousGesture(DragGesture(minimumDistance: 30).onEnded { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                if value.translation.width > 0 { moveWeek(-1) }
                else if !isCurrentWeek { moveWeek(1) }
            })
        }
        .sheet(isPresented: $showingMonth) {
            NavigationStack {
                DatePicker("Дата бюджета", selection: dateBinding, in: ...today, displayedComponents: .date)
                    .datePickerStyle(.graphical).padding()
                    .environment(\.calendar, calendar)
                    .environment(\.timeZone, calendar.timeZone)
                    .navigationTitle("Календарь").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) {
                        Button("Готово") { showingMonth = false }
                    } }
            }.presentationDetents([.medium, .large])
        }
    }

    private var monthButton: some View {
        Button { showingMonth = true } label: {
            HStack(spacing: 6) {
                Text(selected, format: .dateTime.day().month(.wide))
                    .font(.subheadline.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8)
                Image(systemName: "calendar").font(.caption.weight(.semibold))
            }.frame(minHeight: 44)
        }.buttonStyle(.plain).accessibilityLabel("Выбрать дату в календаре")
    }
    @ViewBuilder private var todayButton: some View {
        if selection != nil {
            Button("Сегодня") { selection = nil }
                .font(.caption.weight(.semibold)).frame(minHeight: 44)
        }
    }
    private var weekButtons: some View {
        HStack(spacing: 4) {
            Button { moveWeek(-1) } label: {
                Image(systemName: "chevron.left").frame(width: 36, height: 44)
            }.accessibilityLabel("Предыдущая неделя")
            Button { moveWeek(1) } label: {
                Image(systemName: "chevron.right").frame(width: 36, height: 44)
            }.accessibilityLabel("Следующая неделя").disabled(isCurrentWeek)
        }
    }

    private func day(_ date: Date) -> some View {
        let isSelected = calendar.isDate(date, inSameDayAs: selected)
        let isFuture = calendar.startOfDay(for: date) > calendar.startOfDay(for: today)
        let weekday = ["ВС", "ПН", "ВТ", "СР", "ЧТ", "ПТ", "СБ"][calendar.component(.weekday, from: date) - 1]
        return Button { select(date) } label: {
            VStack(spacing: 4) {
                Text("\(calendar.component(.day, from: date))")
                    .font(.system(.body, design: .rounded, weight: .bold)).monospacedDigit()
                Text(weekday).font(.system(.caption2, design: .rounded, weight: .semibold))
            }
            .lineLimit(1).minimumScaleFactor(0.7)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity).frame(minHeight: 56)
            .foregroundStyle(isSelected ? Color.white : .primary)
            .background(isSelected ? Color.folkiAccent : Color(uiColor: .secondarySystemGroupedBackground).opacity(0.5),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .opacity(isFuture ? 0.38 : (isSelected ? 1 : 0.75))
        }
        .buttonStyle(.plain).frame(maxWidth: .infinity).disabled(isFuture)
        .accessibilityLabel(date.formatted(.dateTime.weekday(.wide).day().month(.wide).year()))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func select(_ date: Date) {
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) {
            selection = calendar.isDate(date, inSameDayAs: today) ? nil : calendar.startOfDay(for: date)
        }
    }
    private func moveWeek(_ direction: Int) {
        guard let target = calendar.date(byAdding: .day, value: direction * 7, to: selected) else { return }
        select(min(target, today))
    }
}
