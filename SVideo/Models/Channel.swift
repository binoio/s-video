import Foundation
import SwiftData

@Model
final class Channel {
    @Attribute(.unique) var channelId: String
    var title: String
    var handle: String?
    var feedURLString: String
    var addedAt: Date
    var isSubscribed: Bool
    var updatedAt: Date

    init(
        channelId: String,
        title: String,
        handle: String? = nil,
        feedURLString: String? = nil,
        addedAt: Date = .now,
        isSubscribed: Bool = true,
        updatedAt: Date = .now
    ) {
        self.channelId = channelId
        self.title = title
        self.handle = handle
        self.feedURLString = feedURLString ?? Channel.defaultFeedURLString(for: channelId)
        self.addedAt = addedAt
        self.isSubscribed = isSubscribed
        self.updatedAt = updatedAt
    }

    static func defaultFeedURLString(for channelId: String) -> String {
        "https://www.youtube.com/feeds/videos.xml?channel_id=\(channelId)"
    }

    var feedURL: URL? {
        URL(string: feedURLString)
    }

    var channelURL: URL? {
        if YouTubeChannelResolver.isChannelId(channelId) {
            return URL(string: "https://www.youtube.com/channel/\(channelId)")
        }
        return URL(string: feedURLString)
    }

    var snapshot: ChannelSnapshot {
        ChannelSnapshot(
            channelId: channelId,
            title: title,
            handle: handle,
            feedURLString: feedURLString,
            addedAt: addedAt,
            isSubscribed: isSubscribed,
            updatedAt: updatedAt
        )
    }
}

struct ChannelSnapshot: Codable, Sendable, Equatable, Hashable, Identifiable {
    var id: String { channelId }
    let channelId: String
    let title: String
    let handle: String?
    let feedURLString: String
    let addedAt: Date
    let isSubscribed: Bool
    let updatedAt: Date
}
