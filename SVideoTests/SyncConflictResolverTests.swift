import CloudKit
import Foundation
import XCTest
@testable import S_Video

final class SyncConflictResolverTests: XCTestCase {
    func testWatchedVideoNeverResurrectsFromOlderUnwatchedCopy() {
        let earlier = Date(timeIntervalSince1970: 1_700_000_000)
        let later = Date(timeIntervalSince1970: 1_700_001_000)

        let watchedOnIPadA = VideoStateSnapshot(
            videoId: "dQw4w9WgXcQ",
            channelId: "UCuAXFkgsw1L7xaCfnd5JJOw",
            watchStatus: .watched,
            positionSeconds: 212,
            durationSeconds: 212,
            completedAt: later,
            stateUpdatedAt: later
        )

        let unwatchedOnIPadB = VideoStateSnapshot(
            videoId: "dQw4w9WgXcQ",
            channelId: "UCuAXFkgsw1L7xaCfnd5JJOw",
            watchStatus: .unwatched,
            positionSeconds: 0,
            durationSeconds: 0,
            completedAt: nil,
            stateUpdatedAt: earlier
        )

        let mergedAB = SyncConflictResolver.merge(local: watchedOnIPadA, remote: unwatchedOnIPadB)
        let mergedBA = SyncConflictResolver.merge(local: unwatchedOnIPadB, remote: watchedOnIPadA)

        XCTAssertEqual(mergedAB.watchStatus, .watched)
        XCTAssertEqual(mergedBA.watchStatus, .watched)
        XCTAssertEqual(mergedAB.completedAt, later)
        XCTAssertEqual(mergedBA.completedAt, later)
        XCTAssertEqual(mergedAB, mergedBA)
    }

    func testEqualTimestampTieBreakerPrefersHigherStatusThenFurtherProgress() {
        let sameTime = Date(timeIntervalSince1970: 1_700_000_500)

        let inProgressEarly = VideoStateSnapshot(
            videoId: "abc12345678",
            channelId: "UC1234567890123456789012",
            watchStatus: .inProgress,
            positionSeconds: 45,
            durationSeconds: 300,
            completedAt: nil,
            stateUpdatedAt: sameTime
        )

        let inProgressFurther = VideoStateSnapshot(
            videoId: "abc12345678",
            channelId: "UC1234567890123456789012",
            watchStatus: .inProgress,
            positionSeconds: 180,
            durationSeconds: 300,
            completedAt: nil,
            stateUpdatedAt: sameTime
        )

        let merged = SyncConflictResolver.merge(local: inProgressEarly, remote: inProgressFurther)
        XCTAssertEqual(merged.positionSeconds, 180)
        XCTAssertEqual(merged.watchStatus, .inProgress)
    }

    func testChannelMergeUsesLatestUpdateAndPreservesMetadata() {
        let t1 = Date(timeIntervalSince1970: 1_700_000_000)
        let t2 = Date(timeIntervalSince1970: 1_700_002_000)

        let local = ChannelSnapshot(
            channelId: "UC1234567890123456789012",
            title: "Tech Channel",
            handle: "@tech",
            feedURLString: Channel.defaultFeedURLString(for: "UC1234567890123456789012"),
            addedAt: t1,
            isSubscribed: true,
            updatedAt: t1
        )

        let remoteUnsubscribed = ChannelSnapshot(
            channelId: "UC1234567890123456789012",
            title: "",
            handle: nil,
            feedURLString: "",
            addedAt: t2,
            isSubscribed: false,
            updatedAt: t2
        )

        let merged = SyncConflictResolver.merge(local: local, remote: remoteUnsubscribed)
        XCTAssertFalse(merged.isSubscribed)
        XCTAssertEqual(merged.title, "Tech Channel")
        XCTAssertEqual(merged.handle, "@tech")
        XCTAssertEqual(merged.addedAt, t1)
    }

    func testDeterministicCloudRecordIDsAndRoundTrip() {
        let channel = ChannelSnapshot(
            channelId: "UC1234567890123456789012",
            title: "Example Channel",
            handle: "@example",
            feedURLString: Channel.defaultFeedURLString(for: "UC1234567890123456789012"),
            addedAt: Date(timeIntervalSince1970: 1_700_000_000),
            isSubscribed: true,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_100)
        )

        let recordA = CloudRecordCodec.encode(channel)
        let recordB = CloudRecordCodec.encode(channel)
        XCTAssertEqual(recordA.recordID, recordB.recordID)
        XCTAssertEqual(recordA.recordID.recordName, "channel:UC1234567890123456789012")
        XCTAssertEqual(CloudRecordCodec.decodeChannel(from: recordA), channel)

        let state = VideoStateSnapshot(
            videoId: "vid12345678",
            channelId: channel.channelId,
            watchStatus: .inProgress,
            positionSeconds: 92.5,
            durationSeconds: 600,
            completedAt: nil,
            stateUpdatedAt: Date(timeIntervalSince1970: 1_700_000_200)
        )
        let stateRecord = CloudRecordCodec.encode(state)
        XCTAssertEqual(stateRecord.recordID.recordName, "state:vid12345678")
        XCTAssertEqual(CloudRecordCodec.decodeVideoState(from: stateRecord), state)
    }
}
