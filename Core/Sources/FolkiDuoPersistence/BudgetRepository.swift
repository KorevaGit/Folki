import Foundation
import CoreData
import CloudKit
import Observation
import FolkiDuoCore

private struct CloudEventSnapshot: Sendable {
    let identifier: UUID
    let storeIdentifier: String
    let type: Int
    let endDate: Date?
    let succeeded: Bool

    init(_ event: NSPersistentCloudKitContainer.Event) {
        identifier = event.identifier
        storeIdentifier = event.storeIdentifier
        type = event.type.rawValue
        endDate = event.endDate
        succeeded = event.succeeded
    }
}

@MainActor @Observable
public final class BudgetRepository {
    public let container: NSPersistentCloudKitContainer
    public let cloudIdentifier: String?
    public private(set) var changeToken = UUID()
    public private(set) var syncError: String?
    public private(set) var lastCloudUpdate: Date?
    public private(set) var pendingExport = false
    public private(set) var accountLocked = false
    public private(set) var cloudIdentity: String?
    private var observers: [NSObjectProtocol] = []
    private var exports = ExportTracker()
    private let localMemberID: UUID
    private var context: NSManagedObjectContext { container.viewContext }
    public var privateStore: NSPersistentStore { container.persistentStoreCoordinator.persistentStores.first! }
    public var sharedStore: NSPersistentStore? { container.persistentStoreCoordinator.persistentStores.dropFirst().first }
    public var statusText: String {
        if accountLocked { return "Аккаунт iCloud изменился. Верните прежний Apple ID и перезапустите Folki." }
        if let syncError { return syncError }
        if cloudIdentifier == nil { return "Сохранено на iPhone · iCloud не подключён" }
        if pendingExport { return "Сохранено на iPhone · ожидает отправки" }
        if lastCloudUpdate != nil { return "Обмен с iCloud выполнен" }
        return "Сохранено на iPhone · ожидание iCloud"
    }

    private init(container: NSPersistentCloudKitContainer, cloudIdentifier: String?, localMemberID: UUID) {
        self.container = container; self.cloudIdentifier = cloudIdentifier; self.localMemberID = localMemberID
        let metadata = container.persistentStoreCoordinator.metadata(for: privateStore)
        exports.pending = Set(metadata["FolkiPendingStores"] as? [String] ?? [])
        pendingExport = !exports.pending.isEmpty
        lastCloudUpdate = metadata["FolkiLastCloudUpdate"] as? Date
        context.automaticallyMergesChangesFromParent = true
        // Fail local optimistic conflicts; do not silently overwrite another editor's changes.
        context.mergePolicy = NSMergePolicy(merge: .errorMergePolicyType)
        context.transactionAuthor = localMemberID.uuidString
        observe()
    }

    public static func open(directory: URL, cloudIdentifier: String? = nil,
                            localMemberID: UUID) async throws -> BudgetRepository {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let model = try managedObjectModel()
        let container = NSPersistentCloudKitContainer(name: "Folki", managedObjectModel: model)
        var descriptions: [NSPersistentStoreDescription] = []
        for name in cloudIdentifier == nil ? ["private"] : ["private", "shared"] {
            let description = NSPersistentStoreDescription(url: directory.appendingPathComponent("\(name).sqlite"))
            description.shouldMigrateStoreAutomatically = true
            description.shouldInferMappingModelAutomatically = true
            description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
            description.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
            if let cloudIdentifier {
                let options = NSPersistentCloudKitContainerOptions(containerIdentifier: cloudIdentifier)
                options.databaseScope = name == "private" ? .private : .shared
                description.cloudKitContainerOptions = options
            }
            descriptions.append(description)
        }
        // Load sequentially so a single error cannot resume a continuation twice.
        container.persistentStoreDescriptions = []
        for description in descriptions {
            container.persistentStoreDescriptions = [description]
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                container.loadPersistentStores { _, error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                }
            }
        }
        container.persistentStoreDescriptions = descriptions
        return BudgetRepository(container: container, cloudIdentifier: cloudIdentifier, localMemberID: localMemberID)
    }

    static func managedObjectModel(version: String? = nil) throws -> NSManagedObjectModel {
        let root: URL
        if let compiled = Bundle.module.url(forResource: "FolkiDuo", withExtension: "momd") {
            root = compiled
        } else {
            #if os(macOS)
            // Classic command-line SwiftPM copies raw models; iOS/Xcode compiles them.
            root = try compileCommandLineModel()
            #else
            throw LedgerError.corruptStore
            #endif
        }
        let url = version.map { root.appendingPathComponent("\($0).mom") } ?? root
        guard let model = NSManagedObjectModel(contentsOf: url) else { throw LedgerError.corruptStore }
        return model
    }

    #if os(macOS)
    private static var commandLineModelURL: URL?

    private static func compileCommandLineModel() throws -> URL {
        if let commandLineModelURL { return commandLineModelURL }
        guard let source = Bundle.module.url(forResource: "FolkiDuo", withExtension: "xcdatamodeld") else {
            throw LedgerError.corruptStore
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FolkiModel-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let output = directory.appendingPathComponent("FolkiDuo.momd")
        do {
            let compiler = Process()
            compiler.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            compiler.arguments = ["momc", source.path, output.path]
            let diagnostics = Pipe()
            compiler.standardOutput = diagnostics
            compiler.standardError = diagnostics
            try compiler.run()
            _ = diagnostics.fileHandleForReading.readDataToEndOfFile()
            compiler.waitUntilExit()
            guard compiler.terminationStatus == 0 else { throw LedgerError.corruptStore }
            commandLineModelURL = output
            return output
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }
    #endif

    private func fetch(_ entity: String, predicate: NSPredicate? = nil, stores: [NSPersistentStore]? = nil) throws -> [NSManagedObject] {
        let request = NSFetchRequest<NSManagedObject>(entityName: entity)
        request.predicate = predicate
        request.affectedStores = stores
        return try context.fetch(request)
    }
    private func object(_ entity: String, id: UUID) throws -> NSManagedObject {
        let results = try fetch(entity, predicate: NSPredicate(format: "id == %@", id as NSUUID))
        guard results.count == 1, let first = results.first else { throw LedgerError.missingRecord }
        return first
    }
    private func insert(_ entity: String, id: UUID = UUID(), household: NSManagedObject? = nil) -> NSManagedObject {
        let object = NSEntityDescription.insertNewObject(forEntityName: entity, into: context)
        object.setValue(id, forKey: "id")
        if let household {
            context.assign(object, to: household.objectID.persistentStore!)
            object.setValue(household, forKey: "household")
        } else { context.assign(object, to: privateStore) }
        return object
    }

    private func households(in scope: BudgetScope) throws -> [NSManagedObject] {
        try fetch("Household", predicate: NSPredicate(format: "scope == %@", scope.rawValue),
                  stores: scope == .personal ? [privateStore] : nil)
    }

    public func load(asOf date: Date, scope: BudgetScope = .family) throws -> StoredBudget? {
        let households = try households(in: scope)
        guard households.count <= 1 else { throw LedgerError.multipleHouseholds }
        guard let household = households.first else { return nil }
        try validateGoalTransfers(household: household, asOf: date)
        let householdID: UUID = try household.required("id")
        let zone: String = try household.required("timeZone")
        let periods = try fetch("BudgetPeriod", predicate: NSPredicate(format: "household == %@", household))
        let sorted = try periods.map { object -> (NSManagedObject, BudgetPeriod) in
            let month: Date = try object.required("month")
            return (object, try BudgetPeriod(monthContaining: month, timeZoneIdentifier: zone))
        }.sorted { $0.1.start > $1.1.start }
        guard let selected = sorted.first(where: { $0.1.contains(date) }) ?? sorted.first else { return nil }
        let periodObject = selected.0
        let periodID: UUID = try periodObject.required("id")
        let members = try fetch("Member", predicate: NSPredicate(format: "household == %@", household)).map {
            Member(id: try $0.required("id"), name: try $0.required("name"))
        }.sorted { $0.id.uuidString < $1.id.uuidString }
        guard members.count == (scope == .personal ? 1 : 2) else { throw LedgerError.corruptStore }
        let reserves = try fetch("Reserve", predicate: NSPredicate(format: "period == %@", periodObject)).map {
            ProtectedReserve(id: try $0.required("id"), name: try $0.required("name"),
                             openingAmount: Money(minorUnits: try $0.required("openingAmount")))
        }
        let transactionObjects = try fetch("Transaction", predicate: NSPredicate(format: "period == %@", periodObject))
        var records: [LedgerRecord] = try transactionObjects.map { try decode($0) }
        records.sort {
            if $0.transaction.date == $1.transaction.date { return $0.id.uuidString < $1.id.uuidString }
            return $0.transaction.date < $1.transaction.date
        }
        let currency: String = try periodObject.required("currency")
        guard currency == "RUB", Set(records.map(\.id)).count == records.count else { throw LedgerError.corruptStore }
        let snapshot = HouseholdSnapshot(id: householdID, period: selected.1,
            monthlyFreePlan: Money(minorUnits: try periodObject.required("monthlyPlan")),
            openingFunds: Money(minorUnits: try periodObject.required("openingFunds")),
            reserves: reserves, transactions: records.map(\.transaction))
        return StoredBudget(snapshot: snapshot, periodID: periodID, members: members, records: records, scope: scope)
    }

    public func history(scope: BudgetScope = .family) throws -> [LedgerRecord] {
        let households = try households(in: scope)
        guard households.count <= 1 else { throw LedgerError.multipleHouseholds }
        guard let household = households.first else { return [] }
        let objects = try fetch("Transaction", predicate: NSPredicate(format: "household == %@", household))
        return try objects.map { try decode($0) }.sorted { $0.transaction.date < $1.transaction.date }
    }

    public func createPlan(monthlyPlan: Money, available: Money, asOf now: Date,
                           timeZone: String = TimeZone.current.identifier,
                           reserves: [ProtectedReserve] = [], scope: BudgetScope = .family) throws {
        try writable()
        guard monthlyPlan.currency == .rub, available.currency == .rub,
              monthlyPlan.minorUnits > 0, available.minorUnits >= 0 else { throw BudgetError.invalidPlan }
        do {
            let households = try households(in: scope)
            guard households.count <= 1 else { throw LedgerError.multipleHouseholds }
            let household: NSManagedObject
            if let existing = households.first { household = existing }
            else {
                household = insert("Household")
                household.setValue(scope.rawValue, forKey: "scope")
                household.setValue(scope == .personal ? "Личный бюджет" : "Семейный бюджет", forKey: "name")
                household.setValue(timeZone, forKey: "timeZone")
                household.setValue(now, forKey: "createdAt")
                try context.obtainPermanentIDs(for: [household])
                for (id, name) in (scope == .personal ? [(localMemberID, "Я")] : [(localMemberID, "Я"), (UUID(), "Партнёр")]) {
                    let member = insert("Member", id: id, household: household)
                    member.setValue(name, forKey: "name")
                    if id == localMemberID { member.setValue(cloudIdentity, forKey: "cloudIdentity") }
                }
            }
            let zone: String = try household.required("timeZone")
            guard let store = household.objectID.persistentStore,
                  container.canModifyManagedObjects(in: store) else { throw LedgerError.accessDenied }
            let period = try BudgetPeriod(monthContaining: now, timeZoneIdentifier: zone)
            let goalReserves = try goals(scope: scope, asOf: now).map {
                ProtectedReserve(id: $0.id, name: $0.name, openingAmount: $0.balance)
            }
            let allReserves = reserves + goalReserves
            _ = try DailyBudgetCalculator.calculate(HouseholdSnapshot(period: period,
                monthlyFreePlan: monthlyPlan, openingFunds: available, reserves: allReserves), asOf: now)
            let existing = try fetch("BudgetPeriod", predicate: NSPredicate(format: "household == %@ AND month == %@", household, period.start as NSDate))
            guard existing.isEmpty else { throw LedgerError.existingPeriod }
            let object = insert("BudgetPeriod", household: household)
            object.setValue(period.start, forKey: "month")
            object.setValue(monthlyPlan.minorUnits, forKey: "monthlyPlan")
            object.setValue(available.minorUnits, forKey: "openingFunds")
            object.setValue("RUB", forKey: "currency")
            for reserve in allReserves {
                let item = insert("Reserve", id: reserve.id, household: household)
                item.setValue(object, forKey: "period")
                item.setValue(reserve.name, forKey: "name")
                item.setValue(reserve.openingAmount.minorUnits, forKey: "openingAmount")
            }
            try commit()
        } catch { context.rollback(); throw error }
    }

    /// A planning target, not a cash deposit. Keep funds, reserves and ledger entries unchanged.
    public func updateSpendingLimit(_ limit: Money, in budget: StoredBudget, asOf now: Date) throws {
        try writable()
        guard limit.currency == .rub, limit.minorUnits > 0, budget.snapshot.period.contains(now) else {
            throw BudgetError.invalidPlan
        }
        do {
            let period = try object("BudgetPeriod", id: budget.periodID)
            guard let household = period.value(forKey: "household") as? NSManagedObject else { throw LedgerError.corruptStore }
            try validateScope(budget, household: household)
            guard let store = period.objectID.persistentStore, container.canModifyManagedObjects(in: store),
                  container.canUpdateRecord(forManagedObjectWith: period.objectID) else { throw LedgerError.accessDenied }
            let current: Int64 = try period.required("monthlyPlan")
            guard current == budget.snapshot.monthlyFreePlan.minorUnits else { throw LedgerError.conflict }
            period.setValue(limit.minorUnits, forKey: "monthlyPlan")
            guard let updated = try load(asOf: now, scope: budget.scope), updated.periodID == budget.periodID else {
                throw LedgerError.conflict
            }
            _ = try DailyBudgetCalculator.calculate(updated.snapshot, asOf: now)
            try commit()
        } catch { context.rollback(); throw error }
    }

    public func save(_ record: LedgerRecord, in budget: StoredBudget, expectedRevision: UUID?, asOf now: Date) throws {
        try writable()
        guard [.expense, .refund, .income].contains(record.transaction.kind) else { throw BudgetError.invalidTransaction }
        _ = try LedgerRules.replacing(record, in: budget, asOf: now)
        do {
            if expectedRevision == nil {
                guard record.transaction.authorID == (try authorID(in: budget)) else { throw LedgerError.invalidMember }
            }
            let period = try object("BudgetPeriod", id: budget.periodID)
            guard let household = period.value(forKey: "household") as? NSManagedObject else { throw LedgerError.corruptStore }
            try validateScope(budget, household: household)
            if case .reserve(let reserveID) = record.transaction.funding,
               try goals(scope: budget.scope, asOf: now).contains(where: { $0.id == reserveID }) {
                throw BudgetError.invalidTransaction // Savings move only through paired contribution events.
            }
            let matches = try fetch("Transaction", predicate: NSPredicate(format: "id == %@", record.id as NSUUID))
            let object: NSManagedObject
            if let existing = matches.first {
                guard matches.count == 1, let expectedRevision,
                      existing.value(forKey: "revision") as? UUID == expectedRevision,
                      existing.value(forKey: "period") as? NSManagedObject == period else { throw LedgerError.conflict }
                object = existing
            } else {
                guard expectedRevision == nil else { throw LedgerError.conflict }
                object = insert("Transaction", id: record.id, household: household)
                object.setValue(period, forKey: "period")
            }
            guard let store = period.objectID.persistentStore,
                  container.canModifyManagedObjects(in: store),
                  container.canUpdateRecord(forManagedObjectWith: object.objectID) else { throw LedgerError.accessDenied }
            if expectedRevision != nil {
                guard object.value(forKey: "authorID") as? UUID == record.transaction.authorID else { throw LedgerError.invalidMember }
            }
            encode(record, into: object, updatedAt: now)
            // Re-read the whole period, including imports, before accepting a write.
            guard let current = try load(asOf: now, scope: budget.scope), current.periodID == budget.periodID else { throw LedgerError.conflict }
            _ = try DailyBudgetCalculator.calculate(current.snapshot, asOf: now)
            try commit()
        } catch { context.rollback(); throw error }
    }

    public func goals(scope: BudgetScope = .family, asOf now: Date = .now) throws -> [SavingsGoalSnapshot] {
        let roots = try households(in: scope)
        guard roots.count <= 1 else { throw LedgerError.multipleHouseholds }
        guard let household = roots.first else { return [] }
        try validateGoalTransfers(household: household, asOf: now)
        let goals = try fetch("Goal", predicate: NSPredicate(format: "household == %@", household))
        let contributions = try fetch("GoalContribution", predicate: NSPredicate(format: "household == %@ AND date <= %@", household, now as NSDate))
        return try goals.map { goal in
            let id: UUID = try goal.required("id")
            var balance = Money(minorUnits: 0)
            for contribution in contributions where contribution.value(forKey: "goalID") as? UUID == id {
                let amount = Money(minorUnits: try contribution.required("amount"))
                let direction: String = try contribution.required("direction")
                guard amount.minorUnits > 0, ["contribution", "withdrawal"].contains(direction) else { throw LedgerError.corruptStore }
                balance = try direction == "contribution" ? balance.adding(amount) : balance.subtracting(amount)
            }
            guard balance.minorUnits >= 0 else { throw LedgerError.corruptStore }
            let target = Money(minorUnits: try goal.required("target"))
            guard target.minorUnits > 0 else { throw LedgerError.corruptStore }
            return SavingsGoalSnapshot(id: id, name: try goal.required("name"), target: target, balance: balance)
        }.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    public func createGoal(name: String, target: Money, in budget: StoredBudget, asOf now: Date) throws {
        try writable()
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, target.currency == .rub, target.minorUnits > 0,
              budget.snapshot.period.contains(now) else { throw BudgetError.invalidAmount }
        do {
            let household = try object("Household", id: budget.snapshot.id)
            try validateScope(budget, household: household)
            guard let store = household.objectID.persistentStore, container.canModifyManagedObjects(in: store) else { throw LedgerError.accessDenied }
            let period = try object("BudgetPeriod", id: budget.periodID)
            guard period.value(forKey: "household") as? NSManagedObject == household else { throw LedgerError.accessDenied }
            let id = UUID()
            let goal = insert("Goal", id: id, household: household)
            goal.setValue(name, forKey: "name")
            goal.setValue(target.minorUnits, forKey: "target")
            let reserve = insert("Reserve", id: id, household: household)
            reserve.setValue(name, forKey: "name")
            reserve.setValue(Int64(0), forKey: "openingAmount")
            reserve.setValue(period, forKey: "period")
            try commit()
        } catch { context.rollback(); throw error }
    }

    private func validateGoalTransfers(household: NSManagedObject, asOf now: Date) throws {
        let goalIDs = Set(try fetch("Goal", predicate: NSPredicate(format: "household == %@", household))
            .map { try $0.required("id") as UUID })
        let contributions = try fetch("GoalContribution", predicate: NSPredicate(format: "household == %@ AND date <= %@", household, now as NSDate))
        let transactions = try fetch("Transaction", predicate: NSPredicate(format: "household == %@ AND date <= %@", household, now as NSDate))
        var paired = Set<UUID>()
        for contribution in contributions {
            let id: UUID = try contribution.required("id")
            let goalID: UUID = try contribution.required("goalID")
            let amount: Int64 = try contribution.required("amount")
            let direction: String = try contribution.required("direction")
            let expectedKind = direction == "contribution" ? "reserveAllocation" : "reserveRelease"
            let matching = transactions.filter { $0.value(forKey: "id") as? UUID == id }
            guard amount > 0, ["contribution", "withdrawal"].contains(direction),
                  goalIDs.contains(goalID), paired.insert(id).inserted, matching.count == 1,
                  let transaction = matching.first,
                  transaction.value(forKey: "kind") as? String == expectedKind,
                  transaction.value(forKey: "funding") as? String == "reserve",
                  transaction.value(forKey: "reserveID") as? UUID == goalID,
                  transaction.value(forKey: "amount") as? Int64 == amount,
                  transaction.value(forKey: "authorID") as? UUID == contribution.value(forKey: "memberID") as? UUID,
                  transaction.value(forKey: "date") as? Date == contribution.value(forKey: "date") as? Date,
                  transaction.value(forKey: "tombstone") as? Bool == false else { throw LedgerError.corruptStore }
        }
        for transaction in transactions {
            guard let reserveID = transaction.value(forKey: "reserveID") as? UUID, goalIDs.contains(reserveID) else { continue }
            let id: UUID = try transaction.required("id")
            guard paired.contains(id) else { throw LedgerError.corruptStore }
        }
    }

    /// One save contains both the savings event and its matching reserve transfer.
    public func transferToGoal(_ id: UUID, amount: Money, withdrawal: Bool, in budget: StoredBudget, asOf now: Date, operationID: UUID = UUID()) throws {
        try writable()
        guard amount.currency == .rub, amount.minorUnits > 0 else { throw BudgetError.invalidAmount }
        do {
            let household = try object("Household", id: budget.snapshot.id)
            try validateScope(budget, household: household)
            guard let store = household.objectID.persistentStore, container.canModifyManagedObjects(in: store),
                  let current = try load(asOf: now, scope: budget.scope), current.periodID == budget.periodID else { throw LedgerError.accessDenied }
            let author = try authorID(in: current)
            let existing = try fetch("Transaction", predicate: NSPredicate(format: "id == %@", operationID as NSUUID))
            if let previous = existing.first {
                guard existing.count == 1, previous.value(forKey: "household") as? NSManagedObject == household,
                      previous.value(forKey: "reserveID") as? UUID == id,
                      previous.value(forKey: "amount") as? Int64 == amount.minorUnits,
                      previous.value(forKey: "authorID") as? UUID == author,
                      previous.value(forKey: "kind") as? String == (withdrawal ? "reserveRelease" : "reserveAllocation") else { throw LedgerError.conflict }
                return
            }
            guard let goal = try goals(scope: budget.scope, asOf: now).first(where: { $0.id == id }) else { throw LedgerError.missingRecord }
            if withdrawal && amount.minorUnits > goal.balance.minorUnits { throw BudgetError.insufficientReserve }
            if !withdrawal {
                let available = try DailyBudgetCalculator.calculate(current.snapshot, asOf: now).monthlyRemaining
                guard amount.minorUnits <= available.minorUnits else { throw BudgetError.insufficientReserve }
            }
            let period = try object("BudgetPeriod", id: current.periodID)
            let record = LedgerRecord(transaction: TransactionSnapshot(id: operationID, amount: amount,
                kind: withdrawal ? .reserveRelease : .reserveAllocation, funding: .reserve(id),
                date: now, authorID: author, payerID: author),
                title: withdrawal ? "Из накоплений: \(goal.name)" : "В накопления: \(goal.name)", symbol: "arrow.left.arrow.right")
            _ = try LedgerRules.replacing(record, in: current, asOf: now)
            let transaction = insert("Transaction", id: record.id, household: household)
            transaction.setValue(period, forKey: "period")
            encode(record, into: transaction, updatedAt: now)
            let contribution = insert("GoalContribution", id: record.id, household: household)
            contribution.setValue(id, forKey: "goalID")
            contribution.setValue(author, forKey: "memberID")
            contribution.setValue(amount.minorUnits, forKey: "amount")
            contribution.setValue(withdrawal ? "withdrawal" : "contribution", forKey: "direction")
            contribution.setValue(now, forKey: "date")
            try commit()
        } catch { context.rollback(); throw error }
    }

    public func authorID(in budget: StoredBudget) throws -> UUID {
        if cloudIdentifier == nil {
            guard budget.members.contains(where: { $0.id == localMemberID }) else { throw LedgerError.invalidMember }
            return localMemberID
        }
        if cloudIdentity == nil, !accountLocked,
           budget.members.contains(where: { $0.id == localMemberID }) { return localMemberID }
        guard let cloudIdentity, !accountLocked else { throw LedgerError.accessDenied }
        let household = try object("Household", id: budget.snapshot.id)
        let members = try fetch("Member", predicate: NSPredicate(format: "household == %@", household))
        if let own = members.first(where: { $0.value(forKey: "cloudIdentity") as? String == cloudIdentity }) {
            return try own.required("id")
        }
        // A locally created budget keeps its author when iCloud is first enabled.
        let candidate = members.first(where: { $0.value(forKey: "id") as? UUID == localMemberID })
            ?? (household.objectID.persistentStore == sharedStore ? members.first(where: { $0.value(forKey: "cloudIdentity") == nil }) : nil)
        guard let candidate else { throw LedgerError.invalidMember }
        candidate.setValue(cloudIdentity, forKey: "cloudIdentity")
        try commit()
        return try candidate.required("id")
    }

    private func writable() throws {
        guard !accountLocked else { throw LedgerError.accountChanged }
    }
    private func commit() throws {
        let changed = Array(context.insertedObjects.union(context.updatedObjects).union(context.deletedObjects))
        try context.save()
        if cloudIdentifier != nil {
            let stores = Set(changed.compactMap { $0.objectID.persistentStore?.identifier })
            exports.saved(stores: stores)
        }
        pendingExport = !exports.pending.isEmpty
        persistSyncMetadata()
        changeToken = UUID()
    }
    private func persistSyncMetadata() {
        var metadata = container.persistentStoreCoordinator.metadata(for: privateStore)
        metadata["FolkiPendingStores"] = Array(exports.pending)
        metadata["FolkiLastCloudUpdate"] = lastCloudUpdate
        container.persistentStoreCoordinator.setMetadata(metadata, for: privateStore)
    }
    private func decode(_ object: NSManagedObject) throws -> LedgerRecord {
        let kindString: String = try object.required("kind")
        let kind: TransactionKind
        switch kindString {
        case "expense": kind = .expense
        case "refund": kind = .refund
        case "income": kind = .income
        case "reserveAllocation": kind = .reserveAllocation
        case "reserveRelease": kind = .reserveRelease
        default: throw LedgerError.corruptStore
        }
        let fundingString: String = try object.required("funding")
        let funding: BudgetFunding
        switch fundingString {
        case "flexible": funding = .flexible
        case "unallocated": funding = .unallocated
        case "reserve": funding = .reserve(try object.required("reserveID"))
        default: throw LedgerError.corruptStore
        }
        let categoryString: String = try object.required("category")
        guard let category = ExpenseCategory(rawValue: categoryString) else { throw LedgerError.corruptStore }
        return LedgerRecord(transaction: TransactionSnapshot(id: try object.required("id"),
            amount: Money(minorUnits: try object.required("amount")), kind: kind, funding: funding,
            date: try object.required("date"), authorID: try object.required("authorID"),
            payerID: try object.required("payerID"), isDeleted: try object.required("tombstone")),
            title: try object.required("title"), category: category, revision: try object.required("revision"))
    }
    private func encode(_ record: LedgerRecord, into object: NSManagedObject, updatedAt: Date) {
        let entry = record.transaction
        let kind: String = switch entry.kind {
        case .expense: "expense"; case .refund: "refund"; case .income: "income"
        case .reserveAllocation: "reserveAllocation"; case .reserveRelease: "reserveRelease"
        }
        let funding: String
        var reserveID: UUID?
        switch entry.funding {
        case .flexible: funding = "flexible"
        case .unallocated: funding = "unallocated"
        case .reserve(let id): funding = "reserve"; reserveID = id
        }
        let values: [String: Any] = ["amount": entry.amount.minorUnits, "kind": kind, "funding": funding,
            "date": entry.date, "authorID": entry.authorID, "payerID": entry.payerID,
            "title": record.title, "category": record.category.rawValue, "tombstone": entry.isDeleted,
            "revision": record.revision, "updatedAt": updatedAt]
        values.forEach { object.setValue($0.value, forKey: $0.key) }
        object.setValue(reserveID, forKey: "reserveID")
    }

    private func observe() {
        observers.append(NotificationCenter.default.addObserver(forName: .NSPersistentStoreRemoteChange,
            object: container.persistentStoreCoordinator, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.context.refreshAllObjects()
                    self.changeToken = UUID()
                }
            })
        guard cloudIdentifier != nil else { return }
        observers.append(NotificationCenter.default.addObserver(forName: NSPersistentCloudKitContainer.eventChangedNotification,
            object: container, queue: .main) { [weak self] notification in
                guard let event = notification.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                        as? NSPersistentCloudKitContainer.Event else { return }
                let snapshot = CloudEventSnapshot(event)
                Task { @MainActor [weak self] in self?.handle(snapshot) }
            })
        observers.append(NotificationCenter.default.addObserver(forName: .CKAccountChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.accountLocked = true
                self?.syncError = "Аккаунт iCloud изменился. Верните прежний Apple ID и перезапустите Folki."
                self?.changeToken = UUID()
            }
        })
    }
    private func handle(_ event: CloudEventSnapshot) {
        if event.type == NSPersistentCloudKitContainer.EventType.export.rawValue && event.endDate == nil {
            exports.started(id: event.identifier, store: event.storeIdentifier)
        }
        guard let end = event.endDate else { return }
        if event.succeeded {
            syncError = nil
            if event.type == NSPersistentCloudKitContainer.EventType.import.rawValue || event.type == NSPersistentCloudKitContainer.EventType.export.rawValue { lastCloudUpdate = end }
            if event.type == NSPersistentCloudKitContainer.EventType.export.rawValue {
                exports.finished(id: event.identifier, store: event.storeIdentifier, succeeded: true)
                pendingExport = !exports.pending.isEmpty
            }
            persistSyncMetadata()
        } else {
            if event.type == NSPersistentCloudKitContainer.EventType.export.rawValue { exports.finished(id: event.identifier, store: event.storeIdentifier, succeeded: false) }
            syncError = "Не удалось выполнить обмен с iCloud. Записи сохранены на iPhone; проверьте аккаунт, доступ и сеть."
        }
        changeToken = UUID()
    }
    public func verifyAccount() async {
        guard let cloudIdentifier else { return }
        do {
            let cloud = CKContainer(identifier: cloudIdentifier)
            guard try await cloud.accountStatus() == .available else { throw LedgerError.accessDenied }
            let identity = try await cloud.userRecordID().recordName
            let previous = container.persistentStoreCoordinator.metadata(for: privateStore)["FolkiCloudIdentity"] as? String
            guard previous == nil || previous == identity else { throw LedgerError.accountChanged }
            cloudIdentity = identity
            var metadata = container.persistentStoreCoordinator.metadata(for: privateStore)
            metadata["FolkiCloudIdentity"] = identity
            container.persistentStoreCoordinator.setMetadata(metadata, for: privateStore)
            syncError = nil
        } catch {
            if (error as? LedgerError) == .accountChanged { accountLocked = true }
            if let cloudError = error as? CKError,
               [.networkUnavailable, .networkFailure, .serviceUnavailable].contains(cloudError.code) {
                cloudIdentity = container.persistentStoreCoordinator.metadata(for: privateStore)["FolkiCloudIdentity"] as? String
            }
            syncError = "iCloud недоступен или изменился Apple ID. Локальные записи сохранены."
        }
        changeToken = UUID()
    }

    public func sharingRootID(householdID: UUID) throws -> NSManagedObjectID {
        try sharingRoot(householdID: householdID).objectID
    }
    private func sharingRoot(householdID: UUID) throws -> NSManagedObject {
        let household = try object("Household", id: householdID)
        guard household.value(forKey: "scope") as? String == BudgetScope.family.rawValue else {
            throw LedgerError.privateBudgetCannotBeShared
        }
        return household
    }
    private func validateScope(_ budget: StoredBudget, household: NSManagedObject) throws {
        guard household.value(forKey: "id") as? UUID == budget.snapshot.id,
              household.value(forKey: "scope") as? String == budget.scope.rawValue,
              budget.scope != .personal || household.objectID.persistentStore == privateStore else {
            throw LedgerError.accessDenied
        }
    }

    public func share(householdID: UUID) async throws -> CKShare {
        try writable()
        guard cloudIdentifier != nil, cloudIdentity != nil else { throw LedgerError.cloudNotConfigured }
        let household = try sharingRoot(householdID: householdID)
        if let share = try container.fetchShares(matching: [household.objectID])[household.objectID] { return share }
        let share: CKShare = try await withCheckedThrowingContinuation { continuation in
            container.share([household], to: nil) { _, share, _, error in
                if let error { continuation.resume(throwing: error) }
                else if let share { continuation.resume(returning: share) }
                else { continuation.resume(throwing: LedgerError.unavailable) }
            }
        }
        share.publicPermission = .none
        share[CKShare.SystemFieldKey.title] = "Общий бюджет Folki" as CKRecordValue
        try await persist(share: share, store: household.objectID.persistentStore!)
        return share
    }
    public func persist(share: CKShare, store: NSPersistentStore) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            container.persistUpdatedShare(share, in: store) { _, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
        changeToken = UUID()
    }
    public func accept(_ metadata: CKShare.Metadata) async throws {
        try writable()
        guard metadata.containerIdentifier == cloudIdentifier, cloudIdentity != nil,
              let sharedStore else { throw LedgerError.cloudNotConfigured }
        // Do not silently replace a budget with an invitation to a different household.
        let households = try households(in: .family)
        if let household = households.first {
            let existing = try container.fetchShares(matching: [household.objectID])[household.objectID]
            guard households.count == 1, existing?.recordID == metadata.share.recordID else { throw LedgerError.multipleHouseholds }
            return
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            container.acceptShareInvitations(from: [metadata], into: sharedStore) { _, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
        changeToken = UUID()
    }
    public func reportSharingError() {
        syncError = "Не удалось изменить общий доступ. Проверьте iCloud и попробуйте снова."
    }
    public func sharingStopped() {
        context.refreshAllObjects()
        syncError = "Общий доступ отключён. Проверьте статус пространства."
        changeToken = UUID()
    }
    public func close() throws {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        for store in container.persistentStoreCoordinator.persistentStores {
            try container.persistentStoreCoordinator.remove(store)
        }
    }
}

private extension NSManagedObject {
    func required<T>(_ key: String) throws -> T {
        guard let value = value(forKey: key) as? T else { throw LedgerError.corruptStore }
        return value
    }
}
