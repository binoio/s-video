import Foundation
import SwiftData

/// Local-only SwiftData container (`cloudKitDatabase: .none`).
/// Keeping SwiftData local allows `@Attribute(.unique)` on `Channel.channelId`
/// and `VideoItem.videoId`, eliminating duplicate records at the database layer.
/// Cross-device sync is handled exclusively by `CloudSyncEngine` via `CKSyncEngine`.
enum LocalStore {
    static let schema = Schema([
        Channel.self,
        VideoItem.self
    ])

    static func makeContainer(inMemory: Bool = false) throws -> ModelContainer {
        if !inMemory,
           let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        }
        let config = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: inMemory,
            cloudKitDatabase: .none
        )
        return try ModelContainer(for: schema, configurations: [config])
    }

    @MainActor
    static func upsertChannel(_ snapshot: ChannelSnapshot, in context: ModelContext) -> Channel {
        let id = snapshot.channelId
        var descriptor = FetchDescriptor<Channel>(predicate: #Predicate { $0.channelId == id })
        descriptor.fetchLimit = 1
        if let existing = try? context.fetch(descriptor).first {
            let merged = SyncConflictResolver.merge(local: existing.snapshot, remote: snapshot)
            existing.title = merged.title
            existing.handle = merged.handle
            existing.feedURLString = merged.feedURLString
            existing.isSubscribed = merged.isSubscribed
            existing.updatedAt = merged.updatedAt
            return existing
        }
        let channel = Channel(
            channelId: snapshot.channelId,
            title: snapshot.title,
            handle: snapshot.handle,
            feedURLString: snapshot.feedURLString,
            addedAt: snapshot.addedAt,
            isSubscribed: snapshot.isSubscribed,
            updatedAt: snapshot.updatedAt
        )
        context.insert(channel)
        return channel
    }

    @MainActor
    static func upsertFeedVideos(_ feedVideos: [FeedVideo], in context: ModelContext) {
        guard !feedVideos.isEmpty else { return }
        let existingVideos = (try? context.fetch(FetchDescriptor<VideoItem>())) ?? []
        var byId = Dictionary(uniqueKeysWithValues: existingVideos.map { ($0.videoId, $0) })

        for feedVideo in feedVideos {
            if let existing = byId[feedVideo.videoId] {
                existing.title = feedVideo.title
                existing.channelTitle = feedVideo.channelTitle
                existing.publishedAt = feedVideo.publishedAt
                existing.videoURLString = feedVideo.videoURLString
                if let media = feedVideo.mediaURLString, !media.isEmpty {
                    existing.mediaURLString = media
                }
                if let thumb = feedVideo.thumbnailURLString, !thumb.isEmpty {
                    existing.thumbnailURLString = thumb
                }
            } else {
                let item = VideoItem(
                    videoId: feedVideo.videoId,
                    channelId: feedVideo.channelId,
                    channelTitle: feedVideo.channelTitle,
                    title: feedVideo.title,
                    publishedAt: feedVideo.publishedAt,
                    thumbnailURLString: feedVideo.thumbnailURLString,
                    videoURLString: feedVideo.videoURLString,
                    mediaURLString: feedVideo.mediaURLString
                )
                context.insert(item)
                byId[feedVideo.videoId] = item
            }
        }
        try? context.save()
    }

    @MainActor
    static func applyRemoteVideoState(_ remote: VideoStateSnapshot, in context: ModelContext) {
        let id = remote.videoId
        var descriptor = FetchDescriptor<VideoItem>(predicate: #Predicate { $0.videoId == id })
        descriptor.fetchLimit = 1
        if let existing = try? context.fetch(descriptor).first {
            let merged = SyncConflictResolver.merge(local: existing.stateSnapshot, remote: remote)
            existing.applyState(merged)
        } else {
            let placeholder = VideoItem(
                videoId: remote.videoId,
                channelId: remote.channelId,
                channelTitle: "",
                title: "",
                publishedAt: remote.completedAt ?? remote.stateUpdatedAt,
                positionSeconds: remote.positionSeconds,
                durationSeconds: remote.durationSeconds,
                watchStatus: remote.watchStatus,
                completedAt: remote.completedAt,
                stateUpdatedAt: remote.stateUpdatedAt
            )
            context.insert(placeholder)
        }
    }
}
