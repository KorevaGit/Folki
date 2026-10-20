import SwiftUI
import FolkiDuoCore

extension EnvelopeUrgency {
    /// Grey while calm, amber at 3–7 days, red at 0–2; accent once full.
    var color: Color {
        switch self {
        case .funded: Color.folkiAccent
        case .calm: Color.secondary
        case .attention: Color.folkiWarning
        case .serious: Color.red
        }
    }
}

/// "Конверты": recurring payments of one budget, nearest first.
struct EnvelopesView: View {
    let personal: BudgetSession
    let family: BudgetSession
    @State private var scope: BudgetScope = .personal
    @State private var creating = false
    private var session: BudgetSession { scope == .family && family.household != nil ? family : personal }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: FolkiSpacing.section) {
                    if family.household != nil {
                        FolkiSegmentedPicker(title: String(localized: "Бюджет"), selection: $scope,
                                             options: [(String(localized: "Личные"), .personal), (String(localized: "Семейные"), .family)],
                                             minimumHeight: 36)
                    }
                    if session.envelopes.isEmpty {
                        empty
                    } else {
                        summary
                        VStack(spacing: FolkiSpacing.item) {
                            ForEach(session.envelopes) { envelope in
                                NavigationLink(value: envelope) { EnvelopeCard(session: session, envelope: envelope) }
                                    .buttonStyle(FolkiPressStyle(scale: 0.98))
                            }
                        }
                    }
                }.folkiPagePadding(top: FolkiSpacing.xs)
            }
            .background { FolkiBackground() }
            .navigationTitle("Конверты").toolbarTitleDisplayMode(.inlineLarge)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { creating = true } label: { Image(systemName: "plus") }.accessibilityLabel("Добавить конверт")
                }
            }
            .navigationDestination(for: RecurringEnvelope.self) { envelope in
                EnvelopeDetailView(session: session, envelopeID: envelope.id)
            }
            .sheet(isPresented: $creating) { EnvelopeEditorView(session: session) }
        }
    }

    private var summary: some View {
        let saved = session.envelopes.reduce(Int64(0)) { $0 + min(session.envelopeBalance($1).minorUnits, $1.size.minorUnits) }
        let total = session.envelopes.reduce(Int64(0)) { $0 + $1.size.minorUnits }
        let missing = session.envelopes.filter(\.isMandatory)
            .reduce(Int64(0)) { $0 + ((try? $1.shortfall(balance: session.envelopeBalance($1)).minorUnits) ?? 0) }
        let worst = session.envelopes.map(session.envelopeUrgency).max() ?? .funded
        return VStack(alignment: .leading, spacing: FolkiSpacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Отложено").font(.body).foregroundStyle(.secondary)
                Text(MoneyText.whole(Money(minorUnits: saved))).font(.system(size: 22, weight: .semibold, design: .rounded)).monospacedDigit()
                Text("из \(MoneyText.whole(Money(minorUnits: total)))").font(.body).foregroundStyle(.secondary).monospacedDigit()
            }
            ProgressBar(fraction: total > 0 ? Double(saved) / Double(total) : 0, color: worst == .funded ? .folkiAccent : worst.color, height: 8)
            if missing > 0 {
                Text("Не хватает \(MoneyText.whole(Money(minorUnits: missing).roundedUpToWholeUnits))")
                    .font(.subheadline.weight(.medium)).foregroundStyle(worst == .calm ? .secondary : worst.color)
            }
        }
    }

    private var empty: some View {
        VStack(spacing: FolkiSpacing.card) {
            Image(systemName: "tray.full").font(.system(size: 48)).foregroundStyle(.secondary)
            Text("Аренда, интернет, подписки — отложу на них заранее, и они не съедят дневной бюджет")
                .font(.body).multilineTextAlignment(.center)
            Button("Добавить конверт") { creating = true }.buttonStyle(FolkiSoftButtonStyle())
        }.frame(maxWidth: .infinity).padding(.top, FolkiSpacing.huge)
    }
}

struct ProgressBar: View {
    let fraction: Double
    let color: Color
    var height: CGFloat = 4
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.folkiSoft)
                Capsule().fill(color).frame(width: geo.size.width * max(0, min(1, fraction)))
            }
        }.frame(height: height).accessibilityHidden(true)
    }
}

/// Envelope icon: monochrome on this screen, colour belongs to the status.
private struct EnvelopeIcon: View {
    let session: BudgetSession
    let envelope: RecurringEnvelope
    var size: CGFloat = 44
    var body: some View {
        let category = session.catalog.category(for: envelope.categoryID ?? BuiltInCategory.other.id)
        Image(systemName: category.symbol).font(.system(size: size * 0.42, weight: .medium))
            .foregroundStyle(Color.folkiInk).frame(width: size, height: size)
            .background(Color.folkiSoft, in: Circle()).accessibilityHidden(true)
    }
}

private struct EnvelopeCard: View {
    let session: BudgetSession
    let envelope: RecurringEnvelope
    var body: some View {
        let balance = session.envelopeBalance(envelope)
        let urgency = session.envelopeUrgency(envelope)
        VStack(spacing: FolkiSpacing.item) {
            HStack(spacing: FolkiSpacing.item) {
                EnvelopeIcon(session: session, envelope: envelope)
                VStack(alignment: .leading, spacing: 2) {
                    Text(envelope.name).font(.headline).foregroundStyle(Color.folkiInk).lineLimit(1)
                    Text(dueText(envelope, session: session)).font(.footnote)
                        .foregroundStyle(urgency == .funded || urgency == .calm ? .secondary : urgency.color)
                }
                Spacer(minLength: FolkiSpacing.xs)
                VStack(alignment: .trailing, spacing: 2) {
                    HStack(spacing: 4) {
                        if urgency == .funded { Image(systemName: "checkmark").font(.footnote.bold()).foregroundStyle(Color.folkiAccent) }
                        Text(MoneyText.whole(balance)).font(.system(.body, design: .rounded, weight: .semibold)).monospacedDigit()
                            .foregroundStyle(Color.folkiInk)
                    }
                    Text("из \(MoneyText.whole(envelope.size))").font(.footnote).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            ProgressBar(fraction: Double(balance.minorUnits) / Double(envelope.size.minorUnits), color: urgency.color)
        }
        .padding(FolkiSpacing.card)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: FolkiSpacing.cardRadius))
        .accessibilityElement(children: .combine)
    }
}

@MainActor private func dueText(_ envelope: RecurringEnvelope, session: BudgetSession) -> String {
    let date = envelope.nextDue.formatted(.dateTime.day().month(.abbreviated))
    let days = session.daysUntil(envelope)
    switch days {
    case ..<0: return String(localized: "\(date) · просрочен")
    case 0: return String(localized: "\(date) · сегодня")
    case 1: return String(localized: "\(date) · завтра")
    default: return String(localized: "\(date) · через \(days) дн.")
    }
}

/// One envelope: its ring, payments and the two actions.
struct EnvelopeDetailView: View {
    let session: BudgetSession
    let envelopeID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var sheet: Sheet?
    @State private var paidCheck = false
    @State private var askNewSize: Money?
    @State private var errorMessage: String?
    enum Sheet: String, Identifiable { case fund, pay, edit; var id: String { rawValue } }
    private var envelope: RecurringEnvelope? { session.envelopes.first { $0.id == envelopeID } }

    var body: some View {
        ScrollView {
            if let envelope {
                let balance = session.envelopeBalance(envelope)
                let urgency = session.envelopeUrgency(envelope)
                VStack(spacing: FolkiSpacing.section) {
                    ZStack {
                        Circle().stroke(Color.folkiSoft, lineWidth: 16)
                        Circle().trim(from: 0, to: Double(balance.minorUnits) / Double(envelope.size.minorUnits))
                            .stroke(urgency.color, style: StrokeStyle(lineWidth: 16, lineCap: .round)).rotationEffect(.degrees(-90))
                            .animation(FolkiMotion.ring, value: balance)
                        VStack(spacing: 2) {
                            Text(MoneyText.whole(balance)).font(.system(size: 34, weight: .bold, design: .rounded)).monospacedDigit()
                                .contentTransition(.numericText()).animation(FolkiMotion.quick, value: balance)
                            Text("из \(MoneyText.whole(envelope.size))").font(.subheadline).foregroundStyle(.secondary)
                        }
                        if paidCheck {
                            Image(systemName: "checkmark").font(.system(size: 64, weight: .bold)).foregroundStyle(Color.folkiAccent)
                                .transition(.scale.combined(with: .opacity))
                        }
                    }.frame(width: 160, height: 160).padding(.top, FolkiSpacing.page)
                    VStack(spacing: FolkiSpacing.xxs) {
                        Text(envelope.name).font(.title2.weight(.semibold))
                        Text("Каждый месяц, \(envelope.dueDay)-го · \(dueText(envelope, session: session))")
                            .font(.subheadline).foregroundStyle(.secondary)
                        if !envelope.isMandatory { Text("Необязательный").font(.footnote).foregroundStyle(.tertiary) }
                    }.multilineTextAlignment(.center)
                    HStack(spacing: FolkiSpacing.item) {
                        Button("Пополнить") { sheet = .fund }.buttonStyle(FolkiSoftButtonStyle()).frame(maxWidth: .infinity)
                        Button("Оплачено") { sheet = .pay }.buttonStyle(FolkiPrimaryButtonStyle(fullWidth: true, minHeight: 50))
                    }
                    if let errorMessage { FolkiErrorMessage(message: errorMessage) }
                    history(envelope)
                }.folkiPagePadding()
            }
        }
        .background { FolkiBackground() }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Изменить", systemImage: "pencil") { sheet = .edit }
                    Button("Удалить конверт", systemImage: "trash", role: .destructive, action: archive)
                } label: { Image(systemName: "ellipsis") }.accessibilityLabel("Ещё")
            }
        }
        .sheet(item: $sheet) { kind in
            if let envelope {
                switch kind {
                case .fund: EnvelopeAmountSheet(session: session, envelope: envelope, mode: .fund) { _ in }
                case .pay: EnvelopeAmountSheet(session: session, envelope: envelope, mode: .pay) { paid in afterPayment(paid, envelope) }
                case .edit: EnvelopeEditorView(session: session, editing: envelope)
                }
            }
        }
        .alert("Сделать новым размером?", isPresented: Binding(get: { askNewSize != nil }, set: { if !$0 { askNewSize = nil } })) {
            Button("Да") {
                if let size = askNewSize, let envelope, let updated = try? envelope.with(size: size) { try? session.updateEnvelope(updated) }
                askNewSize = nil
            }
            Button("Только сейчас", role: .cancel) { askNewSize = nil }
        } message: {
            Text("Платёж был \(askNewSize.map(MoneyText.whole) ?? ""). Запомню эту сумму на следующие месяцы")
        }
    }

    private func history(_ envelope: RecurringEnvelope) -> some View {
        let records = session.envelopeHistory(envelope)
        return VStack(alignment: .leading, spacing: 0) {
            if !records.isEmpty {
                Text("История").font(.headline).padding(.bottom, FolkiSpacing.xs)
                ForEach(records) { record in
                    let paid = record.transaction.kind == .expense
                    let released = record.transaction.kind == .reserveRelease
                    HStack {
                        Text(paid ? "Оплачено" : released ? "Вернулось на жизнь" : "Пополнение").font(.body)
                        Spacer()
                        Text("\(paid || released ? "−" : "+")\(MoneyText.whole(record.transaction.amount))")
                            .font(.system(.body, design: .rounded)).monospacedDigit()
                        Text(record.transaction.date, format: .dateTime.day().month(.abbreviated))
                            .font(.footnote).foregroundStyle(.secondary).frame(width: 64, alignment: .trailing)
                    }.frame(minHeight: 44)
                    Divider()
                }
            }
        }
    }

    private func afterPayment(_ paid: Money, _ envelope: RecurringEnvelope) {
        withAnimation(FolkiMotion.quick) { paidCheck = true }
        Task {
            try? await Task.sleep(for: .seconds(0.8))
            withAnimation(FolkiMotion.standard) { paidCheck = false }
            if paid != envelope.size { askNewSize = paid }
        }
    }

    private func archive() {
        guard let envelope else { return }
        do { try session.archiveEnvelope(envelope); dismiss() }
        catch { errorMessage = String(localized: "Не получилось удалить конверт. Попробуй ещё раз.") }
    }
}

/// Amount sheet for "Пополнить" (from living money) and "Оплачено" (the real bill).
private struct EnvelopeAmountSheet: View {
    enum Mode { case fund, pay }
    @Environment(\.dismiss) private var dismiss
    let session: BudgetSession
    let envelope: RecurringEnvelope
    let mode: Mode
    let done: (Money) -> Void
    @State private var amount = ""
    @State private var operationID = UUID()
    @State private var errorMessage: String?
    private var money: Money? { (try? MoneyText.parse(amount)).flatMap { $0.minorUnits > 0 ? $0 : nil } }

    var body: some View {
        NavigationStack {
            VStack(spacing: FolkiSpacing.page) {
                Text(mode == .pay ? "Сколько заплатил за «\(envelope.name)»?" : "Сколько положить в «\(envelope.name)»?")
                    .font(.headline).multilineTextAlignment(.center)
                Text("\(amount.isEmpty ? "0" : MoneyText.grouped(amount)) ₽")
                    .font(.system(size: 52, weight: .bold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(money == nil ? .tertiary : .primary).lineLimit(1).minimumScaleFactor(0.4)
                    .contentTransition(.numericText()).animation(FolkiMotion.quick, value: amount)
                Text(hint).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                if let errorMessage { FolkiErrorMessage(message: errorMessage) }
                Spacer(minLength: 0)
                AmountKeypad(text: $amount)
                Button(mode == .pay ? "Оплачено" : "Положить", action: save)
                    .buttonStyle(FolkiPrimaryButtonStyle(fullWidth: true))
            }
            .padding(.horizontal, FolkiSpacing.page).padding(.bottom, FolkiSpacing.xs).padding(.top, FolkiSpacing.page)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } } }
        }
        .onAppear {
            let need = (try? envelope.shortfall(balance: session.envelopeBalance(envelope))) ?? envelope.size
            let free = session.result?.monthlyRemaining.nonnegative ?? Money(minorUnits: 0)
            let start = mode == .pay ? envelope.size : Money(minorUnits: min(need.minorUnits, free.minorUnits))
            amount = start.minorUnits > 0 ? MoneyText.input(start) : ""
        }
        .presentationDetents([.large])
    }

    private var hint: String {
        let balance = session.envelopeBalance(envelope)
        guard let money else { return "" }
        switch mode {
        case .fund:
            return String(localized: "Из денег на жизнь")
        case .pay:
            if money.minorUnits > balance.minorUnits {
                let diff = Money(minorUnits: money.minorUnits - balance.minorUnits)
                return String(localized: "\(MoneyText.whole(diff)) возьму из денег на жизнь")
            } else if money.minorUnits < balance.minorUnits {
                let diff = Money(minorUnits: balance.minorUnits - money.minorUnits)
                return String(localized: "\(MoneyText.whole(diff)) вернётся на жизнь")
            }
            return String(localized: "Ровно сколько отложено")
        }
    }

    private func save() {
        guard let money else { FolkiFeedback.boundary(); return }
        do {
            switch mode {
            case .fund: try session.fundEnvelope(envelope, amount: money, operationID: operationID)
            case .pay: try session.payEnvelope(envelope, amount: money, operationID: operationID)
            }
            FolkiFeedback.saved()
            dismiss()
            done(money)
        } catch BudgetError.insufficientReserve {
            errorMessage = String(localized: "Столько свободных денег сейчас нет")
        } catch {
            errorMessage = String(localized: "Не получилось сохранить. Попробуй ещё раз.")
        }
    }
}

/// Create (templates first) or edit an envelope.
struct EnvelopeEditorView: View {
    @Environment(\.dismiss) private var dismiss
    let session: BudgetSession
    var editing: RecurringEnvelope?
    @State private var choosing = true
    @State private var name = ""
    @State private var categoryID: UUID?
    @State private var amount = ""
    @State private var nextDue = Date.now
    @State private var mandatory = true
    @State private var errorMessage: String?
    @State private var offerFunding: RecurringEnvelope?
    private var money: Money? { (try? MoneyText.parse(amount)).flatMap { $0.minorUnits > 0 ? $0 : nil } }
    private let columns = Array(repeating: GridItem(.flexible(), spacing: FolkiSpacing.xs), count: 3)

    var body: some View {
        NavigationStack {
            Group {
                if choosing && editing == nil { templates } else { form }
            }
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } } }
        }
        .onAppear {
            guard let editing else { return }
            choosing = false; name = editing.name; categoryID = editing.categoryID
            amount = MoneyText.input(editing.size); nextDue = editing.nextDue; mandatory = editing.isMandatory
        }
        .alert("Положить сейчас?", isPresented: Binding(get: { offerFunding != nil }, set: { if !$0 { offerFunding = nil; dismiss() } })) {
            Button("Положить") {
                if let envelope = offerFunding {
                    let free = session.result?.monthlyRemaining.nonnegative ?? Money(minorUnits: 0)
                    let put = Money(minorUnits: min(envelope.size.minorUnits, free.minorUnits))
                    if put.minorUnits > 0 { try? session.fundEnvelope(envelope, amount: put); FolkiFeedback.saved() }
                }
                offerFunding = nil; dismiss()
            }
            Button("Позже", role: .cancel) { offerFunding = nil; dismiss() }
        } message: {
            Text("Положить \(offerFunding.map { MoneyText.whole($0.size) } ?? "") из денег на жизнь? Иначе конверт будет пополняться со следующих поступлений")
        }
    }

    private var templates: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: FolkiSpacing.page) {
                Button {
                    choosing = false
                } label: {
                    Label("Свой конверт", systemImage: "plus").font(.headline).frame(maxWidth: .infinity, minHeight: 52)
                }.buttonStyle(FolkiSoftButtonStyle())
                LazyVGrid(columns: columns, spacing: FolkiSpacing.page) {
                    ForEach(PaymentTemplates.all) { category in
                        Button {
                            FolkiFeedback.selection()
                            name = category.name; categoryID = category.id; mandatory = category.isEssential; choosing = false
                        } label: {
                            VStack(spacing: FolkiSpacing.xs) {
                                CategoryIcon(category: category, size: 44)
                                Text(category.name).font(.footnote).foregroundStyle(Color.folkiInk).lineLimit(2).multilineTextAlignment(.center)
                            }.frame(maxWidth: .infinity)
                        }.buttonStyle(FolkiPressStyle())
                    }
                }
            }.padding(FolkiSpacing.page)
        }.navigationTitle("Новый конверт").navigationBarTitleDisplayMode(.inline)
    }

    private var form: some View {
        VStack(spacing: FolkiSpacing.card) {
            TextField("Название", text: $name).font(.title2.weight(.semibold)).multilineTextAlignment(.center)
            Text("\(amount.isEmpty ? "0" : MoneyText.grouped(amount)) ₽")
                .font(.system(size: 52, weight: .bold, design: .rounded)).monospacedDigit()
                .foregroundStyle(money == nil ? .tertiary : .primary).lineLimit(1).minimumScaleFactor(0.4)
            VStack(spacing: 0) {
                DatePicker("Ближайшая оплата", selection: $nextDue, in: session.calendar.startOfDay(for: session.referenceDate)...,
                           displayedComponents: .date).frame(minHeight: 44)
                Divider()
                Toggle(isOn: $mandatory) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Обязательный")
                        Text("Нужно собрать полностью к дате").font(.footnote).foregroundStyle(.secondary)
                    }
                }.frame(minHeight: 52)
            }
            .padding(.horizontal, FolkiSpacing.card)
            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: FolkiSpacing.cardRadius))
            if let errorMessage { FolkiErrorMessage(message: errorMessage) }
            Spacer(minLength: 0)
            AmountKeypad(text: $amount)
            Button(editing == nil ? "Создать" : "Сохранить", action: save).buttonStyle(FolkiPrimaryButtonStyle(fullWidth: true))
        }
        .padding(.horizontal, FolkiSpacing.page).padding(.bottom, FolkiSpacing.xs)
        .navigationTitle(editing == nil ? "Новый конверт" : "Конверт").navigationBarTitleDisplayMode(.inline)
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let money, !trimmed.isEmpty else { FolkiFeedback.boundary(); errorMessage = String(localized: "Нужны название и сумма"); return }
        do {
            if let editing {
                let day = session.calendar.component(.day, from: nextDue)
                try session.updateEnvelope(editing.with(name: trimmed, size: money, dueDay: day,
                                                        nextDue: session.calendar.startOfDay(for: nextDue), isMandatory: mandatory))
                FolkiFeedback.saved(); dismiss()
            } else {
                let created = try session.createEnvelope(name: trimmed, size: money, nextDue: nextDue, isMandatory: mandatory, categoryID: categoryID)
                FolkiFeedback.saved()
                if (session.result?.monthlyRemaining.minorUnits ?? 0) > 0 { offerFunding = created } else { dismiss() }
            }
        } catch {
            errorMessage = String(localized: "Не получилось сохранить конверт. Попробуй ещё раз.")
        }
    }
}
