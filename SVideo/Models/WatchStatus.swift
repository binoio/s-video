import CryptoKit
import Foundation

enum WatchStatus: Int, Codable, Sendable, CaseIterable, Comparable {
    case unwatched = 0
    case inProgress = 1
    case watched = 2

    static func < (lhs: WatchStatus, rhs: WatchStatus) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var label: String {
        switch self {
        case .unwatched: "Unwatched"
        case .inProgress: "In Progress"
        case .watched: "Watched"
        }
    }

    var symbolName: String {
        switch self {
        case .unwatched: "circle"
        case .inProgress: "play.circle.fill"
        case .watched: "checkmark.circle.fill"
        }
    }
}

enum StableID {
    static func sha256Prefix(_ input: String, prefix: String, length: Int = 20) -> String {
        let digest = SHA256.hash(data: Data(input.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "\(prefix)-\(hex.prefix(length))"
    }
}

enum VideoLinkBuilder {
    static func shareURL(
        videoId: String,
        videoURLString: String?,
        atSeconds seconds: Double? = nil
    ) -> URL {
        let baseURL: URL
        if let raw = videoURLString, let parsed = URL(string: raw), parsed.scheme != nil {
            baseURL = parsed
        } else {
            baseURL = URL(string: "https://youtu.be/\(videoId)")!
        }

        guard let seconds, Int(seconds) > 0 else {
            return baseURL
        }

        let secs = Int(seconds)
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            return baseURL
        }

        let host = components.host?.lowercased() ?? ""
        if host.contains("youtu.be") || host.contains("youtube.com") {
            var items = (components.queryItems ?? []).filter { $0.name != "t" }
            items.append(URLQueryItem(name: "t", value: "\(secs)"))
            components.queryItems = items
        } else {
            // Standard W3C Media Fragments timecode (#t=123) supported by browsers, Vimeo, PeerTube, etc.
            components.fragment = "t=\(secs)"
        }
        return components.url ?? baseURL
    }

    static func browserURL(
        videoId: String,
        videoURLString: String?,
        atSeconds seconds: Double? = nil
    ) -> URL {
        shareURL(videoId: videoId, videoURLString: videoURLString, atSeconds: seconds)
    }

    static func youtubeVideoID(from urlString: String?) -> String? {
        guard let urlString, let url = URL(string: urlString), let host = url.host?.lowercased() else {
            return nil
        }
        if host.contains("youtu.be") {
            let candidate = url.pathComponents.dropFirst().first
            return candidate.flatMap { $0.isEmpty ? nil : $0 }
        }
        if host.contains("youtube.com") {
            if let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
               let v = comps.queryItems?.first(where: { $0.name == "v" })?.value, !v.isEmpty {
                return v
            }
            let parts = url.pathComponents
            if let idx = parts.firstIndex(where: { $0 == "shorts" || $0 == "live" || $0 == "embed" }),
               parts.indices.contains(idx + 1) {
                return parts[idx + 1]
            }
        }
        return nil
    }

    static func formatTimecode(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }
}
