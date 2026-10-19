import Foundation
import Testing
@testable import FolkiDuoPersistence

struct ExportTrackerTests {
    @Test func exportDoesNotAcknowledgeNewerWritesOrAnotherStore() {
        var tracker = ExportTracker()
        tracker.saved(stores: ["private", "shared"])
        let first = UUID()
        tracker.started(id: first, store: "private")
        tracker.saved(stores: ["private"])
        tracker.finished(id: first, store: "private", succeeded: true)
        #expect(tracker.pending == Set(["private", "shared"]))
        let second = UUID()
        tracker.started(id: second, store: "shared")
        tracker.finished(id: second, store: "shared", succeeded: true)
        #expect(tracker.pending == Set(["private"]))
    }
    @Test func failedOrUnobservedExportKeepsPendingWrites() {
        var tracker = ExportTracker()
        tracker.saved(stores: ["private"])
        let id = UUID()
        tracker.started(id: id, store: "private")
        tracker.finished(id: id, store: "private", succeeded: false)
        tracker.finished(id: UUID(), store: "private", succeeded: true)
        #expect(tracker.pending == Set(["private"]))
    }
}
