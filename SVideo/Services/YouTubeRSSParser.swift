import Foundation

struct FeedVideo: Sendable, Equatable, Hashable {
    let videoId: String
    let channelId: String
    let channelTitle: String
    let title: String
    let publishedAt: Date
    let thumbnailURLString: String?
    let videoURLString: String
    let mediaURLString: String?
}

struct ParsedFeed: Sendable, Equatable {
    let channelId: String?
    let channelTitle: String?
    let videos: [FeedVideo]
}

/// Parses both Atom feeds (YouTube, PeerTube, etc.) and standard RSS 2.0 video feeds
/// (Vimeo, video podcasts, self-hosted feeds) with no filtering by content type.
final class YouTubeRSSParser: NSObject, XMLParserDelegate {
    private var feedChannelId: String?
    private var feedChannelTitle: String?
    private var videos: [FeedVideo] = []

    private var inItem = false
    private var inAuthor = false
    private var currentText = ""

    private var itemYtVideoId = ""
    private var itemYtChannelId = ""
    private var itemGuid = ""
    private var itemTitle = ""
    private var itemAuthor = ""
    private var itemPublished = ""
    private var itemLink = ""
    private var itemMediaURL: String?
    private var itemThumbnailURL: String?

    private static let isoFractionalStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let isoStandardStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: false)

    static func parse(data: Data) throws -> ParsedFeed {
        let delegate = YouTubeRSSParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else {
            throw parser.parserError ?? URLError(.cannotParseResponse)
        }
        return ParsedFeed(
            channelId: delegate.feedChannelId,
            channelTitle: delegate.feedChannelTitle,
            videos: delegate.videos
        )
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        currentText = ""

        switch elementName {
        case "entry", "item":
            inItem = true
            itemYtVideoId = ""
            itemYtChannelId = ""
            itemGuid = ""
            itemTitle = ""
            itemAuthor = ""
            itemPublished = ""
            itemLink = ""
            itemMediaURL = nil
            itemThumbnailURL = nil
        case "author":
            inAuthor = true
        case "link":
            if inItem, let href = attributeDict["href"], !href.isEmpty {
                let rel = attributeDict["rel"] ?? "alternate"
                if rel == "alternate" || itemLink.isEmpty {
                    itemLink = href
                } else if rel == "enclosure", Self.isVideoType(attributeDict["type"], url: href) {
                    itemMediaURL = href
                }
            }
        case "enclosure":
            if inItem, let url = attributeDict["url"], !url.isEmpty,
               Self.isVideoType(attributeDict["type"], url: url) {
                itemMediaURL = url
            }
        case "media:content":
            if inItem, let url = attributeDict["url"], !url.isEmpty {
                let type = attributeDict["type"] ?? ""
                let medium = attributeDict["medium"] ?? ""
                if medium == "video" || Self.isVideoType(type, url: url) {
                    itemMediaURL = itemMediaURL ?? url
                }
            }
        case "media:thumbnail":
            if inItem, let url = attributeDict["url"], !url.isEmpty {
                itemThumbnailURL = itemThumbnailURL ?? url
            }
        case "itunes:image":
            if inItem, let href = attributeDict["href"], !href.isEmpty {
                itemThumbnailURL = itemThumbnailURL ?? href
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)

        if inItem {
            switch elementName {
            case "yt:videoId":
                itemYtVideoId = trimmed
            case "yt:channelId":
                itemYtChannelId = trimmed
            case "guid", "id":
                if !trimmed.isEmpty { itemGuid = trimmed }
            case "title":
                if !trimmed.isEmpty { itemTitle = trimmed }
            case "name":
                if inAuthor, !trimmed.isEmpty { itemAuthor = trimmed }
            case "dc:creator", "itunes:author":
                if itemAuthor.isEmpty, !trimmed.isEmpty { itemAuthor = trimmed }
            case "published", "pubDate", "updated", "dc:date":
                if itemPublished.isEmpty, !trimmed.isEmpty { itemPublished = trimmed }
            case "link":
                if itemLink.isEmpty, !trimmed.isEmpty { itemLink = trimmed }
            case "author":
                inAuthor = false
            case "entry", "item":
                inItem = false
                emitCurrentItem()
            default:
                break
            }
        } else {
            switch elementName {
            case "yt:channelId":
                if !trimmed.isEmpty {
                    // YouTube's feed-level <yt:channelId> omits the "UC" prefix (22 chars)
                    // while <entry> uses the full 24-char "UC..." ID. Normalize to "UC...".
                    if !trimmed.hasPrefix("UC"), trimmed.count == 22 {
                        feedChannelId = "UC\(trimmed)"
                    } else {
                        feedChannelId = trimmed
                    }
                }
            case "title":
                if feedChannelTitle == nil, !trimmed.isEmpty { feedChannelTitle = trimmed }
            case "author":
                inAuthor = false
            default:
                break
            }
        }
        currentText = ""
    }

    private func emitCurrentItem() {
        let canonicalLink: String
        if !itemLink.isEmpty {
            canonicalLink = itemLink
        } else if !itemYtVideoId.isEmpty {
            canonicalLink = "https://www.youtube.com/watch?v=\(itemYtVideoId)"
        } else if let media = itemMediaURL {
            canonicalLink = media
        } else {
            return
        }

        let resolvedVideoId: String
        if !itemYtVideoId.isEmpty {
            resolvedVideoId = itemYtVideoId
        } else if let ytId = VideoLinkBuilder.youtubeVideoID(from: canonicalLink) {
            resolvedVideoId = ytId
        } else {
            let key = itemGuid.isEmpty ? canonicalLink : itemGuid
            resolvedVideoId = StableID.sha256Prefix(key, prefix: "vid")
        }

        let resolvedThumb: String?
        if let thumb = itemThumbnailURL {
            resolvedThumb = thumb
        } else if !itemYtVideoId.isEmpty {
            resolvedThumb = "https://i.ytimg.com/vi/\(itemYtVideoId)/hqdefault.jpg"
        } else {
            resolvedThumb = nil
        }

        let publishedDate = Self.parseDate(itemPublished) ?? .now
        let resolvedChannelId = itemYtChannelId.isEmpty ? (feedChannelId ?? "") : itemYtChannelId
        let resolvedChannelTitle = itemAuthor.isEmpty ? (feedChannelTitle ?? "") : itemAuthor

        videos.append(FeedVideo(
            videoId: resolvedVideoId,
            channelId: resolvedChannelId,
            channelTitle: resolvedChannelTitle,
            title: itemTitle.isEmpty ? "Untitled Video" : itemTitle,
            publishedAt: publishedDate,
            thumbnailURLString: resolvedThumb,
            videoURLString: canonicalLink,
            mediaURLString: itemMediaURL
        ))
    }

    private static func isVideoType(_ mimeType: String?, url: String) -> Bool {
        if let mime = mimeType?.lowercased(), mime.hasPrefix("video/") || mime.contains("mpegurl") {
            return true
        }
        let lower = url.lowercased()
        return lower.hasSuffix(".mp4") || lower.hasSuffix(".m4v")
            || lower.hasSuffix(".mov") || lower.hasSuffix(".m3u8")
    }

    private static func parseDate(_ raw: String) -> Date? {
        guard !raw.isEmpty else { return nil }
        if let date = (try? isoFractionalStyle.parse(raw)) ?? (try? isoStandardStyle.parse(raw)) {
            return date
        }
        let rfcFormats = [
            "EEE, dd MMM yyyy HH:mm:ss Z",
            "EEE, d MMM yyyy HH:mm:ss Z",
            "EEE, dd MMM yyyy HH:mm:ss zzz",
            "dd MMM yyyy HH:mm:ss Z"
        ]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in rfcFormats {
            formatter.dateFormat = format
            if let date = formatter.date(from: raw) {
                return date
            }
        }
        return nil
    }
}
