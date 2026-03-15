import SwiftUI

@main
struct WalletApp: App {
    let persistenceController = PersistenceController.shared
    @State private var cardStore: CardStore

    init() {
        let context = PersistenceController.shared.container.viewContext
        _cardStore = State(initialValue: CardStore(context: context))
    }

    var body: some Scene {
        WindowGroup {
            CardListView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
                .environment(cardStore)
        }
    }
}
