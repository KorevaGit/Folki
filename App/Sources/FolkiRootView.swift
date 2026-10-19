import SwiftUI

/// One screen: the budget. Tasks and the shopping list will become their own sections later.
struct FolkiRootView: View {
    let personal: BudgetSession
    let family: BudgetSession
    @State private var selectedDay: Date?

    var body: some View {
        BudgetRootView(personal: personal, family: family, selectedDay: $selectedDay)
            .tint(Color.folkiAccent)
    }
}
