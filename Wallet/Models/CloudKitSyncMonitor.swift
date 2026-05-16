import CloudKit
import CoreData
import Foundation
import Observation

/// Observes `NSPersistentCloudKitContainer` sync events and the iCloud account
/// status so import/export failures become visible instead of silently losing data.
@MainActor
@Observable
final class CloudKitSyncMonitor {
    enum Status: Equatable {
        case unknown
        case syncing
        case upToDate
        case accountUnavailable(String)
        case failed(String)
    }

    private(set) var status: Status = .unknown

    private var eventObserver: NSObjectProtocol?

    init(container: NSPersistentCloudKitContainer, cloudKitEnabled: Bool) {
        guard cloudKitEnabled else {
            status = .upToDate
            return
        }

        eventObserver = NotificationCenter.default.addObserver(
            forName: NSPersistentCloudKitContainer.eventChangedNotification,
            object: container,
            queue: .main
        ) { [weak self] notification in
            let event = notification.userInfo?[
                NSPersistentCloudKitContainer.eventNotificationUserInfoKey
            ] as? NSPersistentCloudKitContainer.Event
            Task { @MainActor in
                self?.handle(event)
            }
        }

        checkAccountStatus()
    }

    deinit {
        if let eventObserver {
            NotificationCenter.default.removeObserver(eventObserver)
        }
    }

    private func handle(_ event: NSPersistentCloudKitContainer.Event?) {
        guard let event else { return }

        // `.setup` only happens once at store load; sync health is import/export.
        guard event.type == .`import` || event.type == .export else { return }

        guard event.endDate != nil else {
            status = .syncing
            return
        }

        if let error = event.error {
            AppLogger.data.error(
                "CloudKitSyncMonitor: \(String(describing: event.type)) failed: \(error.localizedDescription), \((error as NSError).userInfo)"
            )
            status = .failed("iCloud sync failed: \(error.localizedDescription)")
        } else {
            AppLogger.data.debug("CloudKitSyncMonitor: \(String(describing: event.type)) succeeded")
            status = .upToDate
        }
    }

    private func checkAccountStatus() {
        CKContainer(identifier: "iCloud.com.kevinthau.wallet").accountStatus { [weak self] accountStatus, error in
            Task { @MainActor in
                guard let self else { return }

                if let error {
                    AppLogger.data.error(
                        "CloudKitSyncMonitor: account status check failed: \(error.localizedDescription)"
                    )
                }

                let message: String?
                switch accountStatus {
                case .available:
                    message = nil
                case .noAccount:
                    message = "Sign in to iCloud in Settings to sync your cards across devices."
                case .restricted:
                    message = "iCloud is restricted on this device, so your cards can't sync."
                case .couldNotDetermine, .temporarilyUnavailable:
                    message = "Wallet couldn't reach iCloud. Your cards may not be syncing."
                @unknown default:
                    message = nil
                }

                if let message {
                    AppLogger.data.error("CloudKitSyncMonitor: iCloud unavailable - \(message)")
                    self.status = .accountUnavailable(message)
                }
            }
        }
    }
}
