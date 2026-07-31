import AppKit
import StillCore
import SwiftUI
import UniformTypeIdentifiers

@main
struct StillDesktopApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
        }
        .windowStyle(.automatic)
        .commands {
            CommandMenu("Bottle") {
                Button("Open Windows Steam") {
                    Task { await model.launchSelectedSteam() }
                }
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(
                    model.selectedBottle?.recipeID
                        != BundledApplicationRecipes.steam.id
                )

                Button("Scan Applications") {
                    Task { await model.refreshApplications() }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(model.bottles.isEmpty)

                Button("Reveal Bottle in Finder") {
                    model.revealSelectedBottle()
                }
                .disabled(model.selectedBottle == nil)

                Divider()

                Button("Running Windows Processes…") {
                    Task { await model.showSelectedBottleProcesses() }
                }
                .keyboardShortcut("p", modifiers: [.command, .option])
                .disabled(model.selectedBottle == nil)

                Button("Wine Configuration") {
                    Task { await model.launchSelectedTool("winecfg") }
                }
                .disabled(model.selectedBottle == nil)

                Button("Registry Editor") {
                    Task { await model.launchSelectedTool("regedit") }
                }
                .disabled(model.selectedBottle == nil)

                Button("Control Panel") {
                    Task { await model.launchSelectedTool("control") }
                }
                .disabled(model.selectedBottle == nil)

                Button("Open Still Logs") {
                    model.openLogs()
                }

                Divider()

                Button("Stop Selected Bottle") {
                    Task { await model.stopSelectedBottle() }
                }
                .keyboardShortcut(
                    "k",
                    modifiers: [.command, .option]
                )
                .disabled(
                    model.selectedBottle == nil || model.isStoppingProcesses
                )

                Button("Kill All Bottles") {
                    Task { await model.stopAllBottles() }
                }
                .keyboardShortcut("k", modifiers: [.command, .shift])
                .disabled(
                    model.bottles.isEmpty || model.isStoppingProcesses
                )

                Divider()

                Button("Wine Engines…") {
                    model.showsEngineLibrary = true
                }
                .keyboardShortcut("e", modifiers: [.command])

                Button("Set Up Steam…") {
                    Task { await model.setupSteam() }
                }
                .disabled(model.isSettingUpSteam || model.hasSteamBottle)
            }
        }
    }
}

@MainActor
private final class AppModel: ObservableObject {
    private let bottleStore = JSONBottleStore()
    private let applicationPinStore = JSONApplicationPinStore()
    private let engineInstaller = EngineInstaller()
    private lazy var bottleProvisioner = BottleProvisioner(
        bottleStore: bottleStore
    )
    private lazy var steamBootstrapper = SteamBootstrapper(
        bottleStore: bottleStore,
        engineInstaller: engineInstaller
    )
    private let applicationScanner = ApplicationLibraryScanner()
    private let wineProcessController = WineProcessController()

    @Published var bottles: [Bottle] = []
    @Published var selection: Bottle.ID?
    @Published var errorMessage: String?
    @Published var installedEngineIDs: Set<String> = []
    @Published var installedEngines: [EngineDescriptor] = []
    @Published var selectedEngineID: String?
    @Published var installingEngineID: String?
    @Published var applicationsByBottle: [Bottle.ID: [InstalledWindowsApplication]] = [:]
    @Published var isSettingUpSteam = false
    @Published var statusMessage: String?
    @Published var showsEngineLibrary = false
    @Published var showsProcessList = false
    @Published var windowsProcesses: [WindowsProcess] = []
    @Published var isLoadingProcesses = false
    @Published var isStoppingProcesses = false

    let availableEngines = BundledEngineCatalog.manifests

    var selectedBottle: Bottle? {
        bottles.first { $0.id == selection }
    }

    var hasSteamBottle: Bool {
        bottles.contains {
            $0.recipeID == BundledApplicationRecipes.steam.id
        }
    }

    func load() async {
        do {
            bottles = try await bottleStore.bottles()
            if selection == nil {
                selection = bottles.first?.id
            }
            let descriptors = await engineInstaller.installedDescriptors()
            installedEngines = descriptors
            installedEngineIDs = Set(descriptors.map(\.id))
            let preferredEngineID = descriptors.first(
                where: { $0.id == "gcenx-gptk-3.0-3" }
            )?.id ?? descriptors.first?.id
            if let currentEngineID = selectedEngineID {
                if !installedEngineIDs.contains(currentEngineID) {
                    selectedEngineID = preferredEngineID
                }
            } else {
                selectedEngineID = preferredEngineID
            }
            try await scanApplications()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func setupSteam() async {
        guard !isSettingUpSteam else { return }
        isSettingUpSteam = true
        defer { isSettingUpSteam = false }

        do {
            let result = try await steamBootstrapper.bootstrap()
            await load()
            selection = result.bottle.id
            if result.steamExecutableURL != nil {
                statusMessage = "Steam is already installed."
            } else {
                statusMessage = "Steam installer started. Games will appear after a library scan."
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refreshApplications() async {
        do {
            try await scanApplications()
            statusMessage = "Windows applications scanned."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func pinApplication(
        executableURL: URL,
        in bottle: Bottle
    ) async {
        do {
            let application = try await applicationPinStore.pin(
                executableURL: executableURL,
                in: bottle
            )
            try await scanApplications()
            statusMessage = "\(application.name) pinned."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func removePin(
        _ application: InstalledWindowsApplication,
        from bottle: Bottle
    ) async {
        do {
            try await applicationPinStore.remove(
                applicationID: application.id,
                bottleID: bottle.id
            )
            try await scanApplications()
            statusMessage = "\(application.name) removed from the library."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func setEngine(
        engineID: String,
        for bottle: Bottle
    ) async {
        do {
            guard installedEngineIDs.contains(engineID) else {
                throw StillCoreError.engineNotFound(engineID)
            }
            var updatedBottle = bottle
            if let currentEngineID = bottle.engineID,
               currentEngineID != engineID,
               let currentEngine = installedEngines.first(
                   where: { $0.id == currentEngineID }
               ) {
                try await wineProcessController.stop(
                    bottle: bottle,
                    engine: currentEngine
                )
            }
            updatedBottle.engineID = engineID
            updatedBottle.updatedAt = .now
            try await bottleStore.save(updatedBottle)
            await load()
            selection = updatedBottle.id
            statusMessage = "Bottle stopped and engine changed."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func setCompatibility(
        graphicsBackend: GraphicsBackend,
        enhancedSync: EnhancedSyncMode,
        metalHUDEnabled: Bool,
        metalTraceEnabled: Bool,
        for bottle: Bottle
    ) async {
        do {
            let engine = try engine(for: bottle)
            if graphicsBackend == .d3dMetal,
               !engine.capabilities.contains(.d3dMetal) {
                throw StillCoreError.invalidCompatibilityConfiguration(
                    "D3DMetal requires a Game Porting Toolkit engine."
                )
            }
            if enhancedSync == .msync,
               !engine.capabilities.contains(.msync) {
                throw StillCoreError.invalidCompatibilityConfiguration(
                    "MSync is not supported by the selected engine."
                )
            }

            try await wineProcessController.stop(
                bottle: bottle,
                engine: engine
            )
            var updatedBottle = bottle
            updatedBottle.graphicsBackend = graphicsBackend
            updatedBottle.enhancedSync = enhancedSync
            updatedBottle.metalHUDEnabled = metalHUDEnabled
            updatedBottle.metalTraceEnabled = metalTraceEnabled
            updatedBottle.updatedAt = .now
            try await bottleStore.save(updatedBottle)
            await load()
            selection = updatedBottle.id
            statusMessage = "Bottle stopped and compatibility settings changed."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func launchSelectedTool(_ tool: String) async {
        guard let selectedBottle else { return }
        await launchTool(tool, in: selectedBottle)
    }

    func launchTool(_ tool: String, in bottle: Bottle) async {
        do {
            _ = try await wineProcessController.launchTool(
                [tool],
                bottle: bottle,
                engine: try engine(for: bottle)
            )
            statusMessage = "\(tool) launch requested."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func openLogs() {
        NSWorkspace.shared.open(LogLocations.defaultRootURL())
    }

    func showSelectedBottleProcesses() async {
        guard let selectedBottle else { return }
        showsProcessList = true
        await refreshProcesses(in: selectedBottle)
    }

    func refreshProcesses(in bottle: Bottle) async {
        guard !isLoadingProcesses else { return }
        isLoadingProcesses = true
        defer { isLoadingProcesses = false }
        do {
            windowsProcesses = try await wineProcessController.processes(
                bottle: bottle,
                engine: try engine(for: bottle)
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func kill(_ process: WindowsProcess, in bottle: Bottle) async {
        do {
            try await wineProcessController.kill(
                processID: process.processID,
                bottle: bottle,
                engine: try engine(for: bottle)
            )
            await refreshProcesses(in: bottle)
            statusMessage = "\(process.name) (PID \(process.processID)) stopped."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func stopBottle(_ bottle: Bottle) async {
        guard !isStoppingProcesses else { return }
        isStoppingProcesses = true
        defer { isStoppingProcesses = false }

        do {
            guard let engineID = bottle.engineID,
                  let engine = installedEngines.first(
                    where: { $0.id == engineID }
                  ) else {
                throw StillCoreError.engineNotFound(
                    bottle.engineID ?? "unassigned"
                )
            }
            try await wineProcessController.stop(
                bottle: bottle,
                engine: engine
            )
            statusMessage = "\(bottle.name) processes stopped."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func stopSelectedBottle() async {
        guard let selectedBottle else { return }
        await stopBottle(selectedBottle)
    }

    func launchSelectedSteam() async {
        guard let selectedBottle,
              selectedBottle.recipeID == BundledApplicationRecipes.steam.id
        else {
            return
        }
        await launchSteam(in: selectedBottle)
    }

    func revealSelectedBottle() {
        guard let selectedBottle else { return }
        NSWorkspace.shared.activateFileViewerSelecting([
            selectedBottle.prefixURL
        ])
    }

    func stopAllBottles() async {
        guard !isStoppingProcesses else { return }
        isStoppingProcesses = true
        defer { isStoppingProcesses = false }

        do {
            var stoppedCount = 0
            for bottle in bottles {
                guard let engineID = bottle.engineID,
                      let engine = installedEngines.first(
                          where: { $0.id == engineID }
                      ) else {
                    continue
                }
                try await wineProcessController.stop(
                    bottle: bottle,
                    engine: engine
                )
                stoppedCount += 1
            }
            statusMessage = "Stopped \(stoppedCount) bottle(s)."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func launchSteam(in bottle: Bottle) async {
        let steamURL = await steamBootstrapper.steamURL(in: bottle)
        guard FileManager.default.fileExists(atPath: steamURL.path) else {
            errorMessage = "Steam is not installed in this bottle."
            return
        }
        await launch(
            InstalledWindowsApplication(
                id: "valve-steam-client",
                name: "Steam",
                source: .steam,
                installState: .installed,
                installDirectoryURL: steamURL.deletingLastPathComponent(),
                launcherURL: steamURL,
                launchArguments: SteamBootstrapper.launchArguments(
                    for: bottle
                )
            ),
            in: bottle
        )
    }

    func launch(
        _ application: InstalledWindowsApplication,
        in bottle: Bottle
    ) async {
        do {
            guard application.installState == .installed else {
                throw StillCoreError.invalidApplicationState(
                    application.installState.rawValue
                )
            }
            guard let engineID = bottle.engineID,
                  let descriptor = installedEngines.first(
                    where: { $0.id == engineID }
                  ) else {
                throw StillCoreError.engineNotFound(
                    bottle.engineID ?? "unassigned"
                )
            }
            _ = try await LocalWineEngine(
                descriptor: descriptor
            ).launch(
                LaunchRequest(
                    bottle: bottle,
                    executableURL: application.launcherURL,
                    arguments: application.launchArguments,
                    environment: application.id == "valve-steam-client"
                        && bottle.graphicsBackend == .dxmt
                        ? ["STILL_STEAM_CEF_RAW_ANGLE": "1"]
                        : [:],
                    workingDirectoryURL: application.launcherURL
                        .deletingLastPathComponent()
                )
            )
            statusMessage = "\(application.name) launch requested."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func scanApplications() async throws {
        var discovered: [Bottle.ID: [InstalledWindowsApplication]] = [:]
        for bottle in bottles {
            var applications = Dictionary(
                uniqueKeysWithValues: try applicationScanner
                    .scan(bottle: bottle)
                    .map { ($0.id, $0) }
            )
            for application in try await applicationPinStore.applications(
                bottleID: bottle.id
            ) {
                applications[application.id] = application
            }
            discovered[bottle.id] = applications.values.sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        }
        applicationsByBottle = discovered
    }

    func createBottle() async {
        do {
            guard let selectedEngineID,
                  let descriptor = installedEngines.first(
                    where: { $0.id == selectedEngineID }
                  ) else {
                throw StillCoreError.noInstalledEngine
            }
            let number = bottles.count + 1
            let engine = LocalWineEngine(descriptor: descriptor)
            let bottle = try await bottleProvisioner.create(
                name: "Bottle \(number)",
                engine: engine
            )
            await load()
            selection = bottle.id
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func installEngine(
        _ manifest: EngineManifest,
        acceptsExternalLicense: Bool = false
    ) async {
        guard installingEngineID == nil else { return }
        installingEngineID = manifest.id
        defer { installingEngineID = nil }

        do {
            let descriptor = try await engineInstaller.install(
                manifest,
                acceptsExternalLicense: acceptsExternalLicense
            )
            installedEngineIDs.insert(descriptor.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func engine(for bottle: Bottle) throws -> EngineDescriptor {
        guard let engineID = bottle.engineID,
              let engine = installedEngines.first(
                where: { $0.id == engineID }
              ) else {
            throw StillCoreError.engineNotFound(
                bottle.engineID ?? "unassigned"
            )
        }
        return engine
    }
}

private struct ContentView: View {
    @ObservedObject var model: AppModel

    var selectedBottle: Bottle? {
        model.bottles.first { $0.id == model.selection }
    }

    var body: some View {
        NavigationSplitView {
            List(model.bottles, selection: $model.selection) { bottle in
                Label(bottle.name, systemImage: "shippingbox")
                    .tag(bottle.id)
            }
            .navigationTitle(ProductIdentity.name)
            .toolbar {
                Button("Create Bottle", systemImage: "plus") {
                    Task { await model.createBottle() }
                }
                Button("Engines", systemImage: "shippingbox") {
                    model.showsEngineLibrary = true
                }
                Button(
                    model.hasSteamBottle ? "Steam Ready" : "Set Up Steam",
                    systemImage: model.hasSteamBottle
                        ? "checkmark.circle"
                        : "gamecontroller"
                ) {
                    Task { await model.setupSteam() }
                }
                .disabled(model.isSettingUpSteam || model.hasSteamBottle)
            }
        } detail: {
            if let bottle = selectedBottle {
                BottleDetailView(
                    bottle: bottle,
                    applications: model.applicationsByBottle[bottle.id] ?? [],
                    installedEngines: model.installedEngines,
                    refresh: {
                        Task { await model.refreshApplications() }
                    },
                    openSteam: {
                        Task { await model.launchSteam(in: bottle) }
                    },
                    launch: { application in
                        Task { await model.launch(application, in: bottle) }
                    },
                    pin: { executableURL in
                        Task {
                            await model.pinApplication(
                                executableURL: executableURL,
                                in: bottle
                            )
                        }
                    },
                    removePin: { application in
                        Task {
                            await model.removePin(application, from: bottle)
                        }
                    },
                    setEngine: { engineID in
                        Task {
                            await model.setEngine(
                                engineID: engineID,
                                for: bottle
                            )
                        }
                    },
                    setCompatibility: { graphics, sync, hud, trace in
                        Task {
                            await model.setCompatibility(
                                graphicsBackend: graphics,
                                enhancedSync: sync,
                                metalHUDEnabled: hud,
                                metalTraceEnabled: trace,
                                for: bottle
                            )
                        }
                    },
                    openTool: { tool in
                        Task { await model.launchTool(tool, in: bottle) }
                    },
                    openLogs: model.openLogs,
                    showProcesses: {
                        Task { await model.showSelectedBottleProcesses() }
                    },
                    stopBottle: {
                        Task { await model.stopBottle(bottle) }
                    },
                    isStoppingProcesses: model.isStoppingProcesses
                )
            } else {
                ContentUnavailableView(
                    "No Bottle Selected",
                    systemImage: "shippingbox",
                    description: Text("Create a bottle to begin.")
                )
            }
        }
        .frame(minWidth: 760, minHeight: 480)
        .task { await model.load() }
        .sheet(isPresented: $model.showsEngineLibrary) {
            EngineLibraryView(model: model)
        }
        .sheet(isPresented: $model.showsProcessList) {
            if let bottle = model.selectedBottle {
                WindowsProcessListView(model: model, bottle: bottle)
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
        .overlay(alignment: .bottom) {
            if let status = model.statusMessage {
                Text(status)
                    .font(.caption)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(.regularMaterial, in: Capsule())
                    .padding()
                    .onTapGesture { model.statusMessage = nil }
            }
        }
    }
}

private struct EngineLibraryView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        NavigationStack {
            List(model.availableEngines) { engine in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(engine.displayName)
                                .font(.headline)
                            Text(ByteCountFormatter.string(
                                fromByteCount: engine.downloadSize,
                                countStyle: .file
                            ))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        Spacer()
                        action(for: engine)
                    }

                    ForEach(engine.requirements, id: \.self) { requirement in
                        Text(requirement)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
            .safeAreaInset(edge: .top) {
                if !model.installedEngines.isEmpty {
                    Picker(
                        "Default engine for new bottles",
                        selection: $model.selectedEngineID
                    ) {
                        ForEach(model.installedEngines) { engine in
                            Text(engine.displayName)
                                .tag(Optional(engine.id))
                        }
                    }
                    .padding()
                    .background(.background)
                }
            }
            .navigationTitle("Wine Engines")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { model.showsEngineLibrary = false }
                }
            }
        }
        .frame(minWidth: 620, minHeight: 430)
    }

    @ViewBuilder
    private func action(for engine: EngineManifest) -> some View {
        if model.installedEngineIDs.contains(engine.id) {
            Label("Installed", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        } else if model.installingEngineID == engine.id {
            ProgressView()
                .controlSize(.small)
        } else if engine.distributionPolicy == .externalLicenseRequired {
            HStack {
                if let licenseURL = engine.licenseURL {
                    Link("License", destination: licenseURL)
                }
                Button("Accept & Install") {
                    Task {
                        await model.installEngine(
                            engine,
                            acceptsExternalLicense: true
                        )
                    }
                }
                .disabled(model.installingEngineID != nil)
            }
        } else {
            Button("Install") {
                Task { await model.installEngine(engine) }
            }
            .disabled(model.installingEngineID != nil)
        }
    }
}

private struct BottleDetailView: View {
    let bottle: Bottle
    let applications: [InstalledWindowsApplication]
    let installedEngines: [EngineDescriptor]
    let refresh: () -> Void
    let openSteam: () -> Void
    let launch: (InstalledWindowsApplication) -> Void
    let pin: (URL) -> Void
    let removePin: (InstalledWindowsApplication) -> Void
    let setEngine: (String) -> Void
    let setCompatibility: (
        GraphicsBackend,
        EnhancedSyncMode,
        Bool,
        Bool
    ) -> Void
    let openTool: (String) -> Void
    let openLogs: () -> Void
    let showProcesses: () -> Void
    let stopBottle: () -> Void
    let isStoppingProcesses: Bool

    var body: some View {
        Form {
            Section("Bottle") {
                LabeledContent("Name", value: bottle.name)
                LabeledContent("Profile", value: bottle.recipeID ?? "Custom")
                LabeledContent("Windows", value: bottle.windowsVersion.rawValue)
                Picker(
                    "Engine",
                    selection: Binding(
                        get: { bottle.engineID ?? "" },
                        set: { engineID in setEngine(engineID) }
                    )
                ) {
                    if bottle.engineID == nil {
                        Text("Not selected").tag("")
                    }
                    ForEach(installedEngines) { engine in
                        Text(engine.displayName).tag(engine.id)
                    }
                }
                .disabled(installedEngines.isEmpty)
                Picker(
                    "Graphics",
                    selection: Binding(
                        get: { bottle.graphicsBackend },
                        set: { graphics in
                            setCompatibility(
                                graphics,
                                bottle.enhancedSync,
                                bottle.metalHUDEnabled,
                                bottle.metalTraceEnabled
                            )
                        }
                    )
                ) {
                    Text(GraphicsBackend.wineD3D.displayName)
                        .tag(GraphicsBackend.wineD3D)
                    if selectedEngine?.capabilities.contains(.d3dMetal) == true {
                        Text(GraphicsBackend.d3dMetal.displayName)
                            .tag(GraphicsBackend.d3dMetal)
                    } else if bottle.graphicsBackend == .d3dMetal {
                        Text("\(GraphicsBackend.d3dMetal.displayName) (Unavailable)")
                            .tag(GraphicsBackend.d3dMetal)
                    }
                }
                Picker(
                    "Synchronization",
                    selection: Binding(
                        get: { bottle.enhancedSync },
                        set: { sync in
                            setCompatibility(
                                bottle.graphicsBackend,
                                sync,
                                bottle.metalHUDEnabled,
                                bottle.metalTraceEnabled
                            )
                        }
                    )
                ) {
                    ForEach(supportedSyncModes, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                if bottle.graphicsBackend == .d3dMetal {
                    Toggle(
                        "Metal Performance HUD",
                        isOn: Binding(
                            get: { bottle.metalHUDEnabled },
                            set: { enabled in
                                setCompatibility(
                                    bottle.graphicsBackend,
                                    bottle.enhancedSync,
                                    enabled,
                                    bottle.metalTraceEnabled
                                )
                            }
                        )
                    )
                    Toggle(
                        "Metal Capture",
                        isOn: Binding(
                            get: { bottle.metalTraceEnabled },
                            set: { enabled in
                                setCompatibility(
                                    bottle.graphicsBackend,
                                    bottle.enhancedSync,
                                    bottle.metalHUDEnabled,
                                    enabled
                                )
                            }
                        )
                    )
                }
                LabeledContent("Prefix") {
                    HStack {
                        Text(bottle.prefixURL.path)
                            .font(.caption.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                        Button("Copy Prefix", systemImage: "doc.on.doc") {
                            copyPrefix()
                        }
                        .labelStyle(.iconOnly)
                        Button("Reveal Prefix", systemImage: "folder") {
                            revealPrefix()
                        }
                        .labelStyle(.iconOnly)
                    }
                }
                Button(
                    "Stop Bottle Processes",
                    systemImage: "stop.circle"
                ) {
                    stopBottle()
                }
                .disabled(isStoppingProcesses)
            }

            Section("Tools") {
                HStack {
                    Button("Wine Configuration") { openTool("winecfg") }
                    Button("Registry Editor") { openTool("regedit") }
                    Button("Control Panel") { openTool("control") }
                }
                HStack {
                    Button("Running Processes") { showProcesses() }
                    Button("Open Logs") { openLogs() }
                }
            }

            if bottle.recipeID == BundledApplicationRecipes.steam.id {
                Section("Steam") {
                    Button("Open Windows Steam", systemImage: "play.fill") {
                        openSteam()
                    }
                }
            }

            Section {
                if applications.isEmpty {
                    ContentUnavailableView(
                        bottle.recipeID == BundledApplicationRecipes.steam.id
                            ? "No Steam games found"
                            : "No Windows applications found",
                        systemImage: "square.grid.2x2",
                        description: Text(
                            bottle.recipeID
                                == BundledApplicationRecipes.steam.id
                                ? "Install a game in Windows Steam, then scan again."
                                : "Install an application in this bottle, then scan again."
                        )
                    )
                } else {
                    ForEach(applications) { application in
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(application.name)
                                Text(applicationStatus(application))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(
                                application.source == .steam ? "Play" : "Open"
                            ) {
                                launch(application)
                            }
                            .disabled(
                                application.installState != .installed
                            )
                            if application.source == .pinned {
                                Button(
                                    "Remove Pin",
                                    systemImage: "pin.slash"
                                ) {
                                    removePin(application)
                                }
                                .labelStyle(.iconOnly)
                            }
                        }
                    }
                }
            } header: {
                HStack {
                    Text("Applications")
                    Spacer()
                    Button("Scan", systemImage: "arrow.clockwise") {
                        refresh()
                    }
                    .labelStyle(.iconOnly)
                    Button("Pin Executable", systemImage: "pin") {
                        chooseExecutable()
                    }
                    .labelStyle(.iconOnly)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(bottle.name)
    }

    private var selectedEngine: EngineDescriptor? {
        installedEngines.first { $0.id == bottle.engineID }
    }

    private var supportedSyncModes: [EnhancedSyncMode] {
        var modes: [EnhancedSyncMode] = [.automatic, .none]
        if selectedEngine?.capabilities.contains(.esync) == true {
            modes.append(.esync)
        }
        if selectedEngine?.capabilities.contains(.msync) == true {
            modes.append(.msync)
        }
        if !modes.contains(bottle.enhancedSync) {
            modes.append(bottle.enhancedSync)
        }
        return modes
    }

    private func applicationStatus(
        _ application: InstalledWindowsApplication
    ) -> String {
        var values = [
            application.source.displayName,
            application.installState.rawValue
        ]
        if let size = application.sizeOnDisk {
            values.append(
                ByteCountFormatter.string(
                    fromByteCount: size,
                    countStyle: .file
                )
            )
        }
        return values.joined(separator: " · ")
    }

    private func chooseExecutable() {
        let panel = NSOpenPanel()
        panel.title = "Choose a Windows executable"
        panel.prompt = "Pin"
        panel.directoryURL = bottle.prefixURL
            .appending(path: "drive_c", directoryHint: .isDirectory)
        panel.allowedContentTypes = [
            UTType(filenameExtension: "exe") ?? .data
        ]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        pin(url)
    }

    private func copyPrefix() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(
            bottle.prefixURL.path,
            forType: .string
        )
    }

    private func revealPrefix() {
        NSWorkspace.shared.activateFileViewerSelecting([
            bottle.prefixURL
        ])
    }
}

private struct WindowsProcessListView: View {
    @ObservedObject var model: AppModel
    let bottle: Bottle

    var body: some View {
        NavigationStack {
            Group {
                if model.isLoadingProcesses {
                    ProgressView("Reading Windows processes…")
                } else if model.windowsProcesses.isEmpty {
                    ContentUnavailableView(
                        "No Windows Processes",
                        systemImage: "list.bullet.rectangle",
                        description: Text("This bottle has no reported processes.")
                    )
                } else {
                    List(model.windowsProcesses) { process in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(process.name)
                                Text("PID \(process.processID)")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Force Quit", role: .destructive) {
                                Task { await model.kill(process, in: bottle) }
                            }
                        }
                    }
                }
            }
            .navigationTitle("\(bottle.name) Processes")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Refresh", systemImage: "arrow.clockwise") {
                        Task { await model.refreshProcesses(in: bottle) }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { model.showsProcessList = false }
                }
            }
        }
        .frame(minWidth: 520, minHeight: 360)
    }
}
