import Foundation
import StillCore

enum SidebarDestination: String, CaseIterable, Hashable, Identifiable {
    case allApplications
    case favorites
    case games
    case applications
    case recent
    case install
    case activity
    case environments
    case engines
    case processInspector
    case diagnostics
    case labs

    var id: String { rawValue }

    var title: String {
        switch self {
        case .allApplications: "All Applications"
        case .favorites: "Favorites"
        case .games: "Games"
        case .applications: "Applications"
        case .recent: "Recent"
        case .install: "Install"
        case .activity: "Activity"
        case .environments: "Environments"
        case .engines: "Engines"
        case .processInspector: "Process Inspector"
        case .diagnostics: "Diagnostics"
        case .labs: "Labs"
        }
    }

    var systemImage: String {
        switch self {
        case .allApplications: "square.grid.2x2"
        case .favorites: "star"
        case .games: "gamecontroller"
        case .applications: "app"
        case .recent: "clock"
        case .install: "plus.app"
        case .activity: "waveform.path.ecg"
        case .environments: "shippingbox"
        case .engines: "cpu"
        case .processInspector: "list.bullet.rectangle"
        case .diagnostics: "stethoscope"
        case .labs: "flask"
        }
    }

    var isLibrary: Bool {
        [.allApplications, .favorites, .games, .applications, .recent].contains(self)
    }
}

enum CloseRunningBehavior: String, CaseIterable {
    case ask
    case stopAndClose
    case leaveRunning

    var title: String {
        switch self {
        case .ask: "Ask Every Time"
        case .stopAndClose: "Request Stop, Then Close"
        case .leaveRunning: "Leave Running"
        }
    }
}

enum PendingForceTermination: Equatable {
    case selected(LaunchSession.ID, String)
    case all(Int)
}

enum LibraryPresentation: String, CaseIterable {
    case grid
    case list
}

enum FeatureLoadState: Equatable {
    case idle
    case loading
    case success(String?)
    case partial(String)
    case failure(String)
    case offline(String)
    case recovery(String)
}

struct InstallDraft: Equatable {
    var installerURL: URL?
    var environmentID: WindowsEnvironment.ID?
}

struct PendingDiscoveryCandidate: Identifiable {
    let environmentID: WindowsEnvironment.ID
    let candidate: DiscoveredApplicationCandidate
    var id: String { "\(environmentID):\(candidate.id)" }
}
