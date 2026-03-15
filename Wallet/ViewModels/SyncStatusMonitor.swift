import Foundation
import CoreData
import CloudKit
import Combine

/// Monitors CloudKit sync events and exposes current sync status for the UI.
@MainActor
@Observable
class SyncStatusMonitor {
    enum SyncStatus: Equatable {
        case idle
        case syncing
        case synced
        case noAccount
        case error(String)
    }

    private(set) var status: SyncStatus = .idle
    private var cancellables = Set<AnyCancellable>()
    private var syncTimeoutTask: Task<Void, Never>?

    init(persistenceController: PersistenceController) {
        observeCloudKitEvents(persistenceController: persistenceController)
        observeRemoteChanges(persistenceController: persistenceController)
        checkAccountStatus()
    }

    private func observeCloudKitEvents(persistenceController: PersistenceController) {
        // NSPersistentCloudKitContainer posts these notifications during import/export
        NotificationCenter.default.publisher(for: NSNotification.Name("NSPersistentCloudKitContainerEventChanged"), object: nil)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                self?.handleCloudKitEvent(notification)
            }
            .store(in: &cancellables)
    }

    private func observeRemoteChanges(persistenceController: PersistenceController) {
        persistenceController.remoteChangePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                self?.status = .synced
                self?.scheduleSyncTimeout()
            }
            .store(in: &cancellables)
    }

    private func handleCloudKitEvent(_ notification: Notification) {
        // NSPersistentCloudKitContainer.Event is available via the notification's userInfo
        // The event object is stored under the "event" key
        guard let event = notification.userInfo?["event"] as? NSPersistentCloudKitContainer.Event else {
            return
        }

        if event.endDate == nil {
            // Event is in progress
            status = .syncing
            syncTimeoutTask?.cancel()
        } else if let error = event.error {
            let nsError = error as NSError
            // CKErrorNotAuthenticated = 9 means no iCloud account
            if nsError.domain == "CKErrorDomain" && nsError.code == 9 {
                status = .noAccount
            } else {
                AppLogger.data.error("SyncStatusMonitor: CloudKit sync error: \(error.localizedDescription)")
                status = .error(error.localizedDescription)
                scheduleSyncTimeout()
            }
        } else {
            // Event completed successfully
            status = .synced
            scheduleSyncTimeout()
        }
    }

    private func checkAccountStatus() {
        // Use CloudKit to check if the user has an iCloud account
        let container = CKContainer(identifier: "iCloud.com.kevinthau.wallet")
        container.accountStatus { [weak self] accountStatus, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let error {
                    AppLogger.data.error("SyncStatusMonitor: Account status check failed: \(error.localizedDescription)")
                    return
                }
                switch accountStatus {
                case .noAccount, .restricted:
                    self.status = .noAccount
                case .available:
                    // Account is available, sync will happen automatically
                    break
                default:
                    break
                }
            }
        }
    }

    /// Returns status to idle after a delay so the synced indicator doesn't persist forever.
    private func scheduleSyncTimeout() {
        syncTimeoutTask?.cancel()
        syncTimeoutTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            status = .idle
        }
    }
}
