import StillCore
import SwiftUI

struct SidebarView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        List(selection: $model.destination) {
            Section("Library") {
                ForEach(model.libraryDestinations) { destination in
                    Label(destination.title, systemImage: destination.systemImage)
                        .tag(destination)
                }
            }
            Section("Manage") {
                ForEach([SidebarDestination.install, .activity, .environments]) { destination in
                    Label(destination.title, systemImage: destination.systemImage)
                        .tag(destination)
                }
            }
            if model.developerModeEnabled {
                Section("Developer") {
                    ForEach([
                        SidebarDestination.engines,
                        .processInspector,
                        .diagnostics
                    ]) { destination in
                        Label(destination.title, systemImage: destination.systemImage)
                            .tag(destination)
                    }
#if DEBUG
                    Label(SidebarDestination.labs.title, systemImage: SidebarDestination.labs.systemImage)
                        .tag(SidebarDestination.labs)
#endif
                }
            }
        }
        .navigationTitle(ProductIdentity.name)
    }
}
