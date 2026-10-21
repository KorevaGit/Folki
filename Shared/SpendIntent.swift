import AppIntents
import Foundation

/// "Записать трату": opens Folki on the spend sheet. Used by the Action Button, Control Center and Shortcuts.
struct SpendIntent: AppIntent {
    static let title: LocalizedStringResource = "Записать трату"
    static let description = IntentDescription("Открывает Folki сразу на вводе траты")

    func perform() async throws -> some IntentResult & OpensIntent {
        .result(opensIntent: OpenURLIntent(FolkiLinks.spend))
    }
}
