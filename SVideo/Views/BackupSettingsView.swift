import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct BackupSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(CloudSyncEngine.self) private var syncEngine

    @AppStorage("recentlyCompletedDays") private var recentlyCompletedDays = 7
    @AppStorage("confirmBeforeDeletingSources") private var confirmBeforeDeletingSources = true
    @AppStorage("autoHideSidebar") private var autoHideSidebar = false

    @Query private var channels: [Channel]
    @Query private var videos: [VideoItem]

    @State private var isCheckingCloud = false
    @State private var existingCloudSummary: CloudDataSummary?
    @State private var showEnableExistingDataDialog = false
    @State private var showDisableExistingDataDialog = false
    @State private var showFinalConfirmClearOnDisable = false
    @State private var showFinalConfirmStartFresh = false

    @State private var opmlExportDocument: BinaryExportDocument?
    @State private var jsonExportDocument: BinaryExportDocument?
    @State private var cloudBackupExportDocument: BinaryExportDocument?
    @State private var isExportingOPML = false
    @State private var isExportingJSON = false
    @State private var isExportingCloudBackupBeforeFreshStart = false
    @State private var isImportingOPML = false
    @State private var isImportingJSON = false
    @State private var statusBanner: String?
    @State private var isErrorBanner = false

    private var icloudSyncBinding: Binding<Bool> {
        Binding(
            get: { syncEngine.isEnabled && syncEngine.isAccountAvailable },
            set: { newValue in
                handleSyncToggleRequest(enable: newValue)
            }
        )
    }

    var body: some View {
        Form {
            Section {
                HStack {
                    Toggle("iCloud Sync", isOn: icloudSyncBinding)
                        .disabled(!syncEngine.isAccountAvailable || isCheckingCloud)

                    if isCheckingCloud {
                        ProgressView()
                            .padding(.leading, 8)
                    }
                }

                if syncEngine.isEnabled && syncEngine.isAccountAvailable {
                    HStack {
                        Label(syncEngine.status.label, systemImage: syncEngine.status.systemImage)
                            .font(.subheadline)
                            .foregroundStyle(syncEngine.status.isProblem ? .red : .secondary)
                        Spacer()
                        if let lastSyncedAt = syncEngine.lastSyncedAt {
                            Text(lastSyncedAt.formatted(.relative(presentation: .named)))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Button {
                        Task {
                            await coordinator.syncAndRefresh(syncEngine: syncEngine, in: modelContext)
                        }
                    } label: {
                        Label("Sync Now", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
            } footer: {
                if !syncEngine.isAccountAvailable {
                    Text(syncEngine.status.label)
                } else {
                    Text("Syncs your video sources and watch progress across iPads using iCloud.")
                }
            }

            Section("General") {
                Toggle("Auto Hide Sidebar", isOn: $autoHideSidebar)
                Toggle("Confirm Before Deleting Sources", isOn: $confirmBeforeDeletingSources)
                Picker("Show Recently Completed For", selection: $recentlyCompletedDays) {
                    Text("3 Days").tag(3)
                    Text("7 Days").tag(7)
                    Text("14 Days").tag(14)
                    Text("30 Days").tag(30)
                }
            }

            Section {
                Button {
                    let data = SubscriptionBackupService.exportOPML(channels: channels.map(\.snapshot))
                    opmlExportDocument = BinaryExportDocument(data: data)
                    isExportingOPML = true
                } label: {
                    Label("Export Sources (OPML)", systemImage: "square.and.arrow.up")
                }

                Button {
                    isImportingOPML = true
                } label: {
                    Label("Import Sources (OPML)", systemImage: "square.and.arrow.down")
                }

                Button {
                    do {
                        let data = try SubscriptionBackupService.exportJSON(
                            channels: channels.map(\.snapshot),
                            videoStates: videos.filter { $0.watchStatus != .unwatched }.map(\.stateSnapshot)
                        )
                        jsonExportDocument = BinaryExportDocument(data: data)
                        isExportingJSON = true
                    } catch {
                        showBanner("Export failed: \(error.localizedDescription)", isError: true)
                    }
                } label: {
                    Label("Export Full Backup (JSON)", systemImage: "externaldrive.badge.icloud")
                }

                Button {
                    isImportingJSON = true
                } label: {
                    Label("Import Full Backup (JSON)", systemImage: "arrow.down.doc")
                }
            } header: {
                Text("Backup & Import / Export")
            } footer: {
                Text("OPML files work with standard RSS/Atom readers and subscription exports. JSON backups include video sources and watched/in-progress states.")
            }

            if let statusBanner {
                Section {
                    Text(statusBanner)
                        .foregroundStyle(isErrorBanner ? .red : .green)
                }
            }
        }
        .navigationTitle("Sync & Backup")
        .confirmationDialog(
            "Existing iCloud Data Found",
            isPresented: $showEnableExistingDataDialog,
            titleVisibility: .visible
        ) {
            Button("Merge") {
                Task {
                    await syncEngine.enableSync(startFresh: false)
                    await coordinator.refreshFeeds(in: modelContext)
                    showBanner("iCloud Sync enabled and merged.", isError: false)
                }
            }
            Button("Backup & Start Fresh", role: .destructive) {
                prepareCloudBackupForFreshStart()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let summary = existingCloudSummary {
                Text("Found \(summary.channelCount) feeds and \(summary.videoStateCount) video states in iCloud from a previous device or install. Merge with this iPad, or back up the existing iCloud data and start fresh?")
            } else {
                Text("Existing S-Video data was found in iCloud. Merge with this iPad, or back up and start fresh?")
            }
        }
        .confirmationDialog(
            "Disable iCloud Sync",
            isPresented: $showDisableExistingDataDialog,
            titleVisibility: .visible
        ) {
            Button("Keep iCloud Data") {
                Task {
                    await syncEngine.disableSync(clearCloudData: false)
                    showBanner("iCloud Sync disabled. Existing iCloud data was left untouched.", isError: false)
                }
            }
            Button("Clear iCloud Data", role: .destructive) {
                showFinalConfirmClearOnDisable = true
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Existing S-Video data is stored in iCloud. Would you like to leave it untouched for other iPads or clear it?")
        }
        .alert(
            "Permanently Clear iCloud Data?",
            isPresented: $showFinalConfirmClearOnDisable
        ) {
            Button("Permanently Clear iCloud Data", role: .destructive) {
                Task {
                    await syncEngine.disableSync(clearCloudData: true)
                    showBanner("iCloud Sync disabled and iCloud data permanently cleared.", isError: false)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently delete all synced video sources and watch progress from iCloud across all of your iPads. This action cannot be undone.")
        }
        .alert(
            "Replace Existing iCloud Data?",
            isPresented: $showFinalConfirmStartFresh
        ) {
            Button("Clear iCloud & Start Fresh", role: .destructive) {
                Task {
                    await syncEngine.enableSync(startFresh: true)
                    await coordinator.refreshFeeds(in: modelContext)
                    showBanner("Backed up previous iCloud data and started fresh.", isError: false)
                }
            }
            Button("Cancel", role: .cancel) {
                showBanner("Backup saved. Existing iCloud data was not cleared and iCloud Sync remains off.", isError: false)
            }
        } message: {
            Text("Your backup was saved. Continuing will permanently erase the previous iCloud data and replace it with this iPad's current library. This cannot be undone.")
        }
        .fileExporter(
            isPresented: $isExportingCloudBackupBeforeFreshStart,
            document: cloudBackupExportDocument,
            contentType: .json,
            defaultFilename: "S-Video-iCloud-Backup.json"
        ) { result in
            switch result {
            case .success:
                showFinalConfirmStartFresh = true
            case .failure(let error):
                showBanner("Backup cancelled (\(error.localizedDescription)). iCloud Sync was not enabled.", isError: true)
            }
        }
        .fileExporter(
            isPresented: $isExportingOPML,
            document: opmlExportDocument,
            contentType: .opml,
            defaultFilename: "S-Video-Subscriptions.opml"
        ) { result in
            handleExportResult(result, label: "OPML subscriptions")
        }
        .fileExporter(
            isPresented: $isExportingJSON,
            document: jsonExportDocument,
            contentType: .json,
            defaultFilename: "S-Video-Backup.json"
        ) { result in
            handleExportResult(result, label: "JSON backup")
        }
        .fileImporter(
            isPresented: $isImportingOPML,
            allowedContentTypes: [.opml, .xml]
        ) { result in
            handleOPMLImport(result)
        }
        .fileImporter(
            isPresented: $isImportingJSON,
            allowedContentTypes: [.json]
        ) { result in
            handleJSONImport(result)
        }
        .task {
            await syncEngine.refreshAccountStatus()
        }
    }

    private func handleSyncToggleRequest(enable: Bool) {
        guard !isCheckingCloud else { return }
        isCheckingCloud = true

        Task {
            defer { isCheckingCloud = false }
            do {
                let summary = try await syncEngine.inspectExistingCloudData()
                existingCloudSummary = summary

                if enable {
                    if summary.hasData {
                        showEnableExistingDataDialog = true
                    } else {
                        await syncEngine.enableSync(startFresh: false)
                        await coordinator.refreshFeeds(in: modelContext)
                        showBanner("iCloud Sync enabled.", isError: false)
                    }
                } else {
                    if summary.hasData {
                        showDisableExistingDataDialog = true
                    } else {
                        await syncEngine.disableSync(clearCloudData: false)
                        showBanner("iCloud Sync disabled.", isError: false)
                    }
                }
            } catch {
                showBanner("Could not check iCloud data: \(error.localizedDescription)", isError: true)
            }
        }
    }

    private func prepareCloudBackupForFreshStart() {
        isCheckingCloud = true
        Task {
            defer { isCheckingCloud = false }
            do {
                let payload = try await syncEngine.fetchExistingCloudPayload()
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                let data = try encoder.encode(payload)
                cloudBackupExportDocument = BinaryExportDocument(data: data)
                isExportingCloudBackupBeforeFreshStart = true
            } catch {
                showBanner("Failed to back up iCloud data: \(error.localizedDescription)", isError: true)
            }
        }
    }

    private func handleExportResult(_ result: Result<URL, Error>, label: String) {
        switch result {
        case .success:
            showBanner("Exported \(label).", isError: false)
        case .failure(let error):
            showBanner("Export failed: \(error.localizedDescription)", isError: true)
        }
    }

    private func handleOPMLImport(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            Task {
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                do {
                    let data = try Data(contentsOf: url)
                    let count = try await coordinator.importOPML(
                        data: data,
                        syncEngine: syncEngine,
                        in: modelContext
                    )
                    showBanner("Imported \(count) feeds from OPML.", isError: false)
                } catch {
                    showBanner("OPML import failed: \(error.localizedDescription)", isError: true)
                }
            }
        case .failure(let error):
            showBanner("Import cancelled: \(error.localizedDescription)", isError: true)
        }
    }

    private func handleJSONImport(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            Task {
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                do {
                    let data = try Data(contentsOf: url)
                    let imported = try await coordinator.importJSON(
                        data: data,
                        syncEngine: syncEngine,
                        in: modelContext
                    )
                    showBanner(
                        "Imported \(imported.channels) feeds and \(imported.states) video states.",
                        isError: false
                    )
                } catch {
                    showBanner("JSON import failed: \(error.localizedDescription)", isError: true)
                }
            }
        case .failure(let error):
            showBanner("Import cancelled: \(error.localizedDescription)", isError: true)
        }
    }

    private func showBanner(_ message: String, isError: Bool) {
        statusBanner = message
        isErrorBanner = isError
    }
}

struct BinaryExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.opml, .xml, .json, .data] }

    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        self.data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
