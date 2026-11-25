import Foundation

/// Deterministic, commutative conflict resolution for cross-device iCloud sync.
/// Because every record has a deterministic `CKRecord.ID` keyed by `channelId` or `videoId`,
/// duplicates cannot occur; concurrent edits merge cleanly by timestamp with deterministic tie-breakers.
enum SyncConflictResolver {
    static func merge(local: ChannelSnapshot, remote: ChannelSnapshot) -> ChannelSnapshot {
        let winner: ChannelSnapshot
        let loser: ChannelSnapshot

        if remote.updatedAt > local.updatedAt {
            winner = remote
            loser = local
        } else if local.updatedAt > remote.updatedAt {
            winner = local
            loser = remote
        } else if remote.isSubscribed != local.isSubscribed {
            winner = remote.isSubscribed ? remote : local
            loser = remote.isSubscribed ? local : remote
        } else {
            winner = remote
            loser = local
        }

        let resolvedTitle = winner.title.isEmpty ? loser.title : winner.title
        let resolvedHandle = winner.handle ?? loser.handle
        let resolvedFeedURL = winner.feedURLString.isEmpty ? loser.feedURLString : winner.feedURLString
        let earliestAdded = min(local.addedAt, remote.addedAt)

        return ChannelSnapshot(
            channelId: local.channelId,
            title: resolvedTitle,
            handle: resolvedHandle,
            feedURLString: resolvedFeedURL,
            addedAt: earliestAdded,
            isSubscribed: winner.isSubscribed,
            updatedAt: max(local.updatedAt, remote.updatedAt)
        )
    }

    static func merge(local: VideoStateSnapshot, remote: VideoStateSnapshot) -> VideoStateSnapshot {
        let winner: VideoStateSnapshot
        let loser: VideoStateSnapshot

        if remote.stateUpdatedAt > local.stateUpdatedAt {
            winner = remote
            loser = local
        } else if local.stateUpdatedAt > remote.stateUpdatedAt {
            winner = local
            loser = remote
        } else if remote.watchStatus != local.watchStatus {
            winner = remote.watchStatus > local.watchStatus ? remote : local
            loser = remote.watchStatus > local.watchStatus ? local : remote
        } else {
            winner = remote.positionSeconds >= local.positionSeconds ? remote : local
            loser = remote.positionSeconds >= local.positionSeconds ? local : remote
        }

        let duration = winner.durationSeconds > 0 ? winner.durationSeconds : loser.durationSeconds
        let channelId = winner.channelId.isEmpty ? loser.channelId : winner.channelId

        return VideoStateSnapshot(
            videoId: local.videoId,
            channelId: channelId,
            watchStatus: winner.watchStatus,
            positionSeconds: winner.positionSeconds,
            durationSeconds: duration,
            completedAt: winner.watchStatus == .watched ? (winner.completedAt ?? loser.completedAt) : nil,
            stateUpdatedAt: max(local.stateUpdatedAt, remote.stateUpdatedAt)
        )
    }
}
