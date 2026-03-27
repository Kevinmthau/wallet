import CoreData
import Combine

struct PersistenceController {
    static let shared = PersistenceController()

    let container: NSPersistentCloudKitContainer

    /// Publisher for remote CloudKit changes - subscribe to refresh UI when other devices sync
    let remoteChangePublisher = PassthroughSubject<Void, Never>()

    /// Stored observer token for CloudKit remote change notifications
    private let remoteChangeObserver: NSObjectProtocol

    init(inMemory: Bool = false) {
        // Create the managed object model programmatically
        let model = NSManagedObjectModel()

        // Define Card entity
        let cardEntity = NSEntityDescription()
        cardEntity.name = "Card"
        cardEntity.managedObjectClassName = "Card"

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

        if inMemory {
            container.persistentStoreDescriptions.first?.url = URL(fileURLWithPath: "/dev/null")
        }

        // Configure for CloudKit sync
        if let description = container.persistentStoreDescriptions.first {
            if !inMemory {
                description.cloudKitContainerOptions = NSPersistentCloudKitContainerOptions(
                    containerIdentifier: "iCloud.com.kevinthau.wallet"
                )
            }
            description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
            description.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
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

        Self.configure(context: container.viewContext)

        // Observe remote CloudKit changes and notify subscribers
        // Store the observer token to maintain the subscription
        remoteChangeObserver = NotificationCenter.default.addObserver(
            forName: .NSPersistentStoreRemoteChange,
            object: container.persistentStoreCoordinator,
            queue: .main
        ) { [remoteChangePublisher] _ in
            AppLogger.data.info("PersistenceController: Received remote CloudKit change notification")
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
            let card = Card(context: context)
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
        Self.configure(context: context)
        return context
    }

    private static func configure(context: NSManagedObjectContext) {
        context.automaticallyMergesChangesFromParent = true
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
        let objectTimestamp = timestamp(in: conflict.objectSnapshot)
        let storeTimestamp = timestamp(in: conflict.persistedSnapshot)

        switch (objectTimestamp, storeTimestamp) {
        case let (objectTimestamp?, storeTimestamp?):
            return objectTimestamp >= storeTimestamp ? .object : .store
        case (.some, nil):
            return .object
        case (nil, .some):
            return .store
        case (nil, nil):
            return .object
        }
    }

    private func timestamp(in snapshot: [String: Any]?) -> Date? {
        snapshot?[localTimestampKey] as? Date
    }
}
