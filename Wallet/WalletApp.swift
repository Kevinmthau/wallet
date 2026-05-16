import SwiftUI

@main
struct WalletApp: App {
    private let persistenceController: PersistenceController
    @State private var cardStore: CardStore
    @State private var syncMonitor: CloudKitSyncMonitor
    @State private var persistentStoreLoadState: PersistentStoreLoadState

    init() {
        let persistenceController = PersistenceController.shared
        self.persistenceController = persistenceController

        let context = persistenceController.container.viewContext
        _cardStore = State(initialValue: CardStore(context: context))
        _syncMonitor = State(initialValue: CloudKitSyncMonitor(
            container: persistenceController.container,
            cloudKitEnabled: persistenceController.cloudKitEnabled
        ))
        _persistentStoreLoadState = State(initialValue: persistenceController.loadState)
    }

    var body: some Scene {
        WindowGroup {
            WalletRootView(
                persistenceController: persistenceController,
                cardStore: cardStore,
                syncMonitor: syncMonitor,
                persistentStoreLoadState: persistentStoreLoadState
            )
        }
    }
}

private struct WalletRootView: View {
    let persistenceController: PersistenceController
    let cardStore: CardStore
    let syncMonitor: CloudKitSyncMonitor
    let persistentStoreLoadState: PersistentStoreLoadState

    var body: some View {
        Group {
            if let loadFailure = persistentStoreLoadState.loadFailure {
                PersistentStoreFailureView(loadFailure: loadFailure)
            } else {
                CardListView()
                    .environment(\.managedObjectContext, persistenceController.container.viewContext)
                    .environment(cardStore)
                    .environment(syncMonitor)
            }
        }
    }
}

private struct PersistentStoreFailureView: View {
    let loadFailure: PersistentStoreLoadFailure

    var body: some View {
        ContentUnavailableView {
            Label("Wallet Cannot Open", systemImage: "exclamationmark.triangle")
        } description: {
            VStack(spacing: 8) {
                Text(loadFailure.errorDescription ?? "Wallet could not open its local database.")
                Text(loadFailure.recoverySuggestion ?? "Restart Wallet and try again.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            .padding(.horizontal)
        }
    }
}
