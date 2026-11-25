import CloudKit
import Foundation

/// Deterministic CloudKit record IDs and encoding/decoding for `SVideoZone`.
enum CloudRecordCodec {
    static let zoneID = CKRecordZone.ID(zoneName: "SVideoZone", ownerName: CKCurrentUserDefaultName)

    static let channelRecordType = "SVChannel"
    static let videoStateRecordType = "SVVideoState"

    private static let channelPrefix = "channel:"
    private static let videoStatePrefix = "state:"

    static func channelRecordID(for channelId: String) -> CKRecord.ID {
        CKRecord.ID(recordName: "\(channelPrefix)\(channelId)", zoneID: zoneID)
    }

    static func videoStateRecordID(for videoId: String) -> CKRecord.ID {
        CKRecord.ID(recordName: "\(videoStatePrefix)\(videoId)", zoneID: zoneID)
    }

    static func channelId(from recordID: CKRecord.ID) -> String? {
        guard recordID.recordName.hasPrefix(channelPrefix) else { return nil }
        return String(recordID.recordName.dropFirst(channelPrefix.count))
    }

    static func videoId(from recordID: CKRecord.ID) -> String? {
        guard recordID.recordName.hasPrefix(videoStatePrefix) else { return nil }
        return String(recordID.recordName.dropFirst(videoStatePrefix.count))
    }

    // MARK: - Channel Encoding / Decoding

    static func encode(_ snapshot: ChannelSnapshot, existingSystemFields: Data? = nil) -> CKRecord {
        let recordID = channelRecordID(for: snapshot.channelId)
        let record = restoreRecord(from: existingSystemFields)
            ?? CKRecord(recordType: channelRecordType, recordID: recordID)
        record["channelId"] = snapshot.channelId as CKRecordValue
        record["title"] = snapshot.title as CKRecordValue
        record["handle"] = snapshot.handle as CKRecordValue?
        record["feedURLString"] = snapshot.feedURLString as CKRecordValue
        record["addedAt"] = snapshot.addedAt as CKRecordValue
        record["isSubscribed"] = (snapshot.isSubscribed ? 1 : 0) as CKRecordValue
        record["updatedAt"] = snapshot.updatedAt as CKRecordValue
        return record
    }

    static func decodeChannel(from record: CKRecord) -> ChannelSnapshot? {
        guard record.recordType == channelRecordType else { return nil }
        let cid = (record["channelId"] as? String) ?? channelId(from: record.recordID)
        guard let cid, !cid.isEmpty else { return nil }

        let title = (record["title"] as? String) ?? cid
        let handle = record["handle"] as? String
        let feedURLString = (record["feedURLString"] as? String) ?? Channel.defaultFeedURLString(for: cid)
        let addedAt = (record["addedAt"] as? Date) ?? record.creationDate ?? .now
        let isSubscribedInt = (record["isSubscribed"] as? Int) ?? 1
        let updatedAt = (record["updatedAt"] as? Date) ?? record.modificationDate ?? addedAt

        return ChannelSnapshot(
            channelId: cid,
            title: title,
            handle: handle,
            feedURLString: feedURLString,
            addedAt: addedAt,
            isSubscribed: isSubscribedInt != 0,
            updatedAt: updatedAt
        )
    }

    // MARK: - VideoState Encoding / Decoding

    static func encode(_ snapshot: VideoStateSnapshot, existingSystemFields: Data? = nil) -> CKRecord {
        let recordID = videoStateRecordID(for: snapshot.videoId)
        let record = restoreRecord(from: existingSystemFields)
            ?? CKRecord(recordType: videoStateRecordType, recordID: recordID)
        record["videoId"] = snapshot.videoId as CKRecordValue
        record["channelId"] = snapshot.channelId as CKRecordValue
        record["watchStatus"] = snapshot.watchStatus.rawValue as CKRecordValue
        record["positionSeconds"] = snapshot.positionSeconds as CKRecordValue
        record["durationSeconds"] = snapshot.durationSeconds as CKRecordValue
        record["completedAt"] = snapshot.completedAt as CKRecordValue?
        record["stateUpdatedAt"] = snapshot.stateUpdatedAt as CKRecordValue
        return record
    }

    static func decodeVideoState(from record: CKRecord) -> VideoStateSnapshot? {
        guard record.recordType == videoStateRecordType else { return nil }
        let vid = (record["videoId"] as? String) ?? videoId(from: record.recordID)
        guard let vid, !vid.isEmpty else { return nil }

        let channelId = (record["channelId"] as? String) ?? ""
        let statusRaw = (record["watchStatus"] as? Int) ?? WatchStatus.unwatched.rawValue
        let status = WatchStatus(rawValue: statusRaw) ?? .unwatched
        let position = (record["positionSeconds"] as? Double) ?? 0
        let duration = (record["durationSeconds"] as? Double) ?? 0
        let completedAt = record["completedAt"] as? Date
        let updatedAt = (record["stateUpdatedAt"] as? Date) ?? record.modificationDate ?? .distantPast

        return VideoStateSnapshot(
            videoId: vid,
            channelId: channelId,
            watchStatus: status,
            positionSeconds: position,
            durationSeconds: duration,
            completedAt: completedAt,
            stateUpdatedAt: updatedAt
        )
    }

    // MARK: - System Fields Archiving

    static func encodeSystemFields(of record: CKRecord) -> Data {
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: archiver)
        archiver.finishEncoding()
        return archiver.encodedData
    }

    private static func restoreRecord(from data: Data?) -> CKRecord? {
        guard let data,
              let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data) else {
            return nil
        }
        unarchiver.requiresSecureCoding = true
        defer { unarchiver.finishDecoding() }
        return CKRecord(coder: unarchiver)
    }
}
