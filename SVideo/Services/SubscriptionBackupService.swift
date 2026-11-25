import Foundation
import UniformTypeIdentifiers

struct SVideoBackupPayload: Codable, Sendable, Equatable {
    static let currentVersion = 1

    let version: Int
    let exportedAt: Date
    let channels: [ChannelSnapshot]
    let videoStates: [VideoStateSnapshot]
}

extension UTType {
    static let opml = UTType(filenameExtension: "opml") ?? .xml
}

/// Handles OPML (standard RSS/Atom subscription list) and S-Video JSON backup import/export.
enum SubscriptionBackupService {

    // MARK: - OPML Export / Import

    static func exportOPML(channels: [ChannelSnapshot]) -> Data {
        let subscribed = channels
            .filter(\.isSubscribed)
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }

        var lines: [String] = [
            #"<?xml version="1.0" encoding="UTF-8"?>"#,
            #"<opml version="2.0">"#,
            #"  <head>"#,
            #"    <title>S-Video Subscriptions</title>"#,
            #"  </head>"#,
            #"  <body>"#,
            #"    <outline text="Video Feeds" title="Video Feeds">"#
        ]

        for channel in subscribed {
            let escapedTitle = escapeXML(channel.title)
            let escapedFeed = escapeXML(channel.feedURLString)
            let htmlURL = YouTubeChannelResolver.isChannelId(channel.channelId)
                ? "https://www.youtube.com/channel/\(channel.channelId)"
                : channel.feedURLString
            let escapedHTML = escapeXML(htmlURL)
            lines.append(
                #"      <outline type="rss" text="\#(escapedTitle)" title="\#(escapedTitle)" xmlUrl="\#(escapedFeed)" htmlUrl="\#(escapedHTML)" />"#
            )
        }

        lines.append(#"    </outline>"#)
        lines.append(#"  </body>"#)
        lines.append(#"</opml>"#)
        return Data(lines.joined(separator: "\n").utf8)
    }

    static func importOPML(data: Data) throws -> [ChannelSnapshot] {
        let delegate = OPMLParserDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else {
            throw parser.parserError ?? URLError(.cannotParseResponse)
        }
        return delegate.channels
    }

    // MARK: - JSON Backup Export / Import

    static func exportJSON(
        channels: [ChannelSnapshot],
        videoStates: [VideoStateSnapshot]
    ) throws -> Data {
        let payload = SVideoBackupPayload(
            version: SVideoBackupPayload.currentVersion,
            exportedAt: .now,
            channels: channels.filter(\.isSubscribed),
            videoStates: videoStates
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(payload)
    }

    static func importJSON(data: Data) throws -> SVideoBackupPayload {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(SVideoBackupPayload.self, from: data)
    }

    private static func escapeXML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

private final class OPMLParserDelegate: NSObject, XMLParserDelegate {
    var channels: [ChannelSnapshot] = []
    private var seenIds: Set<String> = []

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        guard elementName.lowercased() == "outline" else { return }
        let xmlUrl = (attributeDict["xmlUrl"] ?? attributeDict["xmlurl"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let htmlUrl = (attributeDict["htmlUrl"] ?? attributeDict["htmlurl"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let title = (attributeDict["title"] ?? attributeDict["text"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        let ytId = extractYouTubeChannelId(fromFeedURL: xmlUrl)
            ?? YouTubeChannelResolver.extractChannelIdFromURLString(htmlUrl)

        let channelId: String
        let resolvedFeedURL: String
        if let ytId {
            channelId = ytId
            resolvedFeedURL = xmlUrl.isEmpty ? Channel.defaultFeedURLString(for: ytId) : xmlUrl
        } else if !xmlUrl.isEmpty, URL(string: xmlUrl)?.scheme != nil {
            channelId = StableID.sha256Prefix(xmlUrl.lowercased(), prefix: "feed")
            resolvedFeedURL = xmlUrl
        } else {
            return
        }

        guard !seenIds.contains(channelId) else { return }
        seenIds.insert(channelId)

        let now = Date.now
        channels.append(ChannelSnapshot(
            channelId: channelId,
            title: title.isEmpty ? (URL(string: resolvedFeedURL)?.host ?? channelId) : title,
            handle: nil,
            feedURLString: resolvedFeedURL,
            addedAt: now,
            isSubscribed: true,
            updatedAt: now
        ))
    }

    private func extractYouTubeChannelId(fromFeedURL raw: String) -> String? {
        guard let url = URL(string: raw) else { return nil }
        return YouTubeChannelResolver.extractYouTubeChannelIdFromFeedURL(url)
    }
}
