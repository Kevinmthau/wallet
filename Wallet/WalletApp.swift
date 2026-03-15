import SwiftUI

@main
struct WalletApp: App {
    let persistenceController = PersistenceController.shared
    @State private var cardStore: CardStore
    @State private var syncMonitor: SyncStatusMonitor

    init() {
        let persistence = PersistenceController.shared
        let context = persistence.container.viewContext
        _cardStore = State(initialValue: CardStore(context: context))
        _syncMonitor = State(initialValue: SyncStatusMonitor(persistenceController: persistence))
    }

    var body: some Scene {
        WindowGroup {
            CardListView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
                .environment(cardStore)
                .environment(syncMonitor)
        }
    }
}
