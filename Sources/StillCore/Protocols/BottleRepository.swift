import Foundation

public protocol BottleRepository: Sendable {
    func bottles() async throws -> [Bottle]
    func bottle(id: Bottle.ID) async throws -> Bottle?
    func save(_ bottle: Bottle) async throws
}

