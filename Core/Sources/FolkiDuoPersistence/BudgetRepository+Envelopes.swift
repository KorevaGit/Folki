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
                               kind: EnvelopeKind = .payment, target: Money? = nil,
                               in budget: StoredBudget, asOf now: Date,
                               id: UUID = UUID(), initialFunding: Money = Money(minorUnits: 0)) throws -> RecurringEnvelope {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 80, size.currency == .rub else { throw BudgetError.invalidPlan }
        let envelope = try RecurringEnvelope(id: id, name: trimmed, size: size, dueDay: dueDay,
                                             nextDue: budget.snapshot.period.calendar.startOfDay(for: nextDue), isMandatory: isMandatory,
                                             categoryID: categoryID, symbol: symbol, color: color, kind: kind, target: target)
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
            guard initialFunding.currency == size.currency, initialFunding.minorUnits >= 0,
                  initialFunding.minorUnits <= envelope.capacity.minorUnits else { throw BudgetError.invalidAmount }
            if initialFunding.minorUnits > 0 {
                guard let current = try load(asOf: now, scope: budget.scope) else { throw LedgerError.unavailable }
                let free = try DailyBudgetCalculator.calculate(current.snapshot, asOf: now).monthlyRemaining
                guard initialFunding.minorUnits <= free.minorUnits else { throw BudgetError.insufficientReserve }
                try write([movement(.reserveAllocation, amount: initialFunding, envelope: envelope.id,
                    title: envelope.name, budget: current, now: now)], in: current, root: root, now: now)
            }
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

    /// Assigns existing living money in one commit, without recording another income.
    public func distributeAvailable(_ fills: [UUID: Money], in budget: StoredBudget,
                                    asOf now: Date, operationID: UUID) throws {
        do {
            let root = try writableRoot(budget, now: now)
            guard try fetch("Transaction", predicate: NSPredicate(format: "id == %@", operationID as NSUUID)).isEmpty else { return }
            guard let current = try load(asOf: now, scope: budget.scope) else { throw LedgerError.unavailable }
            let result = try DailyBudgetCalculator.calculate(current.snapshot, asOf: now)
            var total = Money(minorUnits: 0)
            var records: [LedgerRecord] = []
            for id in fills.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
                guard let fill = fills[id], fill.currency == .rub, fill.minorUnits >= 0 else { throw BudgetError.invalidAmount }
                let item = try writableItem("Envelope", id: id, budget: current)
                guard item.value(forKey: "archived") as? Bool != true else { throw BudgetError.invalidPlan }
                let envelope = try decodeEnvelope(item)
                let balance = result.reserveBalances[id] ?? Money(minorUnits: 0)
                guard fill.minorUnits <= (try envelope.shortfall(balance: balance)).minorUnits else { throw BudgetError.invalidAmount }
                total = try total.adding(fill)
                if fill.minorUnits > 0 {
                    records.append(try movement(.reserveAllocation, amount: fill, envelope: id, title: envelope.name,
                        budget: current, now: now, id: records.isEmpty ? operationID : UUID()))
                }
            }
            guard total.minorUnits <= result.monthlyRemaining.minorUnits else { throw BudgetError.insufficientReserve }
            try write(records, in: current, root: root, now: now)
            try commit()
        } catch { context.rollback(); throw error }
    }

    /// A spend from an envelope. Only the spend leaves it; whatever is left stays set aside.
    /// When the envelope holds less than the spend, living money first tops it up by the difference, so the
    /// shortfall is spread over the days that are left instead of landing on today, and then all of it is spent
    /// from the envelope. `closesCycle` also closes the bill for this time (see `closeEnvelope`).
    public func spendFromEnvelope(_ id: UUID, amount: Money, in budget: StoredBudget, asOf now: Date,
                                  operationID: UUID = UUID(), closesCycle: Bool = false) throws {
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
            let shortfall = Money(minorUnits: max(0, amount.minorUnits - balance.minorUnits))
            let author = try authorID(in: current)
            var records: [LedgerRecord] = []
            if shortfall.minorUnits > 0 {
                records.append(try movement(.reserveAllocation, amount: shortfall, envelope: id, title: envelope.name, budget: current, now: now,
                                            id: Self.topUpID(for: operationID)))
            }
            records.append(LedgerRecord(transaction: TransactionSnapshot(id: operationID, amount: amount, kind: .expense,
                funding: .reserve(id), date: now, authorID: author, payerID: author), title: "", categoryID: category))
            try write(records, in: current, root: root, now: now)
            if closesCycle && !envelope.isSavings {
                try encodeEnvelope(closing(envelope, in: current, now: now), into: item)
            }
            try commit()
        } catch { context.rollback(); throw error }
    }

    /// Deletes or restores a spend from an envelope as one operation: with it go the top-ups living money made into
    /// the envelope at the same moment, and a bill it closed in this period opens again when it is deleted.
    public func setEnvelopeSpendDeleted(_ spend: LedgerRecord, deleted: Bool, in budget: StoredBudget, asOf now: Date) throws {
        guard spend.transaction.kind == .expense, case .reserve(let id) = spend.transaction.funding else { throw BudgetError.invalidTransaction }
        do {
            let root = try writableRoot(budget, now: now)
            guard let current = try load(asOf: now, scope: budget.scope) else { throw LedgerError.conflict }
            let topUp = Self.topUpID(for: spend.id)
            let parts = current.records.filter { $0.id == spend.id || $0.id == topUp }
            let changed = parts.map { record in
                LedgerRecord(transaction: TransactionSnapshot(id: record.id, amount: record.transaction.amount, kind: record.transaction.kind,
                    funding: record.transaction.funding, date: record.transaction.date, authorID: record.transaction.authorID,
                    payerID: record.transaction.payerID, isDeleted: deleted),
                    title: record.title, categoryID: record.categoryID, linkID: record.linkID)
            }
            // The whole operation must leave a valid ledger, whichever order the parts are applied in.
            let ids = Set(changed.map(\.id))
            let snapshot = HouseholdSnapshot(id: current.snapshot.id, period: current.snapshot.period,
                monthlyFreePlan: current.snapshot.monthlyFreePlan, openingFunds: current.snapshot.openingFunds, reserves: current.snapshot.reserves,
                transactions: current.records.filter { !ids.contains($0.id) }.map(\.transaction) + changed.map(\.transaction))
            _ = try DailyBudgetCalculator.calculate(snapshot, asOf: now)
            for record in changed {
                guard let object = try fetch("Transaction", predicate: NSPredicate(format: "id == %@", record.id as NSUUID)).first else {
                    throw LedgerError.conflict
                }
                encode(record, into: object, updatedAt: now)
            }
            if deleted {
                let item = try writableItem("Envelope", id: id, budget: current)
                let envelope = try decodeEnvelope(item)
                if envelope.closedThrough == current.snapshot.period.endExclusive {
                    let calendar = current.snapshot.period.calendar
                    guard let earlier = calendar.date(byAdding: .month, value: -1, to: envelope.nextDue) else { throw BudgetError.invalidPeriod }
                    let previous = try EnvelopeSchedule.dueDate(day: envelope.dueDay, inMonthOf: earlier, calendar: calendar)
                    encodeEnvelope(try envelope.with(nextDue: previous).closed(through: nil), into: item)
                }
            }
            _ = root
            try commit()
        } catch { context.rollback(); throw error }
    }

    /// The top-up living money makes for a spend is tied to it by its identifier: the spend's, with the last byte flipped.
    static func topUpID(for spend: UUID) -> UUID {
        var bytes = spend.uuid
        bytes.15 ^= 0xFF
        return UUID(uuid: bytes)
    }

    /// «Закрыть период»: the bill is done for this time. Its date moves to the next one, it asks for nothing more,
    /// and what it holds stays fixed until the end of the period, when the rest returns to living money.
    public func closeEnvelope(_ id: UUID, in budget: StoredBudget, asOf now: Date) throws {
        do {
            _ = try writableRoot(budget, now: now)
            let item = try writableItem("Envelope", id: id, budget: budget)
            let envelope = try decodeEnvelope(item)
            guard !envelope.isSavings, !envelope.isClosed else { throw BudgetError.invalidPlan }
            try encodeEnvelope(closing(envelope, in: budget, now: now), into: item)
            try commit()
        } catch { context.rollback(); throw error }
    }

    /// Undoes a close: the bill is back on its date and asks for money again.
    public func reopenEnvelope(_ id: UUID, in budget: StoredBudget, asOf now: Date) throws {
        do {
            _ = try writableRoot(budget, now: now)
            let item = try writableItem("Envelope", id: id, budget: budget)
            let envelope = try decodeEnvelope(item)
            guard envelope.isClosed else { return }
            let calendar = budget.snapshot.period.calendar
            guard let earlier = calendar.date(byAdding: .month, value: -1, to: envelope.nextDue) else { throw BudgetError.invalidPeriod }
            let previous = try EnvelopeSchedule.dueDate(day: envelope.dueDay, inMonthOf: earlier, calendar: calendar)
            try encodeEnvelope(envelope.with(nextDue: previous).closed(through: nil), into: item)
            try commit()
        } catch { context.rollback(); throw error }
    }

    /// A new period has begun: envelopes closed through its start are open again for their next time.
    /// Their money was already returned to living money when the period was opened.
    public func clearClosures(_ ids: [UUID], in budget: StoredBudget, asOf now: Date) throws {
        guard !ids.isEmpty else { return }
        do {
            _ = try writableRoot(budget, now: now)
            for id in ids {
                let item = try writableItem("Envelope", id: id, budget: budget)
                try encodeEnvelope(decodeEnvelope(item).closed(through: nil), into: item)
            }
            try commit()
        } catch { context.rollback(); throw error }
    }

    private func closing(_ envelope: RecurringEnvelope, in budget: StoredBudget, now: Date) throws -> RecurringEnvelope {
        let calendar = budget.snapshot.period.calendar
        let next = try EnvelopeSchedule.nextDue(after: envelope.nextDue, day: envelope.dueDay, notBefore: now, calendar: calendar)
        return try envelope.with(nextDue: next).closed(through: budget.snapshot.period.endExclusive)
    }

    /// A bill that was not paid this time: it moves to its coming date and keeps what it holds.
    public func skipEnvelope(_ id: UUID, in budget: StoredBudget, asOf now: Date) throws {
        do {
            let root = try writableRoot(budget, now: now)
            let item = try writableItem("Envelope", id: id, budget: budget)
            let envelope = try decodeEnvelope(item)
            guard !envelope.isSavings else { throw BudgetError.invalidPlan }
            let next = try envelope.with(nextDue: EnvelopeSchedule.nextDue(after: envelope.nextDue, day: envelope.dueDay,
                                                                          notBefore: now, calendar: budget.snapshot.period.calendar))
            encodeEnvelope(next, into: item)
            try ensureReserve(for: next, in: budget, root: root)
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
            color: (item.value(forKey: "color") as? String).flatMap(CategoryColor.init(rawValue:)),
            // Envelopes from before jars existed, or of a kind this version does not know, are payments.
            kind: savingsTarget(item) == nil ? .payment : .savings, target: savingsTarget(item),
            closedThrough: item.value(forKey: "closedThrough") as? Date)
    }

    private func savingsTarget(_ item: NSManagedObject) -> Money? {
        guard item.value(forKey: "kind") as? String == EnvelopeKind.savings.rawValue,
              let target = item.value(forKey: "target") as? Int64, target > 0 else { return nil }
        return Money(minorUnits: target)
    }

    private func encodeEnvelope(_ envelope: RecurringEnvelope, into item: NSManagedObject) {
        item.setValue(envelope.name.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "name")
        item.setValue(envelope.size.minorUnits, forKey: "size")
        item.setValue(Int16(envelope.dueDay), forKey: "dueDay")
        item.setValue(envelope.nextDue, forKey: "nextDue")
        item.setValue(envelope.isMandatory, forKey: "mandatory")
        item.setValue(envelope.symbol, forKey: "symbol")
        item.setValue(envelope.color?.rawValue, forKey: "color")
        item.setValue(envelope.kind.rawValue, forKey: "kind")
        item.setValue(envelope.target?.minorUnits, forKey: "target")
        item.setValue(envelope.closedThrough, forKey: "closedThrough")
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
        reserve.setValue(envelope.capacity.minorUnits, forKey: "targetAmount")
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

extension BudgetRepository {
    /// Income, envelope fills and both contribution sides are committed together, or all rolled back.
    public func deposit(_ amount: Money, fills: [UUID: Money], familyShare: Money, in budget: StoredBudget,
                        family: StoredBudget? = nil, asOf now: Date, operationID: UUID) throws {
        do {
            let root = try writableRoot(budget, now: now)
            let existing = try fetch("Transaction", predicate: NSPredicate(format: "id == %@", operationID as NSUUID))
            if let item = existing.first {
                guard item.value(forKey: "amount") as? Int64 == amount.minorUnits,
                      item.value(forKey: "kind") as? String == "income",
                      item.value(forKey: "tombstone") as? Bool != true,
                      item.value(forKey: "period") as? NSManagedObject == (try object("BudgetPeriod", id: budget.periodID)) else { throw LedgerError.conflict }
                return
            }
            guard let current = try load(asOf: now, scope: budget.scope) else { throw LedgerError.unavailable }
            let author = try authorID(in: current)
            let projected = try FundingPlan.applying(to: current.snapshot, incoming: amount, fills: fills,
                familyShare: familyShare, now: now, author: author, operationID: operationID)
            for (id, fill) in fills {
                let item = try writableItem("Envelope", id: id, budget: current)
                let envelope = try decodeEnvelope(item)
                let balance = try DailyBudgetCalculator.calculate(current.snapshot, asOf: now).reserveBalances[id] ?? Money(minorUnits: 0)
                guard fill.minorUnits <= (try envelope.shortfall(balance: balance)).minorUnits else { throw BudgetError.invalidAmount }
            }
            let period = try object("BudgetPeriod", id: current.periodID)
            period.setValue(projected.monthlyFreePlan.minorUnits, forKey: "monthlyPlan")
            let records = projected.transactions.dropFirst(current.snapshot.transactions.count).map { transaction in
                LedgerRecord(transaction: transaction, title: transaction.kind == .contributionOut ? String(localized: "В семейный бюджет", bundle: .module) : "",
                    linkID: transaction.kind == .contributionOut ? operationID : nil)
            }
            try write(records, in: current, root: root, now: now)
            if familyShare.minorUnits > 0 {
                guard current.scope == .personal, let family, family.scope == .family else { throw LedgerError.accessDenied }
                let familyRoot = try writableRoot(family, now: now)
                let familyAuthor = try authorID(in: family)
                let record = LedgerRecord(transaction: TransactionSnapshot(amount: familyShare, kind: .contributionIn, date: now,
                    authorID: familyAuthor, payerID: familyAuthor), title: String(localized: "Взнос в семейный бюджет", bundle: .module), linkID: operationID)
                try write([record], in: family, root: familyRoot, now: now)
                try changePlan(of: family.periodID, by: familyShare.minorUnits)
            }
            try commit()
        } catch { context.rollback(); throw error }
    }
}
