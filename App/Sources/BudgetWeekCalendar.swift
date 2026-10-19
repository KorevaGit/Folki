import SwiftUI

/// A Monday-first week; selection is independent of the live ledger's clock.
struct BudgetWeekCalendar: View {
    @Binding var selection: Date?
    let today: Date
    let calendar: Calendar
    /// Personal and family day-ring fractions for a past or current day; nil where no plan exists.
    var rings: (Date) -> (Double?, Double?) = { _ in (nil, nil) }
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
            HStack(spacing: 2) {
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
        let weekday = ["вс", "пн", "вт", "ср", "чт", "пт", "сб"][calendar.component(.weekday, from: date) - 1]
        let fractions = isFuture ? (nil, nil) : rings(date)
        return Button { select(date) } label: {
            VStack(spacing: 4) {
                Text(weekday).font(.system(.caption2, design: .rounded, weight: .semibold))
                MiniRings(personal: fractions.0, family: fractions.1).frame(width: 30, height: 30)
                Text("\(calendar.component(.day, from: date))")
                    .font(.system(.footnote, design: .rounded, weight: .heavy)).monospacedDigit()
            }
            .lineLimit(1).minimumScaleFactor(0.7)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .foregroundStyle(isSelected ? Color.white : Color.folkiInk)
            .background(isSelected ? Color.folkiAccent : Color.clear, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .opacity(isFuture ? 0.4 : 1)
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

/// A day's two rings at calendar size: personal outside, family inside.
private struct MiniRings: View {
    let personal: Double?
    let family: Double?
    var body: some View {
        ZStack {
            ring(personal, palette: .personal).padding(0)
            ring(family, palette: .family).padding(5.5)
        }
    }
    private func ring(_ fraction: Double?, palette: RingPalette) -> some View {
        ZStack {
            Circle().stroke(palette.start.opacity(0.22), lineWidth: 3.5)
            Circle().trim(from: 0, to: max(0, min(1, fraction ?? 0)))
                .stroke(palette.start, style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }.padding(1.75)
    }
}
