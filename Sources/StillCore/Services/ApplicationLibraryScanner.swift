import Foundation

public struct ApplicationLibraryScanner {
    private let steamScanner: SteamLibraryScanner
    private let executableScanner: WindowsExecutableScanner

    public init(
        steamScanner: SteamLibraryScanner = SteamLibraryScanner(),
        executableScanner: WindowsExecutableScanner = WindowsExecutableScanner()
    ) {
        self.steamScanner = steamScanner
        self.executableScanner = executableScanner
    }

    public func scan(bottle: Bottle) throws -> [InstalledWindowsApplication] {
        let steamApplications = try steamScanner.scan(bottle: bottle)
        let executableApplications = executableScanner.scan(bottle: bottle)

        var applications = Dictionary(
            uniqueKeysWithValues: steamApplications.map { ($0.id, $0) }
        )
        for application in executableApplications {
            applications[application.id] = application
        }

        return applications.values.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}
