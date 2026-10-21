import SwiftUI

/// Seven days ending tomorrow, paged back a week at a time; selection is independent of the live ledger's clock.
struct BudgetWeekCalendar: View {
    @Binding var selection: Date?
    let today: Date
    let calendar: Calendar
    var showsFamily = true
    /// Personal and family day-ring fractions for a past or current day; nil where no plan exists.
    var rings: (Date) -> (Double?, Double?) = { _ in (nil, nil) }
    @State private var showingMonth = false
    @Namespace private var pill
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private var selected: Date { selection ?? today }
    /// Weeks moved back from the current window; 0 shows five days before today, today and tomorrow.
    private var page: Int {
        let firstVisible = calendar.date(byAdding: .day, value: -5, to: calendar.startOfDay(for: today)) ?? today
        let behind = calendar.dateComponents([.day], from: calendar.startOfDay(for: selected), to: firstVisible).day ?? 0
        return behind <= 0 ? 0 : (behind + 6) / 7
    }
    private var weekStart: Date {
        let start = calendar.startOfDay(for: today)
        return calendar.date(byAdding: .day, value: -5 - 7 * page, to: start) ?? start
    }
    private var isCurrentWeek: Bool { page == 0 }
    private var dateBinding: Binding<Date> {
        Binding(get: { selected }, set: { select($0) })
    }

    var body: some View {
        VStack(spacing: 6) {
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 4) {
                        monthButton
                        HStack { if selection != nil { todayButton }; Spacer(); weekButtons }
                    }
                } else {
                    HStack(spacing: 4) {
                        monthButton
                        Spacer(minLength: 4)
                        if selection != nil { todayButton.transition(.opacity) }
                        weekButtons
                    }
                }
            }.foregroundStyle(.secondary)
            .animation(reduceMotion ? nil : FolkiMotion.quick, value: selection == nil)
            ZStack {
                HStack(spacing: 2) {
                    ForEach(0..<7, id: \.self) { offset in
                        if let date = calendar.date(byAdding: .day, value: offset, to: weekStart) {
                            day(date)
                        }
                    }
                }
                .animation(reduceMotion ? nil : FolkiMotion.quick, value: selected)
                .id(weekStart)
                .transition(reduceMotion ? .opacity : .asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading)))
            }.clipped()
            .animation(reduceMotion ? nil : FolkiMotion.standard, value: weekStart)
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
                Image(systemName: "calendar").font(.subheadline.weight(.semibold))
                Text(selected, format: .dateTime.month(.wide)).font(.subheadline.weight(.semibold))
                    .lineLimit(1).minimumScaleFactor(0.7)
            }.frame(minWidth: 44, minHeight: 44, alignment: .leading)
        }.buttonStyle(.plain).accessibilityLabel("Выбрать дату в календаре")
    }
    private var todayButton: some View {
        Button("Сегодня") {
            select(today)
        }
            .font(.caption.weight(.semibold)).frame(minWidth: 60, minHeight: 44)
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
        let isToday = calendar.isDate(date, inSameDayAs: today)
        let isFuture = calendar.startOfDay(for: date) > calendar.startOfDay(for: today)
        let weekday = date.formatted(.dateTime.weekday(.abbreviated)).lowercased().replacingOccurrences(of: ".", with: "")
        let fractions = isFuture ? (nil, nil) : rings(date)
        return Button { select(date) } label: {
            VStack(spacing: 4) {
                Text(weekday).font(.system(.caption2, design: .rounded, weight: .semibold))
                MiniRings(personal: fractions.0, family: fractions.1, onAccent: isSelected, showsFamily: showsFamily).frame(width: 30, height: 30)
                    .accessibilityHidden(true)
                    .padding(3)
                Text("\(calendar.component(.day, from: date))")
                    .font(.system(.footnote, design: .rounded, weight: .heavy)).monospacedDigit()
                Circle().fill(isToday ? (isSelected ? Color.white : Color.folkiAccent) : .clear)
                    .frame(width: 5, height: 5)
            }
            .lineLimit(1).minimumScaleFactor(0.7)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .foregroundStyle(isSelected ? Color.white : Color.folkiInk)
            .background {
                // The selection slides between days instead of jumping.
                if isSelected {
                    RoundedRectangle(cornerRadius: FolkiSpacing.controlRadius, style: .continuous).fill(Color.folkiAccent)
                        .matchedGeometryEffect(id: "selected", in: pill)
                }
            }
            .opacity(isFuture ? 0.3 : 1)
        }
        .buttonStyle(FolkiPressStyle(scale: 0.92)).frame(maxWidth: .infinity).disabled(isFuture)
        .accessibilityLabel((isToday ? String(localized: "Сегодня, ") : "") + date.formatted(.dateTime.weekday(.wide).day().month(.wide).year()))
        .accessibilityValue(isFuture ? String(localized: "Будущий день") : (showsFamily
            ? String(localized: "Личный: \(spokenFraction(fractions.0)). Семейный: \(spokenFraction(fractions.1)).")
            : String(localized: "Личный: \(spokenFraction(fractions.0)).")))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func spokenFraction(_ value: Double?) -> String {
        guard let value else { return String(localized: "нет плана") }
        return String(localized: "осталось \(Int((max(0, min(1, value)) * 100).rounded())) процентов дневного ориентира")
    }

    private func select(_ date: Date) {
        let day = calendar.startOfDay(for: date)
        guard !calendar.isDate(day, inSameDayAs: selected) else { return }
        FolkiFeedback.selection()
        // No screen-wide animation: each part animates itself, so the switch stays light.
        selection = calendar.isDate(day, inSameDayAs: today) ? nil : day
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
    /// On the selected (green) day both rings turn white so they stay readable.
    var onAccent = false
    var showsFamily = true
    var body: some View {
        ZStack {
            ring(personal, palette: .personal).padding(0)
            if showsFamily { ring(family, palette: .family).padding(5.5) }
        }
    }
    private func ring(_ fraction: Double?, palette: RingPalette) -> some View {
        ZStack {
            Circle().stroke((onAccent ? Color.white : palette.start).opacity(onAccent ? 0.3 : 0.4), lineWidth: 3.5)
            Circle().trim(from: 0, to: max(0, min(1, fraction ?? 0)))
                .stroke(onAccent ? Color.white : palette.start, style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }.padding(1.75)
    }
}
