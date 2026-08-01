import StillCore
import SwiftUI

struct LibraryView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Group {
            if model.libraryState == .loading {
                ProgressView("Loading Library…")
            } else if model.visibleApplications.isEmpty {
                ContentUnavailableView {
                    Label(emptyTitle, systemImage: "square.grid.2x2")
                } description: {
                    Text(emptyDescription)
                } actions: {
                    Button("Install from Local File") { model.destination = .install }
                    if !model.environments.isEmpty {
                        Button("Scan Environments") {
                            Task { await model.scanApplications() }
                        }
                    }
                }
            } else if model.presentation == .grid {
                grid
            } else {
                list
            }
        }
        .navigationTitle(model.destination.title)
        .safeAreaInset(edge: .bottom) {
            FeatureStateView(state: model.libraryState)
                .font(.caption)
                .padding(8)
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 16)],
                spacing: 16
            ) {
                ForEach(model.visibleApplications) { application in
                    Button {
                        model.selectedApplicationID = application.id
                    } label: {
                        ApplicationCard(
                            application: application,
                            isSelected: model.selectedApplicationID == application.id
                        )
                    }
                    .buttonStyle(.plain)
                    .simultaneousGesture(TapGesture(count: 2).onEnded {
                        model.selectedApplicationID = application.id
                        Task { await model.launchSelectedApplication() }
                    })
                    .accessibilityLabel(application.name)
                    .accessibilityValue(accessibilityValue(application))
                    .accessibilityHint("Selects the application. Use Command Return to run it.")
                    .accessibilityAction(named: "Run") {
                        model.selectedApplicationID = application.id
                        Task { await model.launchSelectedApplication() }
                    }
                    .contextMenu {
                        Button("Run") {
                            model.selectedApplicationID = application.id
                            Task { await model.launchSelectedApplication() }
                        }
                        Button(application.isFavorite ? "Remove from Favorites" : "Add to Favorites") {
                            Task { await model.toggleFavorite(application) }
                        }
                    }
                }
            }
            .padding(20)
        }
    }

    private var list: some View {
        Table(model.visibleApplications, selection: $model.selectedApplicationID) {
            TableColumn("Name") { application in
                Label(application.name, systemImage: icon(for: application))
            }
            TableColumn("Type") { application in
                Text(application.category.rawValue.capitalized)
            }
            TableColumn("Environment") { application in
                Text(model.environments.first(where: { $0.id == application.environmentID })?.name ?? "Missing")
            }
            TableColumn("Last Used") { application in
                Text(application.lastLaunchedAt?.formatted(date: .abbreviated, time: .shortened) ?? "Never")
            }
        }
        .contextMenu(forSelectionType: LibraryApplication.ID.self) { ids in
            Button("Run") {
                model.selectedApplicationID = ids.first
                Task { await model.launchSelectedApplication() }
            }
        } primaryAction: { ids in
            model.selectedApplicationID = ids.first
            Task { await model.launchSelectedApplication() }
        }
    }

    private var emptyTitle: String {
        model.searchText.isEmpty ? "No Applications" : "No Results"
    }

    private var emptyDescription: String {
        model.searchText.isEmpty
            ? "Choose a local installer or scan an existing Environment."
            : "Try a different search."
    }

    private func icon(for application: LibraryApplication) -> String {
        switch application.category {
        case .game: "gamecontroller"
        case .productivity: "doc.text"
        case .launcher: "square.stack.3d.up"
        default: "app"
        }
    }

    private func accessibilityValue(_ application: LibraryApplication) -> String {
        let selected = model.selectedApplicationID == application.id ? "Selected" : "Not selected"
        let favorite = application.isFavorite ? ", Favorite" : ""
        return "\(selected), \(application.category.rawValue)\(favorite)"
    }
}

private struct ApplicationCard: View {
    let application: LibraryApplication
    let isSelected: Bool
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 16)
                    .fill(.quaternary)
                Image(systemName: application.category == .game ? "gamecontroller.fill" : "app.fill")
                    .font(.system(size: 38))
                    .foregroundStyle(.secondary)
            }
            .aspectRatio(1.4, contentMode: .fit)
            HStack(alignment: .firstTextBaseline) {
                Text(application.name)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                if application.isFavorite {
                    Image(systemName: "star.fill").foregroundStyle(.yellow)
                }
                if isSelected && differentiateWithoutColor {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.primary)
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(isSelected ? Color.accentColor.opacity(0.14) : Color.clear)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .stroke(
                    isSelected ? Color.accentColor : Color.clear,
                    lineWidth: contrast == .increased ? 3 : 2
                )
        }
        .contentShape(Rectangle())
        .accessibilityHidden(true)
    }
}
