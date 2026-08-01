import Foundation

public actor EnvironmentDeletionCoordinator {
    public nonisolated let journalRootURL: URL
    public nonisolated let quarantineRootURL: URL

    private let store: JSONStillStore
    private let ownershipService: EnvironmentOwnershipService
    private let fileManager: FileManager

    public init(
        store: JSONStillStore,
        ownershipService: EnvironmentOwnershipService,
        rootURL: URL,
        fileManager: FileManager = .default
    ) {
        self.store = store
        self.ownershipService = ownershipService
        self.journalRootURL = rootURL.appending(
            path: "Deletion Journal",
            directoryHint: .isDirectory
        )
        self.quarantineRootURL = rootURL.appending(
            path: "Deletion Quarantine",
            directoryHint: .isDirectory
        )
        self.fileManager = fileManager
    }

    public func delete(
        environment: WindowsEnvironment,
        method: EnvironmentDeletionMethod,
        activeSessions: [LaunchSession],
        finalPermanentConfirmation: Bool
    ) async throws {
        guard !activeSessions.contains(where: {
            $0.environmentID == environment.id && $0.state.isActive
        }) else {
            throw StillCoreError.environmentMustBeStopped(environment.id)
        }
        if method == .permanentlyDelete, !finalPermanentConfirmation {
            throw StillCoreError.permanentDeletionConfirmationRequired
        }
        guard let nonce = environment.managementNonce else {
            throw StillCoreError.invalidStore(
                "The Environment has no managed ownership nonce."
            )
        }

        let document = try await store.load()
        try ownershipService.validateManagedOwnership(
            of: environment,
            storeIdentifier: document.storeIdentifier
        )
        let operationID = UUID()
        let quarantineURL = expectedQuarantineURL(
            operationID: operationID,
            environmentID: environment.id
        )
        var journal = EnvironmentDeletionJournal(
            id: operationID,
            storeIdentifier: document.storeIdentifier,
            environmentID: environment.id,
            managementNonce: nonce,
            originalPrefixURL: environment.prefixURL,
            quarantineURL: quarantineURL,
            method: method
        )
        try persist(journal)

        var operation = StillOperation(
            id: operationID,
            kind: .deleteEnvironment,
            environmentID: environment.id
        )
        var movedToQuarantine = false
        var storeCommitted = false
        do {
            try operation.transition(to: .running)
            try await store.saveOperation(operation)
            try fileManager.createDirectory(
                at: quarantineRootURL,
                withIntermediateDirectories: true
            )
            guard !fileManager.fileExists(atPath: quarantineURL.path) else {
                throw StillCoreError.invalidStore(
                    "The deletion quarantine destination already exists."
                )
            }
            try fileManager.moveItem(at: environment.prefixURL, to: quarantineURL)
            movedToQuarantine = true
            journal.state = .quarantined
            journal.updatedAt = .now
            try persist(journal)
            try ownershipService.validateManagedMarker(
                at: quarantineURL,
                environmentID: environment.id,
                storeIdentifier: document.storeIdentifier,
                nonce: nonce
            )

            try await store.commitManagedEnvironmentDeletion(
                id: environment.id,
                expectedPrefixURL: environment.prefixURL,
                expectedManagementNonce: nonce
            )
            storeCommitted = true

            journal.state = .storeCommitted
            journal.updatedAt = .now
            try persist(journal)
            do {
                try finishCleanup(journal)
                try removeJournal(journal.id)
            } catch {
                journal.state = .cleanupPending
                journal.updatedAt = .now
                try? persist(journal)
                throw StillCoreError.deletionCleanupPending(quarantineURL)
            }
        } catch let transactionError {
            if movedToQuarantine, !storeCommitted,
               fileManager.fileExists(atPath: quarantineURL.path) {
                do {
                    try rollback(journal)
                } catch {
                    throw error
                }
            }
            if fileManager.fileExists(atPath: environment.prefixURL.path),
               !fileManager.fileExists(atPath: quarantineURL.path) {
                try? removeJournal(journal.id)
                if operation.state == .running {
                    try? operation.transition(
                        to: .failed,
                        resultSummary: transactionError.localizedDescription
                    )
                    try? await store.saveOperation(operation)
                }
            }
            throw transactionError
        }
    }

    @discardableResult
    public func recoverInterruptedDeletions() async throws -> Int {
        guard fileManager.fileExists(atPath: journalRootURL.path) else { return 0 }
        let document = try await store.load()
        let journalURLs = try fileManager.contentsOfDirectory(
            at: journalRootURL,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "json" }
        var recoveredCount = 0
        for url in journalURLs {
            var journal = try JSONDecoder().decode(
                EnvironmentDeletionJournal.self,
                from: Data(contentsOf: url)
            )
            try validate(journal, storeIdentifier: document.storeIdentifier)
            let environmentExists = document.environments.contains {
                $0.id == journal.environmentID
            }
            let originalExists = fileManager.fileExists(
                atPath: journal.originalPrefixURL.path
            )
            let quarantineExists = fileManager.fileExists(
                atPath: journal.quarantineURL.path
            )

            if environmentExists {
                if quarantineExists && !originalExists {
                    try ownershipService.validateManagedMarker(
                        at: journal.quarantineURL,
                        environmentID: journal.environmentID,
                        storeIdentifier: journal.storeIdentifier,
                        nonce: journal.managementNonce
                    )
                    try fileManager.moveItem(
                        at: journal.quarantineURL,
                        to: journal.originalPrefixURL
                    )
                } else if quarantineExists || !originalExists {
                    throw StillCoreError.invalidStore(
                        "An interrupted deletion cannot be rolled back automatically."
                    )
                }
                journal.state = .rolledBack
                journal.updatedAt = .now
                try persist(journal)
                try removeJournal(journal.id)
                recoveredCount += 1
            } else {
                if quarantineExists {
                    try ownershipService.validateManagedMarker(
                        at: journal.quarantineURL,
                        environmentID: journal.environmentID,
                        storeIdentifier: journal.storeIdentifier,
                        nonce: journal.managementNonce
                    )
                    try finishCleanup(journal)
                } else if originalExists {
                    throw StillCoreError.invalidStore(
                        "A deleted Environment record still has files at its original path."
                    )
                }
                try removeJournal(journal.id)
                recoveredCount += 1
            }
        }
        return recoveredCount
    }

    private func rollback(_ journal: EnvironmentDeletionJournal) throws {
        guard fileManager.fileExists(atPath: journal.quarantineURL.path),
              !fileManager.fileExists(atPath: journal.originalPrefixURL.path) else {
            throw StillCoreError.invalidStore(
                "The deletion transaction could not restore the Environment automatically."
            )
        }
        try fileManager.moveItem(
            at: journal.quarantineURL,
            to: journal.originalPrefixURL
        )
        var rolledBack = journal
        rolledBack.state = .rolledBack
        rolledBack.updatedAt = .now
        try persist(rolledBack)
        try removeJournal(journal.id)
    }

    private func finishCleanup(_ journal: EnvironmentDeletionJournal) throws {
        guard fileManager.fileExists(atPath: journal.quarantineURL.path) else { return }
        switch journal.method {
        case .moveToTrash:
            var resultingURL: NSURL?
            try fileManager.trashItem(
                at: journal.quarantineURL,
                resultingItemURL: &resultingURL
            )
        case .permanentlyDelete:
            try fileManager.removeItem(at: journal.quarantineURL)
        }
    }

    private func validate(
        _ journal: EnvironmentDeletionJournal,
        storeIdentifier: UUID
    ) throws {
        var mismatches: [String] = []
        if journal.version != EnvironmentDeletionJournal.currentVersion {
            mismatches.append("version")
        }
        if journal.storeIdentifier != storeIdentifier {
            mismatches.append("store identifier")
        }
        if journal.originalPrefixURL.standardizedFileURL.path
            != ownershipService.managedPrefixURL(
                for: journal.environmentID
            ).standardizedFileURL.path {
            mismatches.append("original path")
        }
        if journal.quarantineURL.standardizedFileURL.path
            != expectedQuarantineURL(
                operationID: journal.id,
                environmentID: journal.environmentID
            ).standardizedFileURL.path {
            mismatches.append("quarantine path")
        }
        guard mismatches.isEmpty else {
            throw StillCoreError.invalidStore(
                "The deletion journal does not match this Still store: \(mismatches.joined(separator: ", "))."
            )
        }
    }

    private func expectedQuarantineURL(
        operationID: UUID,
        environmentID: WindowsEnvironment.ID
    ) -> URL {
        quarantineRootURL.appending(
            path: "\(operationID.uuidString)-\(environmentID.uuidString)",
            directoryHint: .isDirectory
        )
    }

    private func persist(_ journal: EnvironmentDeletionJournal) throws {
        try fileManager.createDirectory(
            at: journalRootURL,
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(journal).write(
            to: journalURL(journal.id),
            options: .atomic
        )
    }

    private func removeJournal(_ id: UUID) throws {
        let url = journalURL(id)
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    private func journalURL(_ id: UUID) -> URL {
        journalRootURL.appending(path: "\(id.uuidString).json")
    }
}
