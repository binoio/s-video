import Foundation
import SwiftData

@MainActor
@Observable
final class AppCoordinator {
    private(set) var isRefreshing = false
    private(set) var lastRefreshedAt: Date?
    private(set) var lastRefreshSummary: String?

    private let refreshService = FeedRefreshService()
    private let channelResolver = YouTubeChannelResolver()

    func refreshFeeds(in context: ModelContext) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let channels = ((try? context.fetch(FetchDescriptor<Channel>())) ?? [])
            .map(\.snapshot)
            .filter(\.isSubscribed)

        guard !channels.isEmpty else {
            lastRefreshedAt = .now
            lastRefreshSummary = nil
            return
        }

        let result = await refreshService.refresh(channels: channels)
        LocalStore.upsertFeedVideos(result.videos, in: context)
        lastRefreshedAt = .now
        if result.failedCount > 0 {
            lastRefreshSummary = "Updated \(result.succeededCount) channels (\(result.failedCount) failed)"
        } else {
            lastRefreshSummary = "Updated \(result.succeededCount) channels"
        }
    }

    func syncAndRefresh(syncEngine: CloudSyncEngine, in context: ModelContext) async {
        await syncEngine.fetchChangesNow()
        await refreshFeeds(in: context)
    }

    func subscribe(
        input: String,
        syncEngine: CloudSyncEngine,
        in context: ModelContext
    ) async throws -> Channel {
        let resolved = try await channelResolver.resolve(input: input)
        let now = Date.now
        let snapshot = ChannelSnapshot(
            channelId: resolved.channelId,
            title: resolved.title,
            handle: resolved.handle,
            feedURLString: resolved.feedURLString,
            addedAt: now,
            isSubscribed: true,
            updatedAt: now
        )
        let channel = LocalStore.upsertChannel(snapshot, in: context)
        try? context.save()
        syncEngine.enqueueChannelSave(channel.snapshot)

        let result = await refreshService.refresh(channels: [channel.snapshot])
        LocalStore.upsertFeedVideos(result.videos, in: context)
        return channel
    }

    func unsubscribe(
        _ channel: Channel,
        syncEngine: CloudSyncEngine,
        in context: ModelContext
    ) {
        channel.isSubscribed = false
        channel.updatedAt = .now
        try? context.save()
        syncEngine.enqueueChannelSave(channel.snapshot)
    }

    func importOPML(
        data: Data,
        syncEngine: CloudSyncEngine,
        in context: ModelContext
    ) async throws -> Int {
        let imported = try SubscriptionBackupService.importOPML(data: data)
        for snapshot in imported {
            let channel = LocalStore.upsertChannel(snapshot, in: context)
            syncEngine.enqueueChannelSave(channel.snapshot)
        }
        try? context.save()
        await refreshFeeds(in: context)
        return imported.count
    }

    func importJSON(
        data: Data,
        syncEngine: CloudSyncEngine,
        in context: ModelContext
    ) async throws -> (channels: Int, states: Int) {
        let payload = try SubscriptionBackupService.importJSON(data: data)
        for snapshot in payload.channels {
            let channel = LocalStore.upsertChannel(snapshot, in: context)
            syncEngine.enqueueChannelSave(channel.snapshot)
        }
        for state in payload.videoStates {
            LocalStore.applyRemoteVideoState(state, in: context)
            syncEngine.enqueueVideoStateSave(state)
        }
        try? context.save()
        await refreshFeeds(in: context)
        return (payload.channels.count, payload.videoStates.count)
    }
}
