import CloudKit
import CoreData
import Foundation
import Observation

/// Observes `NSPersistentCloudKitContainer` sync events and the iCloud account
/// status so import/export failures become visible instead of silently losing data.
private final class NotificationObserver {
    private let token: NSObjectProtocol

    init(_ token: NSObjectProtocol) {
        self.token = token
    }

    deinit {
        NotificationCenter.default.removeObserver(token)
    }
}

@MainActor
@Observable
final class CloudKitSyncMonitor {
    enum Status: Equatable {
        case unknown
        case signedIn
        case syncing
        case upToDate
        case accountUnavailable(String)
        case failed(String)
    }

    struct LastEvent: Equatable {
        enum Direction: Equatable {
            case importChanges
            case exportChanges

            var logName: String {
                switch self {
                case .importChanges:
                    return "import"
                case .exportChanges:
                    return "export"
                }
            }
        }

        enum Outcome: Equatable {
            case started
            case succeeded
            case failed
        }

        let direction: Direction
        let outcome: Outcome
        let date: Date
        let message: String
    }

    private(set) var status: Status = .unknown
    private(set) var lastEvent: LastEvent?

    private var eventObserver: NotificationObserver?
    private let containerIdentifier: String
    private static let cloudKitDescriptionUserInfoKeys = [
        "CKErrorServerDescription",
        "CKErrorDescription",
        "ServerErrorDescription"
    ]

    init(
        container: NSPersistentCloudKitContainer,
        cloudKitEnabled: Bool,
        containerIdentifier: String = PersistenceController.cloudKitContainerIdentifier
    ) {
        self.containerIdentifier = containerIdentifier

        AppLogger.data.info(
            "CloudKitSyncMonitor: container=\(containerIdentifier), mirroringEnabled=\(cloudKitEnabled)"
        )

        guard cloudKitEnabled else {
            AppLogger.data.info("CloudKitSyncMonitor: CloudKit mirroring disabled")
            status = .upToDate
            return
        }

        let observerToken = NotificationCenter.default.addObserver(
            forName: NSPersistentCloudKitContainer.eventChangedNotification,
            object: container,
            queue: .main,
            using: { [weak self] notification in
                let event = notification.userInfo?[
                    NSPersistentCloudKitContainer.eventNotificationUserInfoKey
                ] as? NSPersistentCloudKitContainer.Event
                Task { @MainActor in
                    self?.handle(event)
                }
            }
        )
        eventObserver = NotificationObserver(observerToken)

        checkAccountStatus()
    }

    #if DEBUG
    func logCurrentState() {
        AppLogger.data.debug(
            "CloudKitSyncMonitor: current status=\(Self.statusDescription(self.status)), lastEvent=\(Self.lastEventDescription(self.lastEvent))"
        )
    }
    #endif

    private func handle(_ event: NSPersistentCloudKitContainer.Event?) {
        guard let event else { return }

        guard let direction = Self.direction(for: event.type) else {
            // `.setup` only happens once at store load; sync health is import/export.
            return
        }

        guard event.endDate != nil else {
            AppLogger.data.info("CloudKitSyncMonitor: \(direction.logName) started")
            lastEvent = LastEvent(
                direction: direction,
                outcome: .started,
                date: Date(),
                message: Self.startedMessage(for: direction)
            )
            status = .syncing
            return
        }

        if let error = event.error {
            let errorPayload = String(describing: (error as NSError).userInfo)
            AppLogger.data.error(
                "CloudKitSyncMonitor: \(direction.logName) failed: \(error.localizedDescription), \(errorPayload)"
            )
            let message = Self.failureMessage(for: error)
            lastEvent = LastEvent(
                direction: direction,
                outcome: .failed,
                date: event.endDate ?? Date(),
                message: message
            )
            status = .failed(message)
        } else {
            AppLogger.data.info("CloudKitSyncMonitor: \(direction.logName) succeeded")
            lastEvent = LastEvent(
                direction: direction,
                outcome: .succeeded,
                date: event.endDate ?? Date(),
                message: Self.succeededMessage(for: direction)
            )
            status = .upToDate
        }
    }

    private func checkAccountStatus() {
        CKContainer(identifier: containerIdentifier).accountStatus { [weak self] accountStatus, error in
            Task { @MainActor in
                guard let self else { return }

                if let error {
                    AppLogger.data.error(
                        "CloudKitSyncMonitor: account status check failed: \(error.localizedDescription)"
                    )
                }

                AppLogger.data.info(
                    "CloudKitSyncMonitor: account status=\(Self.accountStatusDescription(accountStatus))"
                )

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
                } else if case .unknown = self.status {
                    self.status = .signedIn
                }
            }
        }
    }

    private static func direction(
        for eventType: NSPersistentCloudKitContainer.EventType
    ) -> LastEvent.Direction? {
        switch eventType {
        case .`import`:
            return .importChanges
        case .export:
            return .exportChanges
        default:
            return nil
        }
    }

    private static func startedMessage(for direction: LastEvent.Direction) -> String {
        switch direction {
        case .importChanges:
            return "Importing cards from iCloud."
        case .exportChanges:
            return "Uploading cards to iCloud."
        }
    }

    private static func succeededMessage(for direction: LastEvent.Direction) -> String {
        switch direction {
        case .importChanges:
            return "Imported latest changes from iCloud."
        case .exportChanges:
            return "Uploaded latest changes to iCloud."
        }
    }

    static func failureMessage(for error: Error) -> String {
        "iCloud sync failed: \(failureSummary(for: error))"
    }

    private static func failureSummary(for error: Error, depth: Int = 0) -> String {
        let nsError = error as NSError
        guard nsError.domain == CKErrorDomain else {
            return error.localizedDescription
        }

        if let code = CKError.Code(rawValue: nsError.code),
           code == .partialFailure,
           let partialSummary = partialFailureSummary(from: nsError, depth: depth) {
            return partialSummary
        }

        if let detailedDescription = detailedCloudKitDescription(for: nsError) {
            return detailedDescription
        }

        switch CKError.Code(rawValue: nsError.code) {
        case .notAuthenticated:
            return "Sign in to iCloud in Settings to sync your cards across devices."
        case .networkUnavailable, .networkFailure:
            return "Wallet couldn't reach iCloud. Check your network connection and try again."
        case .quotaExceeded:
            return "iCloud storage is full. Free up iCloud storage, then try again."
        case .serviceUnavailable:
            return "iCloud is temporarily unavailable. Try again later."
        case .requestRateLimited:
            if let retryAfter = retryAfterDelay(from: nsError) {
                return "iCloud asked Wallet to retry in \(Int(retryAfter.rounded())) seconds."
            }
            return "iCloud asked Wallet to slow down syncing. Try again later."
        case .missingEntitlement, .badContainer:
            return "Wallet isn't configured for the iCloud container \(PersistenceController.cloudKitContainerIdentifier)."
        case .invalidArguments, .serverRejectedRequest, .constraintViolation:
            return "iCloud rejected a card record. Check that the CloudKit production schema is deployed."
        default:
            return nsError.localizedDescription
        }
    }

    private static func retryAfterDelay(from error: NSError) -> TimeInterval? {
        let value = error.userInfo[CKErrorRetryAfterKey]
        if let timeInterval = value as? TimeInterval {
            return timeInterval
        }
        return (value as? NSNumber)?.doubleValue
    }

    private static func partialFailureSummary(from error: NSError, depth: Int) -> String? {
        guard depth < 4,
              let partialErrors = error.userInfo[CKPartialErrorsByItemIDKey] as? NSDictionary,
              partialErrors.count > 0 else {
            return nil
        }

        let summaries = partialErrors.allValues.compactMap { value -> String? in
            if let nestedError = value as? NSError {
                return failureSummary(for: nestedError, depth: depth + 1)
            }
            if let nestedError = value as? Error {
                return failureSummary(for: nestedError, depth: depth + 1)
            }
            return nil
        }

        guard let firstSummary = summaries.first else {
            return nil
        }

        let failedItemCount = partialErrors.count
        let prefix = failedItemCount == 1
            ? "1 CloudKit item failed"
            : "\(failedItemCount) CloudKit items failed"
        return "\(prefix): \(firstSummary)"
    }

    private static func detailedCloudKitDescription(for error: NSError) -> String? {
        let cloudKitDescriptions = cloudKitDescriptionUserInfoKeys.map { error.userInfo[$0] }
        let candidateDescriptions = cloudKitDescriptions + [
            error.userInfo[NSLocalizedFailureReasonErrorKey],
            error.userInfo[NSDebugDescriptionErrorKey],
            error.userInfo[NSLocalizedDescriptionKey]
        ]

        return candidateDescriptions.compactMap { value -> String? in
            guard let description = value as? String else { return nil }
            let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }.first
    }

    private static func accountStatusDescription(_ accountStatus: CKAccountStatus) -> String {
        switch accountStatus {
        case .available:
            return "available"
        case .noAccount:
            return "noAccount"
        case .restricted:
            return "restricted"
        case .couldNotDetermine:
            return "couldNotDetermine"
        case .temporarilyUnavailable:
            return "temporarilyUnavailable"
        @unknown default:
            return "unknown"
        }
    }

    private static func statusDescription(_ status: Status) -> String {
        switch status {
        case .unknown:
            return "unknown"
        case .signedIn:
            return "signedIn"
        case .syncing:
            return "syncing"
        case .upToDate:
            return "upToDate"
        case .accountUnavailable(let message):
            return "accountUnavailable(\(message))"
        case .failed(let message):
            return "failed(\(message))"
        }
    }

    private static func lastEventDescription(_ event: LastEvent?) -> String {
        guard let event else { return "none" }

        let outcome: String
        switch event.outcome {
        case .started:
            outcome = "started"
        case .succeeded:
            outcome = "succeeded"
        case .failed:
            outcome = "failed"
        }

        return "\(event.direction.logName) \(outcome) at \(event.date)"
    }
}
