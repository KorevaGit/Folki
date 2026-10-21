import CoreData
import FolkiDuoCore

/// Recurring envelopes live on the budget and outlast periods. Each one's balance is a reserve with
/// the same identifier in the current period: money goes in with an allocation and out with a payment.
extension BudgetRepository {
    /// Active envelopes of a budget, nearest payment first.
    public func envelopes(scope: BudgetScope) throws -> [RecurringEnvelope] {
        let roots = try households(in: scope)
        guard roots.count <= 1 else { throw LedgerError.multipleHouseholds }
        guard let root = roots.first else { return [] }
        return try fetch("Envelope", predicate: NSPredicate(format: "household == %@ AND archived != YES", root))
            .map(decodeEnvelope)
            .sorted { $0.nextDue != $1.nextDue ? $0.nextDue < $1.nextDue : $0.id.uuidString < $1.id.uuidString }
    }

    /// The category an envelope's payments are recorded under.
    public func envelopeCategory(_ id: UUID) throws -> UUID {
        try object("Envelope", id: id).value(forKey: "categoryID") as? UUID ?? BuiltInCategory.other.id
    }

    @discardableResult
    public func createEnvelope(name: String, size: Money, dueDay: Int, nextDue: Date, isMandatory: Bool,
                               categoryID: UUID? = nil, symbol: String? = nil, color: CategoryColor? = nil,
                               in budget: StoredBudget, asOf now: Date,
                               id: UUID = UUID()) throws -> RecurringEnvelope {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 80, size.currency == .rub else { throw BudgetError.invalidPlan }
        let envelope = try RecurringEnvelope(id: id, name: trimmed, size: size, dueDay: dueDay,
                                             nextDue: budget.snapshot.period.calendar.startOfDay(for: nextDue), isMandatory: isMandatory,
                                             categoryID: categoryID, symbol: symbol, color: color)
        do {
            let root = try writableRoot(budget, now: now)
            if let categoryID { try validateCategory(categoryID, household: root, allowArchived: false) }
            guard try fetch("Envelope", predicate: NSPredicate(format: "id == %@", id as NSUUID)).isEmpty else {
                throw BudgetError.duplicateIdentifier
            }
            let item = insert("Envelope", id: id, household: root)
            item.setValue(categoryID, forKey: "categoryID")
            item.setValue(now, forKey: "createdAt")
            item.setValue(false, forKey: "archived")
            encodeEnvelope(envelope, into: item)
            try ensureReserve(for: envelope, in: budget, root: root)
            try commit()
            return envelope
        } catch { context.rollback(); throw error }
    }

    public func updateEnvelope(_ envelope: RecurringEnvelope, in budget: StoredBudget, asOf now: Date) throws {
        do {
            let root = try writableRoot(budget, now: now)
            let item = try writableItem("Envelope", id: envelope.id, budget: budget)
            let trimmed = envelope.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.count <= 80 else { throw BudgetError.invalidPlan }
            encodeEnvelope(envelope, into: item)
            try ensureReserve(for: envelope, in: budget, root: root)
            try commit()
        } catch { context.rollback(); throw error }
    }

    /// An archived envelope leaves the list; whatever it holds goes back to living money.
    public func archiveEnvelope(_ id: UUID, in budget: StoredBudget, asOf now: Date) throws {
        do {
            let root = try writableRoot(budget, now: now)
            let item = try writableItem("Envelope", id: id, budget: budget)
            let result = try DailyBudgetCalculator.calculate(budget.snapshot, asOf: now)
            if let balance = result.reserveBalances[id], balance.minorUnits > 0 {
                try write([movement(.reserveRelease, amount: balance, envelope: id, title: try envelopeName(item), budget: budget, now: now)],
                          in: budget, root: root, now: now)
            }
            item.setValue(true, forKey: "archived")
            item.setValue(UUID(), forKey: "revision")
            try commit()
        } catch { context.rollback(); throw error }
    }

    /// Moves living money into an envelope. Retrying with the same `operationID` is a no-op.
    public func fundEnvelope(_ id: UUID, amount: Money, in budget: StoredBudget, asOf now: Date,
                             operationID: UUID = UUID()) throws {
        guard amount.currency == .rub, amount.minorUnits > 0 else { throw BudgetError.invalidAmount }
        do {
            guard try fetch("Transaction", predicate: NSPredicate(format: "id == %@", operationID as NSUUID)).isEmpty else { return }
            let root = try writableRoot(budget, now: now)
            let item = try writableItem("Envelope", id: id, budget: budget)
            let envelope = try decodeEnvelope(item)
            try ensureReserve(for: envelope, in: budget, root: root)
            guard let current = try load(asOf: now, scope: budget.scope) else { throw LedgerError.conflict }
            let free = try DailyBudgetCalculator.calculate(current.snapshot, asOf: now).monthlyRemaining
            guard amount.minorUnits <= free.minorUnits else { throw BudgetError.insufficientReserve }
            try write([movement(.reserveAllocation, amount: amount, envelope: id, title: envelope.name, budget: current, now: now, id: operationID)],
                      in: current, root: root, now: now)
            try commit()
        } catch { context.rollback(); throw error }
    }

    /// Pays an envelope with the real amount of the bill and moves it to next month.
    /// The envelope's balance pays first; a bigger bill takes the difference from living money,
    /// a smaller one returns the remainder to living money.
    public func payEnvelope(_ id: UUID, amount: Money, in budget: StoredBudget, asOf now: Date,
                            operationID: UUID = UUID()) throws {
        guard amount.currency == .rub, amount.minorUnits > 0 else { throw BudgetError.invalidAmount }
        do {
            guard try fetch("Transaction", predicate: NSPredicate(format: "id == %@", operationID as NSUUID)).isEmpty else { return }
            let root = try writableRoot(budget, now: now)
            let item = try writableItem("Envelope", id: id, budget: budget)
            let envelope = try decodeEnvelope(item)
            try ensureReserve(for: envelope, in: budget, root: root)
            guard let current = try load(asOf: now, scope: budget.scope) else { throw LedgerError.conflict }
            let balance = try DailyBudgetCalculator.calculate(current.snapshot, asOf: now).reserveBalances[id]
                ?? Money(minorUnits: 0)
            let category = item.value(forKey: "categoryID") as? UUID ?? BuiltInCategory.other.id
            let fromEnvelope = Money(minorUnits: min(balance.minorUnits, amount.minorUnits))
            let fromLiving = try amount.subtracting(fromEnvelope)
            let leftover = try balance.subtracting(fromEnvelope)
            let author = try authorID(in: current)
            var records: [LedgerRecord] = []
            if fromEnvelope.minorUnits > 0 {
                records.append(LedgerRecord(transaction: TransactionSnapshot(id: operationID, amount: fromEnvelope, kind: .expense,
                    funding: .reserve(id), date: now, authorID: author, payerID: author), title: envelope.name, categoryID: category))
            }
            if fromLiving.minorUnits > 0 {
                records.append(LedgerRecord(transaction: TransactionSnapshot(id: records.isEmpty ? operationID : UUID(), amount: fromLiving,
                    kind: .expense, funding: .flexible, date: now, authorID: author, payerID: author), title: envelope.name, categoryID: category))
            }
            if leftover.minorUnits > 0 {
                records.append(try movement(.reserveRelease, amount: leftover, envelope: id, title: envelope.name, budget: current, now: now))
            }
            try write(records, in: current, root: root, now: now)
            let calendar = current.snapshot.period.calendar
            let next = try EnvelopeSchedule.nextDue(after: envelope.nextDue, day: envelope.dueDay, calendar: calendar)
            try encodeEnvelope(envelope.with(nextDue: next), into: item)
            try commit()
        } catch { context.rollback(); throw error }
    }

    // MARK: - Storage

    private func decodeEnvelope(_ item: NSManagedObject) throws -> RecurringEnvelope {
        try RecurringEnvelope(id: item.required("id"), name: item.required("name"),
            size: Money(minorUnits: item.required("size")),
            dueDay: Int(item.value(forKey: "dueDay") as? Int16 ?? 1),
            nextDue: item.required("nextDue"),
            isMandatory: item.value(forKey: "mandatory") as? Bool ?? true,
            categoryID: item.value(forKey: "categoryID") as? UUID,
            symbol: item.value(forKey: "symbol") as? String,
            color: (item.value(forKey: "color") as? String).flatMap(CategoryColor.init(rawValue:)))
    }

    private func encodeEnvelope(_ envelope: RecurringEnvelope, into item: NSManagedObject) {
        item.setValue(envelope.name.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "name")
        item.setValue(envelope.size.minorUnits, forKey: "size")
        item.setValue(Int16(envelope.dueDay), forKey: "dueDay")
        item.setValue(envelope.nextDue, forKey: "nextDue")
        item.setValue(envelope.isMandatory, forKey: "mandatory")
        item.setValue(envelope.symbol, forKey: "symbol")
        item.setValue(envelope.color?.rawValue, forKey: "color")
        item.setValue(UUID(), forKey: "revision")
    }

    private func envelopeName(_ item: NSManagedObject) throws -> String { try item.required("name") }

    /// The current period holds a reserve for the envelope, so the ledger can hold its balance.
    private func ensureReserve(for envelope: RecurringEnvelope, in budget: StoredBudget, root: NSManagedObject) throws {
        let period = try object("BudgetPeriod", id: budget.periodID)
        let existing = try fetch("Reserve", predicate: NSPredicate(format: "period == %@ AND id == %@", period, envelope.id as NSUUID))
        let reserve = existing.first ?? {
            let item = insert("Reserve", id: envelope.id, household: root)
            item.setValue(period, forKey: "period")
            item.setValue(Int64(0), forKey: "openingAmount")
            return item
        }()
        reserve.setValue(envelope.name, forKey: "name")
        reserve.setValue(true, forKey: "isRegularPayment")
        reserve.setValue(envelope.nextDue, forKey: "dueDate")
        reserve.setValue(envelope.size.minorUnits, forKey: "targetAmount")
    }

    private func movement(_ kind: TransactionKind, amount: Money, envelope: UUID, title: String, budget: StoredBudget,
                          now: Date, id: UUID = UUID()) throws -> LedgerRecord {
        let author = try authorID(in: budget)
        return LedgerRecord(transaction: TransactionSnapshot(id: id, amount: amount, kind: kind, funding: .reserve(envelope),
            date: now, authorID: author, payerID: author), title: title)
    }

    /// Validates the records one after another against the live ledger, then inserts them.
    private func write(_ records: [LedgerRecord], in budget: StoredBudget, root: NSManagedObject, now: Date) throws {
        context.processPendingChanges()
        guard var current = try load(asOf: now, scope: budget.scope), current.periodID == budget.periodID else { throw LedgerError.conflict }
        let period = try object("BudgetPeriod", id: budget.periodID)
        for record in records {
            current = try LedgerRules.replacing(record, in: current, asOf: now)
            let item = insert("Transaction", id: record.id, household: root)
            item.setValue(period, forKey: "period")
            encode(record, into: item, updatedAt: now)
        }
    }
}

/// The "В семью 30%" line: a family default any member may change, and each member's own override.
extension BudgetRepository {
    /// The family default and this member's override, if any.
    public func contributionPercents(in family: StoredBudget) throws -> (family: Int, mine: Int?) {
        guard family.scope == .family else { throw LedgerError.accessDenied }
        let root = try object("Household", id: family.snapshot.id)
        let familyPercent = Int(root.value(forKey: "contributionPercent") as? Int16 ?? 30)
        let me = try object("Member", id: try authorID(in: family))
        let mine = Int(me.value(forKey: "contributionPercent") as? Int16 ?? -1)
        return (familyPercent, mine >= 0 ? mine : nil)
    }

    /// The percentage this member is offered on a personal top-up.
    public func effectiveContributionPercent(in family: StoredBudget) throws -> Int {
        let percents = try contributionPercents(in: family)
        return percents.mine ?? percents.family
    }

    public func setFamilyContributionPercent(_ percent: Int, in family: StoredBudget, asOf now: Date) throws {
        guard family.scope == .family, (0...100).contains(percent) else { throw BudgetError.invalidAmount }
        do {
            let root = try writableRoot(family, now: now)
            root.setValue(Int16(percent), forKey: "contributionPercent")
            try commit()
        } catch { context.rollback(); throw error }
    }

    /// Nil returns this member to the family default.
    public func setMyContributionPercent(_ percent: Int?, in family: StoredBudget, asOf now: Date) throws {
        guard family.scope == .family, percent.map({ (0...100).contains($0) }) ?? true else { throw BudgetError.invalidAmount }
        do {
            _ = try writableRoot(family, now: now)
            let me = try writableItem("Member", id: try authorID(in: family), budget: family)
            me.setValue(Int16(percent ?? -1), forKey: "contributionPercent")
            try commit()
        } catch { context.rollback(); throw error }
    }
}

extension BudgetRepository {
    /// Creates every record type of the model in the development CloudKit schema, including types the UI has not
    /// saved yet. Development builds only: it uploads sample records and takes a few seconds.
    public func initializeCloudSchema() throws {
        guard cloudIdentifier != nil else { throw LedgerError.cloudNotConfigured }
        try container.initializeCloudKitSchema(options: [])
    }
}
