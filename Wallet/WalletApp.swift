import SwiftUI

@main
struct WalletApp: App {
    let persistenceController = PersistenceController.shared

    var body: some Scene {
        WindowGroup {
            CardListView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
        }
    }
}
