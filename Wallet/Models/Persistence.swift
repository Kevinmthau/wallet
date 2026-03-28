import CoreData
import Combine

private final class RemoteChangeLogCoalescer {
    private let interval: TimeInterval
    private var pendingCount = 0
    private var pendingLog: DispatchWorkItem?

    init(interval: TimeInterval = 2.0) {
        self.interval = interval
    }

    func recordNotification() {
        pendingCount += 1

        guard pendingLog == nil else { return }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }

            let count = pendingCount
            pendingCount = 0
            pendingLog = nil

            if count == 1 {
                AppLogger.data.debug("PersistenceController: Received remote CloudKit change notification")
            } else {
                AppLogger.data.debug("PersistenceController: Received \(count) remote CloudKit change notifications")
            }
        }

        pendingLog = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + interval, execute: workItem)
    }
}

struct PersistenceController {
    static let shared = PersistenceController()
    private static let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    let container: NSPersistentCloudKitContainer

    /// Publisher for remote CloudKit changes - subscribe to refresh UI when other devices sync
    let remoteChangePublisher = PassthroughSubject<Void, Never>()

    /// Stored observer token for CloudKit remote change notifications
    private let remoteChangeObserver: NSObjectProtocol
    private let remoteChangeLogCoalescer = RemoteChangeLogCoalescer()

    init(
        inMemory: Bool = false,
        storeURL: URL? = nil,
        cloudKitEnabled: Bool? = nil
    ) {
        let cloudKitEnabled = cloudKitEnabled ?? (!inMemory && !Self.isRunningTests)

        // Create the managed object model programmatically
        let model = NSManagedObjectModel()

        // Define Card entity
        let cardEntity = NSEntityDescription()
        cardEntity.name = "Card"
        cardEntity.managedObjectClassName = NSStringFromClass(Card.self)

        // Define attributes
        // Note: id is set dynamically when adding cards - not here
        // Setting UUID() here would create ONE UUID shared by all cards (evaluated once at model init)
        let idAttribute = NSAttributeDescription()
        idAttribute.name = "id"
        idAttribute.attributeType = .UUIDAttributeType
        idAttribute.isOptional = true  // CloudKit requires optional or default; we always set in create()

        let nameAttribute = NSAttributeDescription()
        nameAttribute.name = "name"
        nameAttribute.attributeType = .stringAttributeType
        nameAttribute.isOptional = false
        nameAttribute.defaultValue = ""

        let categoryAttribute = NSAttributeDescription()
        categoryAttribute.name = "categoryRaw"
        categoryAttribute.attributeType = .stringAttributeType
        categoryAttribute.isOptional = false
        categoryAttribute.defaultValue = "Other"

        let frontImageAttribute = NSAttributeDescription()
        frontImageAttribute.name = "frontImageData"
        frontImageAttribute.attributeType = .binaryDataAttributeType
        frontImageAttribute.isOptional = true
        frontImageAttribute.allowsExternalBinaryDataStorage = true

        let backImageAttribute = NSAttributeDescription()
        backImageAttribute.name = "backImageData"
        backImageAttribute.attributeType = .binaryDataAttributeType
        backImageAttribute.isOptional = true
        backImageAttribute.allowsExternalBinaryDataStorage = true

        let notesAttribute = NSAttributeDescription()
        notesAttribute.name = "notes"
        notesAttribute.attributeType = .stringAttributeType
        notesAttribute.isOptional = true

        let isFavoriteAttribute = NSAttributeDescription()
        isFavoriteAttribute.name = "isFavorite"
        isFavoriteAttribute.attributeType = .booleanAttributeType
        isFavoriteAttribute.isOptional = false
        isFavoriteAttribute.defaultValue = false

        // Note: createdAt is set dynamically when adding cards - not here
        // Setting Date() here would create ONE Date shared by all cards (evaluated once at model init)
        let createdAtAttribute = NSAttributeDescription()
        createdAtAttribute.name = "createdAt"
        createdAtAttribute.attributeType = .dateAttributeType
        createdAtAttribute.isOptional = true  // CloudKit requires optional or default; we always set in create()

        // Note: lastAccessedAt is set dynamically when adding cards - not here
        let lastAccessedAttribute = NSAttributeDescription()
        lastAccessedAttribute.name = "lastAccessedAt"
        lastAccessedAttribute.attributeType = .dateAttributeType
        lastAccessedAttribute.isOptional = true  // CloudKit requires optional or default; we always set in create()

        let updatedAtAttribute = NSAttributeDescription()
        updatedAtAttribute.name = "updatedAt"
        updatedAtAttribute.attributeType = .dateAttributeType
        updatedAtAttribute.isOptional = true

        cardEntity.properties = [
            idAttribute,
            nameAttribute,
            categoryAttribute,
            frontImageAttribute,
            backImageAttribute,
            notesAttribute,
            isFavoriteAttribute,
            createdAtAttribute,
            lastAccessedAttribute,
            updatedAtAttribute
        ]

        model.entities = [cardEntity]

        container = NSPersistentCloudKitContainer(name: "Wallet", managedObjectModel: model)

        if let description = container.persistentStoreDescriptions.first {
            if let storeURL {
                description.url = storeURL
            } else if inMemory {
                description.url = URL(fileURLWithPath: "/dev/null")
            }

            if !cloudKitEnabled {
                description.cloudKitContainerOptions = nil
            } else {
                description.cloudKitContainerOptions = NSPersistentCloudKitContainerOptions(
                    containerIdentifier: "iCloud.com.kevinthau.wallet"
                )
                description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
                description.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
            }
            description.setOption(true as NSNumber, forKey: NSMigratePersistentStoresAutomaticallyOption)
            description.setOption(true as NSNumber, forKey: NSInferMappingModelAutomaticallyOption)
        } else {
            AppLogger.data.error("PersistenceController: No persistent store description found - CloudKit sync may not work")
        }

        container.loadPersistentStores { _, error in
            if let error = error as NSError? {
                AppLogger.data.error("PersistenceController: Failed to load persistent store: \(error.localizedDescription), \(error.userInfo)")
            }
        }

        Self.configureViewContext(container.viewContext)

        // Observe remote CloudKit changes and notify subscribers
        // Store the observer token to maintain the subscription
        remoteChangeObserver = NotificationCenter.default.addObserver(
            forName: .NSPersistentStoreRemoteChange,
            object: container.persistentStoreCoordinator,
            queue: .main
        ) { [remoteChangePublisher, remoteChangeLogCoalescer] _ in
            remoteChangeLogCoalescer.recordNotification()
            remoteChangePublisher.send()
        }
    }

    // Preview helper
    static var preview: PersistenceController = {
        let controller = PersistenceController(inMemory: true)
        let context = controller.container.viewContext

        // Create sample cards for preview
        let sampleCategories: [CardCategory] = [.insurance, .membership, .id, .loyalty]
        let sampleNames = [
            "Blue Cross Insurance",
            "Science Museum",
            "Driver's License",
            "Coffee Rewards"
        ]

        for (index, name) in sampleNames.enumerated() {
            let referenceDate = Date().addingTimeInterval(TimeInterval(-index * 3600))
            let card = Card.insert(into: context)
            card.id = UUID()
            card.name = name
            card.category = sampleCategories[index]
            card.isFavorite = index == 0
            card.createdAt = referenceDate
            card.lastAccessedAt = referenceDate
            card.updatedAt = referenceDate
        }

        try? context.save()
        return controller
    }()

    func save() {
        let context = container.viewContext
        if context.hasChanges {
            do {
                try context.save()
            } catch {
                AppLogger.data.error("PersistenceController.save failed: \(error.localizedDescription)")
            }
        }
    }

    func makeBackgroundContext() -> NSManagedObjectContext {
        let context = container.newBackgroundContext()
        Self.configureBackgroundContext(context)
        return context
    }

    private static func configureViewContext(_ context: NSManagedObjectContext) {
        context.automaticallyMergesChangesFromParent = true
        context.mergePolicy = CardTimestampMergePolicy()
    }

    private static func configureBackgroundContext(_ context: NSManagedObjectContext) {
        context.automaticallyMergesChangesFromParent = false
        context.mergePolicy = CardTimestampMergePolicy()
    }
}

final class CardTimestampMergePolicy: NSMergePolicy {
    private let objectTrumpPolicy = NSMergePolicy(merge: .mergeByPropertyObjectTrumpMergePolicyType)
    private let storeTrumpPolicy = NSMergePolicy(merge: .mergeByPropertyStoreTrumpMergePolicyType)

    init(localTimestampKey: String = Card.Attributes.updatedAt) {
        self.localTimestampKey = localTimestampKey
        super.init(merge: .errorMergePolicyType)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func resolve(mergeConflicts list: [Any]) throws {
        var objectTrumpConflicts: [Any] = []
        var storeTrumpConflicts: [Any] = []

        for item in list {
            guard let conflict = item as? NSMergeConflict else {
                objectTrumpConflicts.append(item)
                continue
            }

            switch winner(for: conflict) {
            case .object:
                objectTrumpConflicts.append(conflict)
            case .store:
                storeTrumpConflicts.append(conflict)
            }
        }

        if !storeTrumpConflicts.isEmpty {
            try storeTrumpPolicy.resolve(mergeConflicts: storeTrumpConflicts)
        }

        if !objectTrumpConflicts.isEmpty {
            try objectTrumpPolicy.resolve(mergeConflicts: objectTrumpConflicts)
        }
    }

    private enum ConflictWinner {
        case object
        case store
    }

    private let localTimestampKey: String

    private func winner(for conflict: NSMergeConflict) -> ConflictWinner {
        let objectTimestamp = timestamp(in: conflict.sourceObject)
            ?? timestamp(in: conflict.objectSnapshot)
            ?? timestamp(in: conflict.cachedSnapshot)
        let storeTimestamp = timestamp(in: conflict.persistedSnapshot)

        switch (objectTimestamp, storeTimestamp) {
        case let (objectTimestamp?, storeTimestamp?):
            return objectTimestamp > storeTimestamp ? .object : .store
        case (.some, nil):
            return .object
        case (nil, .some):
            return .store
        case (nil, nil):
            return .object
        }
    }

    private func timestamp(in object: NSManagedObject?) -> Date? {
        object?.value(forKey: localTimestampKey) as? Date
    }

    private func timestamp(in snapshot: [String: Any]?) -> Date? {
        snapshot?[localTimestampKey] as? Date
    }
}
