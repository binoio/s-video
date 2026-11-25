import Foundation

struct ResolvedChannel: Sendable, Equatable {
    let channelId: String
    let title: String
    let handle: String?
    let feedURLString: String
}

enum ChannelResolutionError: LocalizedError {
    case emptyInput
    case invalidURL
    case channelNotFound
    case networkFailure(String)

    var errorDescription: String? {
        switch self {
        case .emptyInput:
            "Enter an RSS/Atom feed URL, channel URL, @handle, or video link."
        case .invalidURL:
            "That doesn't look like a valid feed or channel URL."
        case .channelNotFound:
            "Could not find a video feed at that address."
        case .networkFailure(let detail):
            "Network error while looking up feed: \(detail)"
        }
    }
}

/// Resolves any RSS/Atom video feed URL, webpage with `<link rel="alternate">` feed auto-discovery,
/// or YouTube channel URL / `@handle` / `UC...` ID into a verified `ResolvedChannel`.
struct YouTubeChannelResolver: Sendable {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func resolve(input rawInput: String) async throws -> ResolvedChannel {
        let trimmed = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ChannelResolutionError.emptyInput }

        // 1. Direct YouTube channel ID (e.g. UCxxxxxxxxxxxxxxxxxxxxxx)
        if Self.isChannelId(trimmed) {
            return try await verifyYouTubeFeed(channelId: trimmed, handle: nil)
        }

        // 2. YouTube channel URL with /channel/UC...
        if let cid = Self.extractChannelIdFromURLString(trimmed) {
            return try await verifyYouTubeFeed(channelId: cid, handle: nil)
        }

        // 3. @handle shorthand (YouTube)
        if trimmed.hasPrefix("@") {
            guard let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
                  let url = URL(string: "https://www.youtube.com/\(encoded)") else {
                throw ChannelResolutionError.invalidURL
            }
            let html = try await fetchText(from: url)
            guard let cid = Self.extractChannelId(fromHTML: html) else {
                throw ChannelResolutionError.channelNotFound
            }
            return try await verifyYouTubeFeed(channelId: cid, handle: trimmed)
        }

        // 4. General URL (direct RSS/Atom feed, YouTube page, or any site with feed auto-discovery)
        let normalized = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let url = URL(string: normalized), url.host != nil else {
            throw ChannelResolutionError.invalidURL
        }

        let data = try await fetchData(from: url)

        // 4a. Try parsing directly as RSS 2.0 or Atom feed
        if let parsed = try? YouTubeRSSParser.parse(data: data),
           (parsed.channelTitle != nil || !parsed.videos.isEmpty) {
            let feedURLString = url.absoluteString
            let channelId = parsed.channelId
                ?? Self.extractYouTubeChannelIdFromFeedURL(url)
                ?? StableID.sha256Prefix(feedURLString.lowercased(), prefix: "feed")
            let title = parsed.channelTitle ?? url.host ?? feedURLString
            return ResolvedChannel(
                channelId: channelId,
                title: title,
                handle: nil,
                feedURLString: feedURLString
            )
        }

        // 4b. Otherwise inspect HTML for YouTube channel ID or standard <link rel="alternate"> RSS/Atom feed
        let html = String(decoding: data, as: UTF8.self)
        if let cid = Self.extractChannelId(fromHTML: html) {
            return try await verifyYouTubeFeed(channelId: cid, handle: Self.extractHandle(from: url))
        }
        if let discoveredFeedURL = Self.extractAlternateFeedURL(fromHTML: html, baseURL: url) {
            let feedData = try await fetchData(from: discoveredFeedURL)
            let parsed = try YouTubeRSSParser.parse(data: feedData)
            let feedURLString = discoveredFeedURL.absoluteString
            let channelId = parsed.channelId
                ?? Self.extractYouTubeChannelIdFromFeedURL(discoveredFeedURL)
                ?? StableID.sha256Prefix(feedURLString.lowercased(), prefix: "feed")
            return ResolvedChannel(
                channelId: channelId,
                title: parsed.channelTitle ?? discoveredFeedURL.host ?? feedURLString,
                handle: nil,
                feedURLString: feedURLString
            )
        }

        throw ChannelResolutionError.channelNotFound
    }

    private func verifyYouTubeFeed(channelId: String, handle: String?) async throws -> ResolvedChannel {
        let feedURLString = Channel.defaultFeedURLString(for: channelId)
        guard let feedURL = URL(string: feedURLString) else {
            throw ChannelResolutionError.invalidURL
        }
        let data = try await fetchData(from: feedURL)
        let parsed = try YouTubeRSSParser.parse(data: data)
        return ResolvedChannel(
            channelId: channelId,
            title: parsed.channelTitle ?? handle ?? channelId,
            handle: handle,
            feedURLString: feedURLString
        )
    }

    private func fetchData(from url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("Mozilla/5.0 (iPad; CPU OS 17_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw ChannelResolutionError.networkFailure("HTTP \(http.statusCode)")
            }
            return data
        } catch let error as ChannelResolutionError {
            throw error
        } catch {
            throw ChannelResolutionError.networkFailure(error.localizedDescription)
        }
    }

    private func fetchText(from url: URL) async throws -> String {
        let data = try await fetchData(from: url)
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Pure Parsing Helpers

    static func isChannelId(_ string: String) -> Bool {
        string.hasPrefix("UC") && string.count == 24
            && string.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
    }

    static func extractYouTubeChannelIdFromFeedURL(_ url: URL) -> String? {
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let cid = comps.queryItems?.first(where: { $0.name == "channel_id" })?.value,
              isChannelId(cid) else {
            return nil
        }
        return cid
    }

    static func extractChannelIdFromURLString(_ raw: String) -> String? {
        guard let range = raw.range(of: #"/channel/(UC[A-Za-z0-9_-]{22})"#, options: .regularExpression) else {
            return nil
        }
        return String(raw[range]).replacingOccurrences(of: "/channel/", with: "")
    }

    static func extractHandle(from url: URL) -> String? {
        url.pathComponents.first { $0.hasPrefix("@") }
    }

    static func extractChannelId(fromHTML html: String) -> String? {
        let patterns = [
            #""externalId":"(UC[A-Za-z0-9_-]{22})""#,
            #"<link rel="canonical" href="https://www\.youtube\.com/channel/(UC[A-Za-z0-9_-]{22})""#,
            #""channelId":"(UC[A-Za-z0-9_-]{22})""#,
            #"itemprop="identifier" content="(UC[A-Za-z0-9_-]{22})""#
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
               let groupRange = Range(match.range(at: 1), in: html) {
                return String(html[groupRange])
            }
        }
        return nil
    }

    static func extractAlternateFeedURL(fromHTML html: String, baseURL: URL) -> URL? {
        let pattern = #"<link[^>]+rel=["']alternate["'][^>]+type=["']application/(?:rss|atom)\+xml["'][^>]+href=["']([^"']+)["']"#
        if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
           let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
           let hrefRange = Range(match.range(at: 1), in: html) {
            return URL(string: String(html[hrefRange]), relativeTo: baseURL)?.absoluteURL
        }
        return nil
    }
}
