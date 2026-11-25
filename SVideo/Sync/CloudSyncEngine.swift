import CloudKit
import Foundation
import OSLog
import SwiftData

enum SyncStatus: Equatable, Sendable {
    case disabled
    case idle
    case syncing
    case synced(Date)
    case unavailable(String)
    case error(String)

    var label: String {
        switch self {
        case .disabled: "iCloud Sync Off"
        case .idle: "iCloud Ready"
        case .syncing: "Syncing…"
        case .synced: "iCloud Synced"
        case .unavailable(let reason): reason
        case .error(let message): "Sync Error: \(message)"
        }
    }

    var systemImage: String {
        switch self {
        case .disabled: "icloud"
        case .idle, .synced: "checkmark.icloud"
        case .syncing: "arrow.triangle.2.circlepath.icloud"
        case .unavailable: "icloud.slash"
        case .error: "exclamationmark.icloud"
        }
    }

    var isProblem: Bool {
        switch self {
        case .unavailable, .error: true
        default: false
        }
    }
}

struct CloudDataSummary: Sendable, Equatable {
    let channelCount: Int
    let videoStateCount: Int

    var hasData: Bool {
        channelCount > 0 || videoStateCount > 0
    }
}

/// Direct `CKSyncEngine`-backed iCloud sync coordinator.
/// Syncs ONLY subscriptions (`SVChannel`) and lightweight playback states (`SVVideoState`)
/// using deterministic `CKRecord.ID`s in `SVideoZone` — zero duplicates and seconds-fast
/// cold-start onboarding on new iPads.
@MainActor
@Observable
final class CloudSyncEngine: NSObject {
    private let logger = Logger(subsystem: "SVideo", category: "CloudSync")
    private static let enabledDefaultsKey = "icloudSyncEnabled"

    private(set) var status: SyncStatus = .disabled
    private(set) var lastSyncedAt: Date?
    private(set) var isAccountAvailable: Bool = false
    private(set) var isEnabled: Bool = UserDefaults.standard.bool(forKey: CloudSyncEngine.enabledDefaultsKey)

    @ObservationIgnored private var syncEngine: CKSyncEngine?
    @ObservationIgnored private var modelContext: ModelContext?
    @ObservationIgnored private var onChannelsUpdated: (@MainActor () -> Void)?
    @ObservationIgnored private var systemFieldsCache: [String: Data] = [:]
    @ObservationIgnored private var accountObserver: NSObjectProtocol?

    private static var appSupportDir: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("SVideoSync", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static var stateSerializationURL: URL {
        appSupportDir.appendingPathComponent("ck-sync-state.data")
    }

    private static var systemFieldsURL: URL {
        appSupportDir.appendingPathComponent("ck-system-fields.plist")
    }

    func start(modelContext: ModelContext, onChannelsUpdated: @escaping @MainActor () -> Void) {
        self.modelContext = modelContext
        self.onChannelsUpdated = onChannelsUpdated
        loadSystemFieldsCache()

        if accountObserver == nil {
            accountObserver = NotificationCenter.default.addObserver(
                forName: .CKAccountChanged,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    await self?.refreshAccountStatus()
                }
            }
        }

        Task {
            await refreshAccountStatus()
        }
    }

    func refreshAccountStatus() async {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            isAccountAvailable = false
            status = .unavailable("Disabled in unit test runner")
            return
        }

        let container = CKContainer.default()
        do {
            let accountStatus = try await container.accountStatus()
            switch accountStatus {
            case .available:
                isAccountAvailable = true
                if isEnabled {
                    initializeEngineIfNeeded(container: container)
                    await fetchChangesNow()
                } else {
                    status = .disabled
                }
            case .noAccount:
                isAccountAvailable = false
                syncEngine = nil
                status = .unavailable("Sign in to iCloud in Settings")
            case .restricted:
                isAccountAvailable = false
                syncEngine = nil
                status = .unavailable("iCloud is restricted on this iPad")
            case .temporarilyUnavailable:
                isAccountAvailable = false
                status = .unavailable("iCloud temporarily unavailable")
            case .couldNotDetermine:
                isAccountAvailable = false
                status = .unavailable("Could not determine iCloud status")
            @unknown default:
                isAccountAvailable = false
                status = .unavailable("iCloud unavailable")
            }
        } catch {
            logger.error("accountStatus failed: \(error.localizedDescription)")
            isAccountAvailable = false
            status = .unavailable("iCloud not configured")
        }
    }

    // MARK: - Inspect / Backup / Enable / Disable Flows

    /// Inspects `SVideoZone` in the user's private CloudKit database for existing records.
    func inspectExistingCloudData() async throws -> CloudDataSummary {
        let payload = try await fetchExistingCloudPayload()
        return CloudDataSummary(
            channelCount: payload.channels.count,
            videoStateCount: payload.videoStates.count
        )
    }

    /// Fetches all existing `SVChannel` and `SVVideoState` records from `SVideoZone`
    /// so the user can export a JSON backup before choosing "Backup & Start Fresh".
    func fetchExistingCloudPayload() async throws -> SVideoBackupPayload {
        let database = CKContainer.default().privateCloudDatabase

        // Verify zone exists first; a missing zone means no prior iCloud data
        do {
            _ = try await database.recordZone(for: CloudRecordCodec.zoneID)
        } catch let ckError as CKError where ckError.code == .zoneNotFound || ckError.code == .userDeletedZone {
            return SVideoBackupPayload(
                version: SVideoBackupPayload.currentVersion,
                exportedAt: .now,
                channels: [],
                videoStates: []
            )
        }

        let channels: [ChannelSnapshot] = try await fetchAllRecords(
            ofType: CloudRecordCodec.channelRecordType,
            in: database
        ).compactMap { CloudRecordCodec.decodeChannel(from: $0) }

        let states: [VideoStateSnapshot] = try await fetchAllRecords(
            ofType: CloudRecordCodec.videoStateRecordType,
            in: database
        ).compactMap { CloudRecordCodec.decodeVideoState(from: $0) }

        return SVideoBackupPayload(
            version: SVideoBackupPayload.currentVersion,
            exportedAt: .now,
            channels: channels,
            videoStates: states
        )
    }

    private func fetchAllRecords(ofType recordType: String, in database: CKDatabase) async throws -> [CKRecord] {
        var collected: [CKRecord] = []
        let query = CKQuery(recordType: recordType, predicate: NSPredicate(value: true))
        do {
            var (results, cursor) = try await database.records(matching: query, inZoneWith: CloudRecordCodec.zoneID)
            for (_, result) in results {
                if case .success(let record) = result {
                    collected.append(record)
                }
            }
            while let activeCursor = cursor {
                let next = try await database.records(continuingMatchFrom: activeCursor)
                for (_, result) in next.matchResults {
                    if case .success(let record) = result {
                        collected.append(record)
                    }
                }
                cursor = next.queryCursor
            }
        } catch let ckError as CKError where ckError.code == .unknownItem || ckError.code == .zoneNotFound {
            // Record type hasn't been created in this private DB yet
            return []
        }
        return collected
    }

    /// Enables iCloud Sync. If `startFresh` is true, atomically deletes `SVideoZone` first
    /// so CloudKit starts cleanly from this iPad's local library.
    func enableSync(startFresh: Bool) async {
        guard isAccountAvailable else { return }
        status = .syncing

        if startFresh {
            await clearCloudZoneAndLocalSyncMetadata()
        }

        isEnabled = true
        UserDefaults.standard.set(true, forKey: Self.enabledDefaultsKey)

        let container = CKContainer.default()
        initializeEngineIfNeeded(container: container)
        enqueueAllLocalRecords()
        await fetchChangesNow()
    }

    /// Disables iCloud Sync on this iPad, optionally clearing `SVideoZone` in iCloud.
    func disableSync(clearCloudData: Bool) async {
        isEnabled = false
        UserDefaults.standard.set(false, forKey: Self.enabledDefaultsKey)
        syncEngine = nil

        if clearCloudData {
            status = .syncing
            await clearCloudZoneAndLocalSyncMetadata()
        }

        lastSyncedAt = nil
        status = .disabled
    }

    private func clearCloudZoneAndLocalSyncMetadata() async {
        let database = CKContainer.default().privateCloudDatabase
        do {
            try await database.deleteRecordZone(withID: CloudRecordCodec.zoneID)
        } catch let ckError as CKError where ckError.code == .zoneNotFound || ckError.code == .userDeletedZone {
            // Already empty
        } catch {
            logger.error("Failed to delete SVideoZone: \(error.localizedDescription)")
        }
        try? FileManager.default.removeItem(at: Self.stateSerializationURL)
        systemFieldsCache.removeAll()
        persistSystemFieldsCache()
        syncEngine = nil
    }

    private func enqueueAllLocalRecords() {
        guard let context = modelContext, let engine = syncEngine else { return }
        var changes: [CKSyncEngine.PendingRecordZoneChange] = []

        if let channels = try? context.fetch(FetchDescriptor<Channel>()) {
            changes.append(contentsOf: channels.map { .saveRecord(CloudRecordCodec.channelRecordID(for: $0.channelId)) })
        }
        if let videos = try? context.fetch(FetchDescriptor<VideoItem>()) {
            let stateful = videos.filter { $0.watchStatus != .unwatched || $0.positionSeconds > 0 }
            changes.append(contentsOf: stateful.map { .saveRecord(CloudRecordCodec.videoStateRecordID(for: $0.videoId)) })
        }
        if !changes.isEmpty {
            engine.state.add(pendingRecordZoneChanges: changes)
        }
    }

    private func initializeEngineIfNeeded(container: CKContainer) {
        guard syncEngine == nil else { return }
        let savedState = loadStateSerialization()
        let configuration = CKSyncEngine.Configuration(
            database: container.privateCloudDatabase,
            stateSerialization: savedState,
            delegate: self
        )
        let engine = CKSyncEngine(configuration)
        syncEngine = engine
        ensureZoneScheduled(in: engine)
        logger.info("CKSyncEngine initialized (coldStart=\(savedState == nil))")
    }

    private func ensureZoneScheduled(in engine: CKSyncEngine) {
        let zone = CKRecordZone(zoneID: CloudRecordCodec.zoneID)
        engine.state.add(pendingDatabaseChanges: [.saveZone(zone)])
    }

    func enqueueChannelSave(_ snapshot: ChannelSnapshot) {
        guard isEnabled, let engine = syncEngine else { return }
        let recordID = CloudRecordCodec.channelRecordID(for: snapshot.channelId)
        engine.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
    }

    func enqueueVideoStateSave(_ snapshot: VideoStateSnapshot) {
        guard isEnabled, let engine = syncEngine else { return }
        let recordID = CloudRecordCodec.videoStateRecordID(for: snapshot.videoId)
        engine.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
    }

    func fetchChangesNow() async {
        guard isEnabled, let engine = syncEngine else { return }
        status = .syncing
        do {
            try await engine.fetchChanges()
            try await engine.sendChanges()
            let now = Date.now
            lastSyncedAt = now
            status = .synced(now)
        } catch {
            logger.error("Manual sync failed: \(error.localizedDescription)")
            status = .error(error.localizedDescription)
        }
    }

    // MARK: - Persistence Helpers

    private func loadStateSerialization() -> CKSyncEngine.State.Serialization? {
        guard let data = try? Data(contentsOf: Self.stateSerializationURL) else { return nil }
        return try? PropertyListDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
    }

    private func saveStateSerialization(_ state: CKSyncEngine.State.Serialization) {
        guard let data = try? PropertyListEncoder().encode(state) else { return }
        try? data.write(to: Self.stateSerializationURL, options: .atomic)
    }

    private func loadSystemFieldsCache() {
        guard let data = try? Data(contentsOf: Self.systemFieldsURL),
              let decoded = try? PropertyListDecoder().decode([String: Data].self, from: data) else {
            return
        }
        systemFieldsCache = decoded
    }

    private func persistSystemFieldsCache() {
        guard let data = try? PropertyListEncoder().encode(systemFieldsCache) else { return }
        try? data.write(to: Self.systemFieldsURL, options: .atomic)
    }
}

// MARK: - CKSyncEngineDelegate

extension CloudSyncEngine: CKSyncEngineDelegate {
    nonisolated func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) {
        Task { @MainActor in
            self.processEvent(event, syncEngine: syncEngine)
        }
    }

    nonisolated func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        await buildNextBatch(context: context, syncEngine: syncEngine)
    }

    private func processEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) {
        switch event {
        case .stateUpdate(let update):
            saveStateSerialization(update.stateSerialization)

        case .accountChange(let change):
            switch change.changeType {
            case .signIn:
                isAccountAvailable = true
                if isEnabled {
                    ensureZoneScheduled(in: syncEngine)
                    Task { await fetchChangesNow() }
                }
            case .signOut:
                isAccountAvailable = false
                status = .unavailable("Signed out of iCloud")
            case .switchAccounts:
                systemFieldsCache.removeAll()
                persistSystemFieldsCache()
                if isEnabled {
                    Task { await fetchChangesNow() }
                }
            @unknown default:
                break
            }

        case .willFetchChanges, .willSendChanges:
            if isEnabled { status = .syncing }

        case .fetchedRecordZoneChanges(let changes):
            applyFetchedChanges(changes)

        case .sentRecordZoneChanges(let sent):
            handleSentChanges(sent, syncEngine: syncEngine)

        case .didFetchChanges, .didSendChanges:
            let now = Date.now
            lastSyncedAt = now
            if isEnabled, !status.isProblem {
                status = .synced(now)
            }

        case .fetchedDatabaseChanges(let dbChanges):
            for deletion in dbChanges.deletions where deletion.zoneID == CloudRecordCodec.zoneID {
                if isEnabled { ensureZoneScheduled(in: syncEngine) }
            }

        case .sentDatabaseChanges, .willFetchRecordZoneChanges, .didFetchRecordZoneChanges:
            break

        @unknown default:
            break
        }
    }

    private func applyFetchedChanges(_ changes: CKSyncEngine.Event.FetchedRecordZoneChanges) {
        guard let context = modelContext else { return }
        var channelsChanged = false

        for modification in changes.modifications {
            let record = modification.record
            systemFieldsCache[record.recordID.recordName] = CloudRecordCodec.encodeSystemFields(of: record)

            if let channel = CloudRecordCodec.decodeChannel(from: record) {
                _ = LocalStore.upsertChannel(channel, in: context)
                channelsChanged = true
            } else if let videoState = CloudRecordCodec.decodeVideoState(from: record) {
                LocalStore.applyRemoteVideoState(videoState, in: context)
            }
        }

        for deletion in changes.deletions {
            systemFieldsCache.removeValue(forKey: deletion.recordID.recordName)
            if let cid = CloudRecordCodec.channelId(from: deletion.recordID) {
                var descriptor = FetchDescriptor<Channel>(predicate: #Predicate { $0.channelId == cid })
                descriptor.fetchLimit = 1
                if let channel = try? context.fetch(descriptor).first {
                    channel.isSubscribed = false
                    channel.updatedAt = .now
                    channelsChanged = true
                }
            }
        }

        try? context.save()
        persistSystemFieldsCache()

        if channelsChanged {
            onChannelsUpdated?()
        }
    }

    private func handleSentChanges(
        _ sent: CKSyncEngine.Event.SentRecordZoneChanges,
        syncEngine: CKSyncEngine
    ) {
        guard let context = modelContext else { return }
        var retryIDs: [CKRecord.ID] = []

        for saved in sent.savedRecords {
            systemFieldsCache[saved.recordID.recordName] = CloudRecordCodec.encodeSystemFields(of: saved)
        }

        for failed in sent.failedRecordSaves {
            let error = failed.error
            switch error.code {
            case .serverRecordChanged:
                if let serverRecord = error.serverRecord {
                    systemFieldsCache[serverRecord.recordID.recordName] = CloudRecordCodec.encodeSystemFields(of: serverRecord)
                    if let remoteChannel = CloudRecordCodec.decodeChannel(from: serverRecord) {
                        _ = LocalStore.upsertChannel(remoteChannel, in: context)
                        retryIDs.append(serverRecord.recordID)
                    } else if let remoteState = CloudRecordCodec.decodeVideoState(from: serverRecord) {
                        LocalStore.applyRemoteVideoState(remoteState, in: context)
                        retryIDs.append(serverRecord.recordID)
                    }
                }
            case .zoneNotFound:
                ensureZoneScheduled(in: syncEngine)
                retryIDs.append(failed.record.recordID)
            case .unknownItem:
                systemFieldsCache.removeValue(forKey: failed.record.recordID.recordName)
                retryIDs.append(failed.record.recordID)
            default:
                logger.error("Failed to save \(failed.record.recordID.recordName): \(error.localizedDescription)")
                status = .error(error.localizedDescription)
            }
        }

        try? context.save()
        persistSystemFieldsCache()

        if !retryIDs.isEmpty {
            syncEngine.state.add(pendingRecordZoneChanges: retryIDs.map { .saveRecord($0) })
        }
    }

    private func buildNextBatch(
        context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        guard let modelContext else { return nil }
        let scope = context.options.scope
        let pending = syncEngine.state.pendingRecordZoneChanges.filter { scope.contains($0) }
        guard !pending.isEmpty else { return nil }

        var recordsByID: [CKRecord.ID: CKRecord] = [:]
        for change in pending {
            guard case .saveRecord(let recordID) = change else { continue }
            let cachedFields = systemFieldsCache[recordID.recordName]
            if let cid = CloudRecordCodec.channelId(from: recordID) {
                var descriptor = FetchDescriptor<Channel>(predicate: #Predicate { $0.channelId == cid })
                descriptor.fetchLimit = 1
                if let channel = try? modelContext.fetch(descriptor).first {
                    recordsByID[recordID] = CloudRecordCodec.encode(channel.snapshot, existingSystemFields: cachedFields)
                }
            } else if let vid = CloudRecordCodec.videoId(from: recordID) {
                var descriptor = FetchDescriptor<VideoItem>(predicate: #Predicate { $0.videoId == vid })
                descriptor.fetchLimit = 1
                if let video = try? modelContext.fetch(descriptor).first {
                    recordsByID[recordID] = CloudRecordCodec.encode(video.stateSnapshot, existingSystemFields: cachedFields)
                }
            }
        }

        let snapshotMap = recordsByID
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pending) { recordID in
            snapshotMap[recordID]
        }
    }
}
