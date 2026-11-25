import Foundation

struct FeedRefreshResult: Sendable {
    let videos: [FeedVideo]
    let succeededCount: Int
    let failedCount: Int
}

/// Concurrently fetches Atom RSS feeds for all subscribed channels.
struct FeedRefreshService: Sendable {
    private let session: URLSession
    private let maxConcurrent: Int

    init(session: URLSession = .shared, maxConcurrent: Int = 6) {
        self.session = session
        self.maxConcurrent = maxConcurrent
    }

    func refresh(channels: [ChannelSnapshot]) async -> FeedRefreshResult {
        let active = channels.filter(\.isSubscribed)
        guard !active.isEmpty else {
            return FeedRefreshResult(videos: [], succeededCount: 0, failedCount: 0)
        }

        var collected: [FeedVideo] = []
        var succeeded = 0
        var failed = 0

        await withTaskGroup(of: Result<[FeedVideo], Error>.self) { group in
            var iterator = active.makeIterator()

            for _ in 0..<min(maxConcurrent, active.count) {
                if let channel = iterator.next() {
                    group.addTask { await self.fetchFeed(for: channel) }
                }
            }

            while let result = await group.next() {
                switch result {
                case .success(let videos):
                    collected.append(contentsOf: videos)
                    succeeded += 1
                case .failure:
                    failed += 1
                }
                if let next = iterator.next() {
                    group.addTask { await self.fetchFeed(for: next) }
                }
            }
        }

        return FeedRefreshResult(
            videos: collected,
            succeededCount: succeeded,
            failedCount: failed
        )
    }

    private func fetchFeed(for channel: ChannelSnapshot) async -> Result<[FeedVideo], Error> {
        guard let url = URL(string: channel.feedURLString) else {
            return .failure(URLError(.badURL))
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                return .failure(URLError(.badServerResponse))
            }
            let parsed = try YouTubeRSSParser.parse(data: data)
            let normalized = parsed.videos.map { video in
                FeedVideo(
                    videoId: video.videoId,
                    channelId: channel.channelId,
                    channelTitle: video.channelTitle.isEmpty ? channel.title : video.channelTitle,
                    title: video.title,
                    publishedAt: video.publishedAt,
                    thumbnailURLString: video.thumbnailURLString,
                    videoURLString: video.videoURLString,
                    mediaURLString: video.mediaURLString
                )
            }
            return .success(normalized)
        } catch {
            return .failure(error)
        }
    }
}
