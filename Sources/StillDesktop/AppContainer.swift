import StillCore
import SwiftUI

struct AppContainer: View {
    @ObservedObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 260)
        } content: {
            destinationContent
                .navigationSplitViewColumnWidth(min: 480, ideal: 680)
        } detail: {
            if model.destination.isLibrary && model.inspectorPresented {
                ApplicationInspector(model: model)
                    .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 360)
            } else {
                ContentUnavailableView("No Inspector", systemImage: "sidebar.right")
            }
        }
        .searchable(
            text: $model.searchText,
            placement: .toolbar,
            prompt: "Search Library"
        )
        .toolbar { toolbar }
        .background(WindowCloseGuard())
        .task { await model.load() }
        .safeAreaInset(edge: .top) {
            if let notice = model.launchNotice {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(notice).font(.callout)
                    Spacer()
                    if model.pendingWindowControlApplicationID != nil {
                        Button("Allow Window Control") {
                            model.requestWindowControlPermission()
                        }
                        .buttonStyle(.borderless)
                        Button("Try Again") {
                            Task { await model.retryWindowActivation() }
                        }
                        .buttonStyle(.borderless)
                    }
                    Button("Dismiss") { model.dismissLaunchNotice() }
                        .buttonStyle(.borderless)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(.bar)
            }
        }
        .alert(
            "Still could not complete the operation.",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )
        ) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "Unknown error")
        }
        .confirmationDialog(
            forceConfirmationTitle,
            isPresented: Binding(
                get: { model.pendingForceTermination != nil },
                set: { _ in }
            ),
            titleVisibility: .visible
        ) {
            Button(forceConfirmationButtonTitle, role: .destructive) {
                Task { await model.confirmForceTermination() }
            }
            Button("Cancel", role: .cancel) { model.pendingForceTermination = nil }
        } message: {
            Text(forceConfirmationMessage)
        }
        .sheet(isPresented: Binding(
            get: { !model.pendingDiscoveryCandidates.isEmpty },
            set: { if !$0 { model.pendingDiscoveryCandidates.removeAll() } }
        )) {
            DiscoveryReviewView(model: model)
        }
        .transaction { transaction in
            if reduceMotion { transaction.animation = nil }
        }
    }

    @ViewBuilder
    private var destinationContent: some View {
        switch model.destination {
        case .allApplications, .favorites, .games, .applications, .recent:
            LibraryView(model: model)
        case .install:
            InstallView(model: model)
        case .activity:
            ActivityView(model: model)
        case .environments:
            EnvironmentsView(model: model)
        case .engines, .processInspector, .diagnostics, .labs:
            DeveloperView(model: model, destination: model.destination)
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if model.destination.isLibrary {
                Picker("View", selection: $model.presentation) {
                    Label("Grid", systemImage: "square.grid.2x2").tag(LibraryPresentation.grid)
                    Label("List", systemImage: "list.bullet").tag(LibraryPresentation.list)
                }
                .pickerStyle(.segmented)
                .frame(width: 92)

                if let application = model.selectedApplication {
                    let runtimeState = model.runtimeState(for: application)
                    Button(runtimeState.title, systemImage: runtimeState.systemImage) {
                        Task { await model.performPrimaryApplicationAction(applicationID: application.id) }
                    }
                    .disabled(
                        runtimeState == .launching || runtimeState == .stopping
                            || (runtimeState == .idle && !canLaunchSelectedApplication)
                    )
                }

                if model.selectedSession != nil {
                    Button("Request Stop", systemImage: "stop.fill") {
                        Task { await model.stopSelectedNormally() }
                    }
                }

                Button("Inspector", systemImage: "sidebar.right") {
                    model.inspectorPresented.toggle()
                }
            }

            Button("Activity", systemImage: "waveform.path.ecg") {
                model.destination = .activity
                Task { await model.refreshActivity() }
            }

            Button("Install", systemImage: "plus.app") {
                model.destination = .install
            }
        }
    }

    private var forceConfirmationTitle: String {
        switch model.pendingForceTermination {
        case .selected(_, let name): "Force Stop \(name)?"
        case .all(let count): "Force Stop All \(count) Sessions?"
        case nil: "Force Stop?"
        }
    }

    private var forceConfirmationButtonTitle: String {
        switch model.pendingForceTermination {
        case .selected: "Force Stop Selected Application"
        case .all: "Force Stop All Sessions"
        case nil: "Force Stop"
        }
    }

    private var forceConfirmationMessage: String {
        switch model.pendingForceTermination {
        case .selected(_, let name):
            "Force stopping \(name) can discard unsaved Windows application data."
        case .all(let count):
            "Force stopping all \(count) sessions can discard unsaved data in every affected Windows application."
        case nil:
            "Force stopping can discard unsaved Windows application data."
        }
    }

    private var canLaunchSelectedApplication: Bool {
        guard let application = model.selectedApplication else { return false }
        return application.providerManagedState == nil
            || application.providerManagedState == .installed
    }
}
