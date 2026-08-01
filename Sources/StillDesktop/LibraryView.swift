import AppKit
import ImageIO
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
                            isSelected: model.selectedApplicationID == application.id,
                            artworkURL: artworkURL(for: application)
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
                HStack(spacing: 8) {
                    ApplicationArtwork(
                        url: artworkURL(for: application),
                        fallbackSystemImage: icon(for: application),
                        inset: 2
                    )
                    .frame(width: 22, height: 22)
                    Text(application.name)
                }
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
        guard model.searchText.isEmpty else { return "No Results" }
        return model.environments.isEmpty ? "No Environments" : "No Applications Found"
    }

    private var emptyDescription: String {
        guard model.searchText.isEmpty else { return "Try a different search." }
        return model.environments.isEmpty
            ? "Create an Environment or import an existing Wine prefix."
            : "Install a Windows application or scan the registered Environments again."
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

    private func artworkURL(for application: LibraryApplication) -> URL? {
        guard let entryID = application.launchEntryIDs.first,
              let entry = model.launchEntries.first(where: { $0.id == entryID }) else {
            return nil
        }
        return ApplicationArtworkResolver.resolve(
            application: application,
            launcherURL: entry.executableURL
        )
    }
}

private struct ApplicationCard: View {
    let application: LibraryApplication
    let isSelected: Bool
    let artworkURL: URL?
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 16)
                    .fill(.quaternary)
                ApplicationArtwork(
                    url: artworkURL,
                    fallbackSystemImage: application.category == .game
                        ? "gamecontroller.fill"
                        : "app.fill",
                    inset: application.category == .game ? 0 : 32
                )
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

struct ApplicationArtwork: View {
    let url: URL?
    let fallbackSystemImage: String
    var inset: CGFloat = 0

    var body: some View {
        Group {
            if let url, let image = ApplicationArtworkLoader.load(url) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(inset)
            } else {
                Image(systemName: fallbackSystemImage)
                    .resizable()
                    .scaledToFit()
                    .padding(max(inset, 6))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

enum ApplicationArtworkLoader {
    static func load(_ url: URL) -> NSImage? {
        if let image = NSImage(contentsOf: url) { return image }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }

        let bestIndex = (0..<CGImageSourceGetCount(source)).max { left, right in
            pixelArea(source: source, index: left) < pixelArea(source: source, index: right)
        } ?? 0
        guard let image = CGImageSourceCreateImageAtIndex(source, bestIndex, nil) else {
            return nil
        }
        return NSImage(
            cgImage: image,
            size: NSSize(width: image.width, height: image.height)
        )
    }

    private static func pixelArea(source: CGImageSource, index: Int) -> Int {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil)
                as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            return 0
        }
        return width * height
    }
}

enum ApplicationArtworkResolver {
    static func resolve(
        application: LibraryApplication,
        launcherURL: URL,
        fileManager: FileManager = .default
    ) -> URL? {
        guard application.providerID == "steam" else { return nil }
        let steamRoot = launcherURL.deletingLastPathComponent()

        let candidates: [URL]
        if application.providerItemID == "client" {
            candidates = [
                steamRoot.appending(path: "public/steam_tray.ico"),
                steamRoot.appending(path: "public/steam_tray_mono.png")
            ]
        } else if let appID = application.providerItemID {
            let cache = steamRoot.appending(path: "appcache/librarycache")
            candidates = [
                cache.appending(path: "\(appID)/library_600x900.jpg"),
                cache.appending(path: "\(appID)_library_600x900.jpg"),
                cache.appending(path: "\(appID)/header.jpg"),
                cache.appending(path: "\(appID)_header.jpg")
            ]
        } else {
            candidates = []
        }

        return candidates.first { fileManager.fileExists(atPath: $0.path) }
    }
}
