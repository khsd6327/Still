import Foundation

public struct ApplicationLibraryScanner {
    private let coordinator: ApplicationDiscoveryCoordinator

    public init(
        steamScanner: SteamLibraryScanner = SteamLibraryScanner(),
        executableScanner: WindowsExecutableScanner = WindowsExecutableScanner()
    ) {
        coordinator = ApplicationDiscoveryCoordinator(providers: [
            SteamDiscoveryProvider(scanner: steamScanner),
            ExecutableDiscoveryProvider(scanner: executableScanner)
        ])
    }

    public func scan(bottle: Bottle) throws -> [InstalledWindowsApplication] {
        let result = coordinator.discover(in: bottle)
        return (result.accepted + result.requiresConfirmation)
            .map(\.application)
            .sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
    }
}
