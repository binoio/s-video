import Foundation
import SwiftData
import XCTest
@testable import S_Video

final class YouTubeRSSAndBackupTests: XCTestCase {
    func testAtomParserIncludesAllEntriesWithoutFiltering() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <feed xmlns:yt="http://www.youtube.com/xml/schemas/2015"
              xmlns:media="http://search.yahoo.com/mrss/"
              xmlns="http://www.w3.org/2005/Atom">
          <yt:channelId>UC1234567890123456789012</yt:channelId>
          <title>Sample Creator</title>
          <entry>
            <yt:videoId>vidRegular01</yt:videoId>
            <yt:channelId>UC1234567890123456789012</yt:channelId>
            <title>Full Episode #1</title>
            <link rel="alternate" href="https://www.youtube.com/watch?v=vidRegular01" />
            <published>2026-11-24T12:00:00+00:00</published>
            <author><name>Sample Creator</name></author>
            <media:group>
              <media:thumbnail url="https://i.ytimg.com/vi/vidRegular01/hqdefault.jpg" />
            </media:group>
          </entry>
          <entry>
            <yt:videoId>vidShort0002</yt:videoId>
            <yt:channelId>UC1234567890123456789012</yt:channelId>
            <title>Quick #shorts Clip</title>
            <published>2026-11-25T08:30:00+00:00</published>
            <author><name>Sample Creator</name></author>
          </entry>
        </feed>
        """

        let parsed = try YouTubeRSSParser.parse(data: Data(xml.utf8))
        XCTAssertEqual(parsed.channelId, "UC1234567890123456789012")
        XCTAssertEqual(parsed.channelTitle, "Sample Creator")
        XCTAssertEqual(parsed.videos.count, 2)
        XCTAssertEqual(parsed.videos[0].videoId, "vidRegular01")
        XCTAssertEqual(parsed.videos[1].videoId, "vidShort0002")
    }

    func testAtomParserNormalizesYouTubeFeedLevelChannelIDWithoutUCPrefix() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <feed xmlns:yt="http://www.youtube.com/xml/schemas/2015"
              xmlns="http://www.w3.org/2005/Atom">
          <yt:channelId>HnyfMqiRRG1u-2MsSQLbXA</yt:channelId>
          <title>Veritasium</title>
          <entry>
            <yt:videoId>WbM7GP7QoEM</yt:videoId>
            <yt:channelId>UCHnyfMqiRRG1u-2MsSQLbXA</yt:channelId>
            <title>Scientists Said This Wave Was Impossible</title>
            <link rel="alternate" href="https://www.youtube.com/watch?v=WbM7GP7QoEM"/>
            <published>2026-11-25T14:00:52+00:00</published>
          </entry>
        </feed>
        """

        let parsed = try YouTubeRSSParser.parse(data: Data(xml.utf8))
        XCTAssertEqual(parsed.channelId, "UCHnyfMqiRRG1u-2MsSQLbXA")
        XCTAssertEqual(parsed.videos.first?.channelId, "UCHnyfMqiRRG1u-2MsSQLbXA")
        XCTAssertTrue(YouTubeChannelResolver.isChannelId(parsed.channelId ?? ""))
    }

    func testRSS2VideoFeedParserExtractsEnclosureAndStableID() throws {
        let rss = """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0" xmlns:media="http://search.yahoo.com/mrss/">
          <channel>
            <title>Indie Video Cast</title>
            <item>
              <guid>ep-42</guid>
              <title>Episode 42: Analog Signals</title>
              <link>https://example.org/watch/42</link>
              <pubDate>Tue, 24 Nov 2026 14:00:00 +0000</pubDate>
              <enclosure url="https://cdn.example.org/videos/ep42.mp4" type="video/mp4" />
              <media:thumbnail url="https://cdn.example.org/thumbs/ep42.jpg" />
            </item>
          </channel>
        </rss>
        """

        let parsedA = try YouTubeRSSParser.parse(data: Data(rss.utf8))
        let parsedB = try YouTubeRSSParser.parse(data: Data(rss.utf8))
        XCTAssertEqual(parsedA.channelTitle, "Indie Video Cast")
        XCTAssertEqual(parsedA.videos.count, 1)
        XCTAssertEqual(parsedA.videos[0].videoId, parsedB.videos[0].videoId)
        XCTAssertTrue(parsedA.videos[0].videoId.hasPrefix("vid-"))
        XCTAssertEqual(parsedA.videos[0].mediaURLString, "https://cdn.example.org/videos/ep42.mp4")
        XCTAssertEqual(parsedA.videos[0].videoURLString, "https://example.org/watch/42")
        XCTAssertEqual(parsedA.videos[0].thumbnailURLString, "https://cdn.example.org/thumbs/ep42.jpg")
    }

    func testChannelIDAndAlternateFeedDiscoveryHelpers() {
        XCTAssertTrue(YouTubeChannelResolver.isChannelId("UC1234567890123456789012"))
        XCTAssertFalse(YouTubeChannelResolver.isChannelId("not-a-channel"))

        XCTAssertEqual(
            YouTubeChannelResolver.extractChannelIdFromURLString("https://www.youtube.com/channel/UC1234567890123456789012/videos"),
            "UC1234567890123456789012"
        )

        let ytHTML = #"<html><script>var ytInitialData = {"externalId":"UCabcdefghij0123456789AB"};</script></html>"#
        XCTAssertEqual(YouTubeChannelResolver.extractChannelId(fromHTML: ytHTML), "UCabcdefghij0123456789AB")

        let blogHTML = #"<html><head><link rel="alternate" type="application/rss+xml" href="/feeds/videos.rss" /></head></html>"#
        let discovered = YouTubeChannelResolver.extractAlternateFeedURL(
            fromHTML: blogHTML,
            baseURL: URL(string: "https://videos.example.org/channel/demo")!
        )
        XCTAssertEqual(discovered?.absoluteString, "https://videos.example.org/feeds/videos.rss")
    }

    func testVideoLinkBuilderYouTubeAndGenericTimecodes() {
        XCTAssertEqual(
            VideoLinkBuilder.shareURL(videoId: "abc123", videoURLString: "https://youtu.be/abc123").absoluteString,
            "https://youtu.be/abc123"
        )
        XCTAssertEqual(
            VideoLinkBuilder.shareURL(videoId: "abc123", videoURLString: "https://youtu.be/abc123", atSeconds: 125.7).absoluteString,
            "https://youtu.be/abc123?t=125"
        )
        XCTAssertEqual(
            VideoLinkBuilder.shareURL(videoId: "vid-123", videoURLString: "https://vimeo.com/123456", atSeconds: 90).absoluteString,
            "https://vimeo.com/123456#t=90"
        )
        XCTAssertEqual(VideoLinkBuilder.formatTimecode(65), "1:05")
        XCTAssertEqual(VideoLinkBuilder.formatTimecode(3661), "1:01:01")
    }

    func testOPMLAndJSONBackupRoundTripWithGenericAndYouTubeFeeds() throws {
        let genericFeedURL = "https://peertube.example.org/feeds/videos.xml?videoChannelId=7"
        let genericId = StableID.sha256Prefix(genericFeedURL.lowercased(), prefix: "feed")

        let channels = [
            ChannelSnapshot(
                channelId: "UC1234567890123456789012",
                title: "Channel & Friends",
                handle: "@friends",
                feedURLString: Channel.defaultFeedURLString(for: "UC1234567890123456789012"),
                addedAt: Date(timeIntervalSince1970: 1_700_000_000),
                isSubscribed: true,
                updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
            ),
            ChannelSnapshot(
                channelId: genericId,
                title: "PeerTube Channel",
                handle: nil,
                feedURLString: genericFeedURL,
                addedAt: Date(timeIntervalSince1970: 1_700_000_000),
                isSubscribed: true,
                updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
            ),
            ChannelSnapshot(
                channelId: "UC9999999999999999999999",
                title: "Unsubscribed Channel",
                handle: nil,
                feedURLString: Channel.defaultFeedURLString(for: "UC9999999999999999999999"),
                addedAt: Date(timeIntervalSince1970: 1_700_000_000),
                isSubscribed: false,
                updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
        ]

        let opmlData = SubscriptionBackupService.exportOPML(channels: channels)
        let importedOPML = try SubscriptionBackupService.importOPML(data: opmlData)
        XCTAssertEqual(importedOPML.count, 2)
        XCTAssertEqual(Set(importedOPML.map(\.channelId)), Set(["UC1234567890123456789012", genericId]))

        let states = [
            VideoStateSnapshot(
                videoId: "vid0001",
                channelId: "UC1234567890123456789012",
                watchStatus: .watched,
                positionSeconds: 400,
                durationSeconds: 400,
                completedAt: Date(timeIntervalSince1970: 1_700_005_000),
                stateUpdatedAt: Date(timeIntervalSince1970: 1_700_005_000)
            )
        ]
        let jsonData = try SubscriptionBackupService.exportJSON(channels: channels, videoStates: states)
        let payload = try SubscriptionBackupService.importJSON(data: jsonData)
        XCTAssertEqual(payload.channels.count, 2)
        XCTAssertEqual(payload.videoStates, states)
    }

    @MainActor
    func testLocalStoreUpsertNeverCreatesDuplicatesAndPreservesRemoteWatchState() throws {
        let container = try LocalStore.makeContainer(inMemory: true)
        let context = container.mainContext

        let syncedState = VideoStateSnapshot(
            videoId: "vidSync01",
            channelId: "UC1234567890123456789012",
            watchStatus: .watched,
            positionSeconds: 500,
            durationSeconds: 500,
            completedAt: Date(timeIntervalSince1970: 1_700_010_000),
            stateUpdatedAt: Date(timeIntervalSince1970: 1_700_010_000)
        )
        LocalStore.applyRemoteVideoState(syncedState, in: context)

        let feedVideo = FeedVideo(
            videoId: "vidSync01",
            channelId: "UC1234567890123456789012",
            channelTitle: "Creator",
            title: "Synced Video Title",
            publishedAt: Date(timeIntervalSince1970: 1_700_000_000),
            thumbnailURLString: nil,
            videoURLString: "https://www.youtube.com/watch?v=vidSync01",
            mediaURLString: nil
        )
        LocalStore.upsertFeedVideos([feedVideo], in: context)
        LocalStore.upsertFeedVideos([feedVideo], in: context)

        let all = try context.fetch(FetchDescriptor<VideoItem>())
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all[0].title, "Synced Video Title")
        XCTAssertEqual(all[0].watchStatus, .watched)
        XCTAssertEqual(all[0].positionSeconds, 500)
    }

    @MainActor
    func testUnsubscribeDeletesChannelVideosAndResetsWatchProgressOnResubscribe() throws {
        let container = try LocalStore.makeContainer(inMemory: true)
        let context = container.mainContext
        let coordinator = AppCoordinator()
        let syncEngine = CloudSyncEngine()

        let channelSnapshot = ChannelSnapshot(
            channelId: "feed-demo-1",
            title: "Demo Feed",
            handle: nil,
            feedURLString: "https://example.org/feed.xml",
            addedAt: .now,
            isSubscribed: true,
            updatedAt: .now
        )
        let channel = LocalStore.upsertChannel(channelSnapshot, in: context)
        let feedVideo = FeedVideo(
            videoId: "vid-demo-1",
            channelId: "feed-demo-1",
            channelTitle: "Demo Feed",
            title: "Episode 1",
            publishedAt: .now,
            thumbnailURLString: nil,
            videoURLString: "https://example.org/watch/1",
            mediaURLString: "https://example.org/video/1.mp4"
        )
        LocalStore.upsertFeedVideos([feedVideo], in: context)

        let existing = try XCTUnwrap(try context.fetch(FetchDescriptor<VideoItem>()).first)
        existing.positionSeconds = 120
        existing.durationSeconds = 300
        existing.watchStatus = .inProgress
        try context.save()

        coordinator.unsubscribe(channel, syncEngine: syncEngine, in: context)
        XCTAssertFalse(channel.isSubscribed)
        XCTAssertEqual(try context.fetch(FetchDescriptor<VideoItem>()).count, 0)

        LocalStore.upsertFeedVideos([feedVideo], in: context)
        let readded = try XCTUnwrap(try context.fetch(FetchDescriptor<VideoItem>()).first)
        XCTAssertEqual(readded.watchStatus, .unwatched)
        XCTAssertEqual(readded.positionSeconds, 0)
    }
}
