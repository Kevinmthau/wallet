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
        func optionalDateAttribute(named name: String) -> NSAttributeDescription {
            let attribute = NSAttributeDescription()
            attribute.name = name
            attribute.attributeType = .dateAttributeType
            attribute.isOptional = true
            return attribute
        }

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

        let hasBackImageAttribute = NSAttributeDescription()
        hasBackImageAttribute.name = "hasBackImage"
        hasBackImageAttribute.attributeType = .booleanAttributeType
        hasBackImageAttribute.isOptional = false
        hasBackImageAttribute.defaultValue = false

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

        let nameUpdatedAtAttribute = optionalDateAttribute(named: Card.Attributes.nameUpdatedAt)
        let categoryUpdatedAtAttribute = optionalDateAttribute(named: Card.Attributes.categoryUpdatedAt)
        let notesUpdatedAtAttribute = optionalDateAttribute(named: Card.Attributes.notesUpdatedAt)
        let isFavoriteUpdatedAtAttribute = optionalDateAttribute(named: Card.Attributes.isFavoriteUpdatedAt)
        let frontImageUpdatedAtAttribute = optionalDateAttribute(named: Card.Attributes.frontImageUpdatedAt)
        let backImageUpdatedAtAttribute = optionalDateAttribute(named: Card.Attributes.backImageUpdatedAt)

        cardEntity.properties = [
            idAttribute,
            nameAttribute,
            categoryAttribute,
            frontImageAttribute,
            backImageAttribute,
            hasBackImageAttribute,
            notesAttribute,
            isFavoriteAttribute,
            createdAtAttribute,
            lastAccessedAttribute,
            updatedAtAttribute,
            nameUpdatedAtAttribute,
            categoryUpdatedAtAttribute,
            notesUpdatedAtAttribute,
            isFavoriteUpdatedAtAttribute,
            frontImageUpdatedAtAttribute,
            backImageUpdatedAtAttribute
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
            card.hasBackImage = false
            card.isFavorite = index == 0
            card.createdAt = referenceDate
            card.lastAccessedAt = referenceDate
            card.updatedAt = referenceDate
            card.markAllMutableFieldsUpdated(at: referenceDate)
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
    private let independentlyResolvedKeys = [
        Card.Attributes.id,
        Card.Attributes.name,
        Card.Attributes.categoryRaw,
        Card.Attributes.notes,
        Card.Attributes.isFavorite,
        Card.Attributes.createdAt
    ]
    private let updatedAtResolvedKeys = [
        Card.Attributes.updatedAt
    ]
    private let imageDataKeys = [
        Card.Attributes.frontImageData,
        Card.Attributes.backImageData
    ]

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
        var fieldResolvedConflicts: [Any] = []
        var fieldRestorations: [(object: NSManagedObject, fields: [ResolvedField])] = []
        var accessTimestampRestorations: [(object: NSManagedObject, timestamp: Date)] = []

        for item in list {
            guard let conflict = item as? NSMergeConflict else {
                objectTrumpConflicts.append(item)
                continue
            }

            if let latestAccessTimestamp = latestAccessTimestamp(for: conflict) {
                accessTimestampRestorations.append((conflict.sourceObject, latestAccessTimestamp))
            }

            if canResolveByField(conflict) {
                let resolvedFields = resolveFields(for: conflict)
                fieldRestorations.append((conflict.sourceObject, resolvedFields))
                fieldResolvedConflicts.append(conflict)
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

        let objectTrumpResolvedConflicts = objectTrumpConflicts + fieldResolvedConflicts
        if !objectTrumpResolvedConflicts.isEmpty {
            try objectTrumpPolicy.resolve(mergeConflicts: objectTrumpResolvedConflicts)
        }

        // Object-trump uses Core Data's original conflict snapshot, so apply the
        // resolved values again for fields that intentionally keep a local value.
        restoreResolvedFields(fieldRestorations)
        restoreAccessTimestamps(accessTimestampRestorations)
    }

    private enum ConflictWinner {
        case object
        case store
    }

    private let localTimestampKey: String
    private let accessTimestampKey = Card.Attributes.lastAccessedAt

    private struct FieldChange {
        let key: String
        let localValue: Any?
        let storeValue: Any?
        let localChanged: Bool
        let storeChanged: Bool
        let localVersion: Date?
        let storeVersion: Date?
    }

    private struct ResolvedField {
        let key: String
        let value: Any?
        let storeValue: Any?
        let fieldVersion: Date?
        let storeFieldVersion: Date?
    }

    private func canResolveByField(_ conflict: NSMergeConflict) -> Bool {
        guard conflict.sourceObject.entity.name == Card.Attributes.entityName,
              !conflict.sourceObject.isDeleted,
              conflict.cachedSnapshot != nil,
              conflict.persistedSnapshot != nil else {
            return false
        }

        return true
    }

    private func resolveFields(for conflict: NSMergeConflict) -> [ResolvedField] {
        resolveIndependentFields(for: conflict)
            + resolveImageFields(for: conflict)
            + resolveUpdatedAtField(for: conflict)
    }

    private func resolveIndependentFields(for conflict: NSMergeConflict) -> [ResolvedField] {
        independentlyResolvedKeys.map { key in
            let change = fieldChange(for: key, in: conflict)
            let resolvedValue = resolvedValue(for: change, in: conflict)
            let resolvedFieldVersion = resolvedFieldVersion(for: change, in: conflict)
            setResolvedValue(resolvedValue, forKey: key, on: conflict.sourceObject)
            setResolvedFieldVersion(
                resolvedFieldVersion,
                forKey: key,
                on: conflict.sourceObject
            )
            return ResolvedField(
                key: key,
                value: resolvedValue,
                storeValue: change.storeValue,
                fieldVersion: resolvedFieldVersion,
                storeFieldVersion: change.storeVersion
            )
        }
    }

    private func resolveUpdatedAtField(for conflict: NSMergeConflict) -> [ResolvedField] {
        updatedAtResolvedKeys.map { key in
            let change = fieldChange(for: key, in: conflict)
            let resolvedValue = resolvedValue(for: change, in: conflict)
            setResolvedValue(resolvedValue, forKey: key, on: conflict.sourceObject)
            return ResolvedField(
                key: key,
                value: resolvedValue,
                storeValue: change.storeValue,
                fieldVersion: nil,
                storeFieldVersion: nil
            )
        }
    }

    private func resolveImageFields(for conflict: NSMergeConflict) -> [ResolvedField] {
        let imageChanges = imageDataKeys.map { fieldChange(for: $0, in: conflict) }
        let hasSameSideImageConflict = imageChanges.contains { change in
            change.localChanged && change.storeChanged
        }

        let resolvedFields: [ResolvedField]
        if hasSameSideImageConflict {
            let imageWinner = winner(forImageChanges: imageChanges, in: conflict)
            let imageWinnerVersion = version(
                forImageChanges: imageChanges,
                winner: imageWinner,
                in: conflict
            )
            resolvedFields = imageChanges.map { change in
                let fieldWinner = winner(
                    forImageChange: change,
                    defaultWinner: imageWinner,
                    defaultWinnerVersion: imageWinnerVersion
                )
                let resolvedValue: Any?
                let changedFromValue: Any?
                let resolvedFieldVersion: Date?
                switch fieldWinner {
                case .object:
                    resolvedValue = change.localValue
                    changedFromValue = change.storeValue
                    resolvedFieldVersion = change.localVersion
                case .store:
                    resolvedValue = change.storeValue
                    changedFromValue = nil
                    resolvedFieldVersion = change.storeVersion
                }
                setResolvedValue(
                    resolvedValue,
                    forKey: change.key,
                    on: conflict.sourceObject,
                    changedFrom: changedFromValue,
                    forceChange: fieldWinner == .object && change.storeChanged
                )
                setResolvedFieldVersion(
                    resolvedFieldVersion,
                    forKey: change.key,
                    on: conflict.sourceObject,
                    changedFrom: fieldWinner == .object ? change.storeVersion : nil,
                    forceChange: fieldWinner == .object && change.storeChanged
                )
                return ResolvedField(
                    key: change.key,
                    value: resolvedValue,
                    storeValue: change.storeValue,
                    fieldVersion: resolvedFieldVersion,
                    storeFieldVersion: change.storeVersion
                )
            }
        } else {
            resolvedFields = imageChanges.map { change in
                let resolvedValue = resolvedValue(for: change, in: conflict)
                let resolvedFieldVersion = resolvedFieldVersion(for: change, in: conflict)
                setResolvedValue(resolvedValue, forKey: change.key, on: conflict.sourceObject)
                setResolvedFieldVersion(
                    resolvedFieldVersion,
                    forKey: change.key,
                    on: conflict.sourceObject
                )
                return ResolvedField(
                    key: change.key,
                    value: resolvedValue,
                    storeValue: change.storeValue,
                    fieldVersion: resolvedFieldVersion,
                    storeFieldVersion: change.storeVersion
                )
            }
        }

        return resolvedFields + [resolveBackImagePresence(from: resolvedFields, in: conflict)]
    }

    private func resolveBackImagePresence(
        from resolvedImageFields: [ResolvedField],
        in conflict: NSMergeConflict
    ) -> ResolvedField {
        let resolvedBackImageData = resolvedImageFields
            .first { $0.key == Card.Attributes.backImageData }?
            .value
        let hasBackImage = resolvedBackImageData != nil
        let storeValue = value(in: conflict.persistedSnapshot, key: Card.Attributes.hasBackImage)
        setResolvedValue(hasBackImage, forKey: Card.Attributes.hasBackImage, on: conflict.sourceObject)
        return ResolvedField(
            key: Card.Attributes.hasBackImage,
            value: hasBackImage,
            storeValue: storeValue,
            fieldVersion: nil,
            storeFieldVersion: nil
        )
    }

    private func fieldChange(for key: String, in conflict: NSMergeConflict) -> FieldChange {
        let localValue = value(in: conflict.sourceObject, key: key)
        let storeValue = value(in: conflict.persistedSnapshot, key: key)
        let baseValue = value(in: conflict.cachedSnapshot, key: key)
        let localChanged = !valuesAreEqual(localValue, baseValue)
        let storeChanged = !valuesAreEqual(storeValue, baseValue)
        let baseVersion = fieldVersion(forKey: key, in: conflict.cachedSnapshot)
        let localVersion = effectiveFieldVersion(
            fieldVersion(forKey: key, in: conflict.sourceObject),
            baseVersion: baseVersion,
            fieldChanged: localChanged,
            fallbackVersion: objectTimestamp(for: conflict)
        )
        let storeVersion = effectiveFieldVersion(
            fieldVersion(forKey: key, in: conflict.persistedSnapshot),
            baseVersion: baseVersion,
            fieldChanged: storeChanged,
            fallbackVersion: timestamp(in: conflict.persistedSnapshot)
        )

        return FieldChange(
            key: key,
            localValue: localValue,
            storeValue: storeValue,
            localChanged: localChanged,
            storeChanged: storeChanged,
            localVersion: localVersion,
            storeVersion: storeVersion
        )
    }

    private func resolvedValue(for change: FieldChange, in conflict: NSMergeConflict) -> Any? {
        switch (change.localChanged, change.storeChanged) {
        case (true, true):
            switch winner(for: change, in: conflict) {
            case .object:
                return change.localValue
            case .store:
                return change.storeValue
            }
        case (true, false):
            return change.localValue
        case (false, true):
            return change.storeValue
        case (false, false):
            return change.localValue
        }
    }

    private func resolvedFieldVersion(for change: FieldChange, in conflict: NSMergeConflict) -> Date? {
        switch (change.localChanged, change.storeChanged) {
        case (true, true):
            switch winner(for: change, in: conflict) {
            case .object:
                return change.localVersion
            case .store:
                return change.storeVersion
            }
        case (true, false):
            return change.localVersion
        case (false, true):
            return change.storeVersion
        case (false, false):
            return [change.localVersion, change.storeVersion].compactMap { $0 }.max()
        }
    }

    private func setResolvedValue(
        _ resolvedSourceValue: Any?,
        forKey key: String,
        on object: NSManagedObject,
        changedFrom previousValue: Any? = nil,
        forceChange: Bool = false
    ) {
        guard object.entity.propertiesByName[key] != nil else { return }

        let resolvedValue = normalizedValue(resolvedSourceValue)
        if resolvedValue == nil,
           let attribute = object.entity.attributesByName[key],
           !attribute.isOptional {
            return
        }

        let currentValue = value(in: object, key: key)
        let previousValue = normalizedValue(previousValue)
        let canAssignPreviousValue = previousValue != nil
            || object.entity.attributesByName[key]?.isOptional == true

        if forceChange,
           canAssignPreviousValue,
           valuesAreEqual(currentValue, resolvedValue),
           !valuesAreEqual(previousValue, resolvedValue) {
            object.setValue(previousValue, forKey: key)
            object.setValue(resolvedValue, forKey: key)
        } else if !valuesAreEqual(currentValue, resolvedValue) {
            object.setValue(resolvedValue, forKey: key)
        }
    }

    private func setResolvedFieldVersion(
        _ resolvedVersion: Date?,
        forKey key: String,
        on object: NSManagedObject,
        changedFrom previousVersion: Date? = nil,
        forceChange: Bool = false
    ) {
        guard let versionKey = Card.Attributes.timestampKeyByMutableField[key] else { return }
        setResolvedValue(
            resolvedVersion,
            forKey: versionKey,
            on: object,
            changedFrom: previousVersion,
            forceChange: forceChange
        )
    }

    private func winner(for conflict: NSMergeConflict) -> ConflictWinner {
        winner(
            objectTimestamp: objectTimestamp(for: conflict),
            storeTimestamp: timestamp(in: conflict.persistedSnapshot)
        )
    }

    private func winner(for change: FieldChange, in conflict: NSMergeConflict) -> ConflictWinner {
        winner(
            objectTimestamp: change.localVersion ?? objectTimestamp(for: conflict),
            storeTimestamp: change.storeVersion ?? timestamp(in: conflict.persistedSnapshot)
        )
    }

    private func winner(
        forImageChange change: FieldChange,
        defaultWinner: ConflictWinner,
        defaultWinnerVersion: Date?
    ) -> ConflictWinner {
        guard change.localChanged != change.storeChanged else {
            return defaultWinner
        }

        let changedSideWinner: ConflictWinner = change.localChanged ? .object : .store
        let changedSideVersion = change.localChanged ? change.localVersion : change.storeVersion

        switch (changedSideVersion, defaultWinnerVersion) {
        case let (changedSideVersion?, defaultWinnerVersion?):
            return changedSideVersion > defaultWinnerVersion ? changedSideWinner : defaultWinner
        case (.some, nil):
            return changedSideWinner
        case (nil, _):
            return defaultWinner
        }
    }

    private func winner(forImageChanges changes: [FieldChange], in conflict: NSMergeConflict) -> ConflictWinner {
        let conflictingChanges = changes.filter { $0.localChanged && $0.storeChanged }
        return winner(
            objectTimestamp: conflictingChanges
                .compactMap { $0.localVersion }
                .max()
                ?? objectTimestamp(for: conflict),
            storeTimestamp: conflictingChanges
                .compactMap { $0.storeVersion }
                .max()
                ?? timestamp(in: conflict.persistedSnapshot)
        )
    }

    private func version(
        forImageChanges changes: [FieldChange],
        winner: ConflictWinner,
        in conflict: NSMergeConflict
    ) -> Date? {
        let conflictingChanges = changes.filter { $0.localChanged && $0.storeChanged }
        switch winner {
        case .object:
            return conflictingChanges
                .compactMap { $0.localVersion }
                .max()
                ?? objectTimestamp(for: conflict)
        case .store:
            return conflictingChanges
                .compactMap { $0.storeVersion }
                .max()
                ?? timestamp(in: conflict.persistedSnapshot)
        }
    }

    private func winner(objectTimestamp: Date?, storeTimestamp: Date?) -> ConflictWinner {
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

    private func objectTimestamp(for conflict: NSMergeConflict) -> Date? {
        timestamp(in: conflict.objectSnapshot)
            ?? timestamp(in: conflict.sourceObject)
            ?? timestamp(in: conflict.cachedSnapshot)
    }

    private func latestAccessTimestamp(for conflict: NSMergeConflict) -> Date? {
        guard conflict.sourceObject.entity.propertiesByName[accessTimestampKey] != nil else {
            return nil
        }

        return [
            timestamp(in: conflict.sourceObject, key: accessTimestampKey),
            timestamp(in: conflict.objectSnapshot, key: accessTimestampKey),
            timestamp(in: conflict.cachedSnapshot, key: accessTimestampKey),
            timestamp(in: conflict.persistedSnapshot, key: accessTimestampKey)
        ]
        .compactMap { $0 }
        .max()
    }

    private func restoreAccessTimestamps(
        _ restorations: [(object: NSManagedObject, timestamp: Date)]
    ) {
        for (object, timestamp) in restorations where !object.isDeleted {
            let currentTimestamp = self.timestamp(in: object, key: accessTimestampKey)
            if currentTimestamp.map({ timestamp > $0 }) ?? true {
                object.setValue(timestamp, forKey: accessTimestampKey)
            }
        }
    }

    private func restoreResolvedFields(
        _ restorations: [(object: NSManagedObject, fields: [ResolvedField])]
    ) {
        for (object, fields) in restorations where !object.isDeleted {
            for field in fields {
                setResolvedValue(
                    field.value,
                    forKey: field.key,
                    on: object,
                    changedFrom: field.storeValue,
                    forceChange: !valuesAreEqual(field.value, field.storeValue)
                )
                setResolvedFieldVersion(
                    field.fieldVersion,
                    forKey: field.key,
                    on: object,
                    changedFrom: field.storeFieldVersion,
                    forceChange: !valuesAreEqual(field.fieldVersion, field.storeFieldVersion)
                )
            }
        }
    }

    private func timestamp(in object: NSManagedObject?) -> Date? {
        timestamp(in: object, key: localTimestampKey)
    }

    private func timestamp(in snapshot: [String: Any]?) -> Date? {
        timestamp(in: snapshot, key: localTimestampKey)
    }

    private func timestamp(in object: NSManagedObject?, key: String) -> Date? {
        normalizedValue(object?.value(forKey: key)) as? Date
    }

    private func timestamp(in snapshot: [String: Any]?, key: String) -> Date? {
        normalizedValue(snapshot?[key]) as? Date
    }

    private func fieldVersion(forKey key: String, in object: NSManagedObject?) -> Date? {
        guard let versionKey = Card.Attributes.timestampKeyByMutableField[key] else { return nil }
        return timestamp(in: object, key: versionKey)
    }

    private func fieldVersion(forKey key: String, in snapshot: [String: Any]?) -> Date? {
        guard let versionKey = Card.Attributes.timestampKeyByMutableField[key] else { return nil }
        return timestamp(in: snapshot, key: versionKey)
    }

    private func effectiveFieldVersion(
        _ fieldVersion: Date?,
        baseVersion: Date?,
        fieldChanged: Bool,
        fallbackVersion: Date?
    ) -> Date? {
        if fieldChanged,
           (fieldVersion == nil || valuesAreEqual(fieldVersion, baseVersion)) {
            return fallbackVersion ?? fieldVersion
        }
        return fieldVersion ?? fallbackVersion
    }

    private func value(in object: NSManagedObject, key: String) -> Any? {
        guard object.entity.propertiesByName[key] != nil else { return nil }
        return normalizedValue(object.value(forKey: key))
    }

    private func value(in snapshot: [String: Any]?, key: String) -> Any? {
        normalizedValue(snapshot?[key])
    }

    private func normalizedValue(_ value: Any?) -> Any? {
        if value is NSNull {
            return nil
        }
        return value
    }

    private func valuesAreEqual(_ lhs: Any?, _ rhs: Any?) -> Bool {
        let lhs = normalizedValue(lhs)
        let rhs = normalizedValue(rhs)

        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case (nil, _), (_, nil):
            return false
        case let (lhs as Data, rhs as Data):
            return lhs == rhs
        case let (lhs as Date, rhs as Date):
            return lhs == rhs
        case let (lhs as UUID, rhs as UUID):
            return lhs == rhs
        case let (lhs as String, rhs as String):
            return lhs == rhs
        case let (lhs as Bool, rhs as Bool):
            return lhs == rhs
        case let (lhs as NSNumber, rhs as NSNumber):
            return lhs == rhs
        default:
            if let lhsObject = lhs as? NSObject {
                return lhsObject.isEqual(rhs)
            }
            if let rhsObject = rhs as? NSObject {
                return rhsObject.isEqual(lhs)
            }
            return false
        }
    }
}
