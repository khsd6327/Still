import Foundation

public actor EnvironmentOperationCoordinator {
    private var activeOperationIDs: [WindowsEnvironment.ID: StillOperation.ID] = [:]

    public init() {}

    public func begin(_ operation: StillOperation) throws {
        if let activeID = activeOperationIDs[operation.environmentID] {
            throw StillCoreError.environmentOperationInProgress(
                operation.environmentID,
                activeID
            )
        }
        activeOperationIDs[operation.environmentID] = operation.id
    }

    public func finish(_ operation: StillOperation) {
        guard activeOperationIDs[operation.environmentID] == operation.id else {
            return
        }
        activeOperationIDs.removeValue(forKey: operation.environmentID)
    }

    public func activeOperationID(
        for environmentID: WindowsEnvironment.ID
    ) -> StillOperation.ID? {
        activeOperationIDs[environmentID]
    }
}
