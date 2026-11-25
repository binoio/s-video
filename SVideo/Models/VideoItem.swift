import Foundation
import SwiftData

@Model
final class VideoItem {
    @Attribute(.unique) var videoId: String
    var channelId: String
    var channelTitle: String
    var title: String
    var publishedAt: Date
    var thumbnailURLString: String
    var videoURLString: String
    var mediaURLString: String?
    var positionSeconds: Double
    var durationSeconds: Double
    var watchStatusRaw: Int
    var completedAt: Date?
    var stateUpdatedAt: Date

    init(
        videoId: String,
        channelId: String,
        channelTitle: String,
        title: String,
        publishedAt: Date,
        thumbnailURLString: String? = nil,
        videoURLString: String? = nil,
        mediaURLString: String? = nil,
        positionSeconds: Double = 0,
        durationSeconds: Double = 0,
        watchStatus: WatchStatus = .unwatched,
        completedAt: Date? = nil,
        stateUpdatedAt: Date = .distantPast
    ) {
        self.videoId = videoId
        self.channelId = channelId
        self.channelTitle = channelTitle
        self.title = title
        self.publishedAt = publishedAt
        self.thumbnailURLString = thumbnailURLString ?? ""
        self.videoURLString = videoURLString ?? "https://youtu.be/\(videoId)"
        self.mediaURLString = mediaURLString
        self.positionSeconds = positionSeconds
        self.durationSeconds = durationSeconds
        self.watchStatusRaw = watchStatus.rawValue
        self.completedAt = completedAt
        self.stateUpdatedAt = stateUpdatedAt
    }

    var watchStatus: WatchStatus {
        get { WatchStatus(rawValue: watchStatusRaw) ?? .unwatched }
        set { watchStatusRaw = newValue.rawValue }
    }

    var thumbnailURL: URL? {
        thumbnailURLString.isEmpty ? nil : URL(string: thumbnailURLString)
    }

    var mediaURL: URL? {
        mediaURLString.flatMap { $0.isEmpty ? nil : URL(string: $0) }
    }

    var youtubeVideoId: String? {
        VideoLinkBuilder.youtubeVideoID(from: videoURLString)
    }

    var progressFraction: Double {
        guard durationSeconds > 0 else { return watchStatus == .watched ? 1.0 : 0.0 }
        return min(1.0, max(0.0, positionSeconds / durationSeconds))
    }

    var stateSnapshot: VideoStateSnapshot {
        VideoStateSnapshot(
            videoId: videoId,
            channelId: channelId,
            watchStatus: watchStatus,
            positionSeconds: positionSeconds,
            durationSeconds: durationSeconds,
            completedAt: completedAt,
            stateUpdatedAt: stateUpdatedAt
        )
    }

    func applyState(_ state: VideoStateSnapshot) {
        watchStatus = state.watchStatus
        positionSeconds = state.positionSeconds
        if state.durationSeconds > 0 {
            durationSeconds = state.durationSeconds
        }
        completedAt = state.completedAt
        stateUpdatedAt = state.stateUpdatedAt
    }
}

struct VideoStateSnapshot: Codable, Sendable, Equatable, Hashable, Identifiable {
    var id: String { videoId }
    let videoId: String
    let channelId: String
    let watchStatus: WatchStatus
    let positionSeconds: Double
    let durationSeconds: Double
    let completedAt: Date?
    let stateUpdatedAt: Date
}
