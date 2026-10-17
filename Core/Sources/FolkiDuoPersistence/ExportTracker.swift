import Foundation

/// An export can acknowledge only writes present when that store's export began.
struct ExportTracker {
    var pending: Set<String> = []
    private var generations: [String: Int] = [:]
    private var inFlight: [UUID: (store: String, generation: Int)] = [:]
    mutating func saved(stores: Set<String>) {
        for store in stores {
            generations[store, default: 0] += 1
            pending.insert(store)
        }
    }
    mutating func started(id: UUID, store: String) {
        inFlight[id] = (store, generations[store, default: 0])
    }
    mutating func finished(id: UUID, store: String, succeeded: Bool) {
        guard let export = inFlight.removeValue(forKey: id), succeeded,
              export.store == store, export.generation == generations[store, default: 0] else { return }
        pending.remove(store)
    }
}
