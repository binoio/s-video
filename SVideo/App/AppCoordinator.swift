import Foundation
import SwiftData

enum SourceLimitError: LocalizedError, Equatable {
    case limitReached(limit: Int)

    var errorDescription: String? {
        switch self {
        case .limitReached(let limit):
            return "You've reached the maximum of \(limit) video sources. Remove an existing source before adding another."
        }
    }
}

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
        let currentChannels = (try? context.fetch(FetchDescriptor<Channel>())) ?? []
        let activeChannelIDs = Set(currentChannels.filter(\.isSubscribed).map(\.channelId))
        if activeChannelIDs.count >= Channel.maxSubscribedSources {
            throw SourceLimitError.limitReached(limit: Channel.maxSubscribedSources)
        }

        let resolved = try await channelResolver.resolve(input: input)
        if !activeChannelIDs.contains(resolved.channelId),
           activeChannelIDs.count >= Channel.maxSubscribedSources {
            throw SourceLimitError.limitReached(limit: Channel.maxSubscribedSources)
        }

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
        let deletedVideoIds = LocalStore.deleteVideos(forChannelId: channel.channelId, in: context)
        try? context.save()
        syncEngine.enqueueChannelSave(channel.snapshot)
        syncEngine.enqueueVideoStateDeletes(videoIds: deletedVideoIds)
    }

    func importOPML(
        data: Data,
        syncEngine: CloudSyncEngine,
        in context: ModelContext
    ) async throws -> (imported: Int, skippedDueToLimit: Int) {
        let imported = try SubscriptionBackupService.importOPML(data: data)
        var activeIDs = Set(((try? context.fetch(FetchDescriptor<Channel>())) ?? []).filter(\.isSubscribed).map(\.channelId))
        var importedCount = 0
        var skippedCount = 0

        for snapshot in imported {
            if snapshot.isSubscribed && !activeIDs.contains(snapshot.channelId) {
                if activeIDs.count >= Channel.maxSubscribedSources {
                    skippedCount += 1
                    continue
                }
                activeIDs.insert(snapshot.channelId)
            }
            let channel = LocalStore.upsertChannel(snapshot, in: context)
            syncEngine.enqueueChannelSave(channel.snapshot)
            importedCount += 1
        }
        try? context.save()
        await refreshFeeds(in: context)
        return (importedCount, skippedCount)
    }

    func importJSON(
        data: Data,
        syncEngine: CloudSyncEngine,
        in context: ModelContext
    ) async throws -> (channels: Int, states: Int, skippedChannelsDueToLimit: Int) {
        let payload = try SubscriptionBackupService.importJSON(data: data)
        var activeIDs = Set(((try? context.fetch(FetchDescriptor<Channel>())) ?? []).filter(\.isSubscribed).map(\.channelId))
        var importedChannels = 0
        var skippedChannels = 0

        for snapshot in payload.channels {
            if snapshot.isSubscribed && !activeIDs.contains(snapshot.channelId) {
                if activeIDs.count >= Channel.maxSubscribedSources {
                    skippedChannels += 1
                    continue
                }
                activeIDs.insert(snapshot.channelId)
            }
            let channel = LocalStore.upsertChannel(snapshot, in: context)
            syncEngine.enqueueChannelSave(channel.snapshot)
            importedChannels += 1
        }
        for state in payload.videoStates {
            LocalStore.applyRemoteVideoState(state, in: context)
            syncEngine.enqueueVideoStateSave(state)
        }
        try? context.save()
        await refreshFeeds(in: context)
        return (importedChannels, payload.videoStates.count, skippedChannels)
    }
}
