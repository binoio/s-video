import SwiftUI
import WebKit

enum YouTubePlaybackState: Int, Sendable {
    case unstarted = -1
    case ended = 0
    case playing = 1
    case paused = 2
    case buffering = 3
    case cued = 5
}

@MainActor
@Observable
final class YouTubePlayerController {
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    private(set) var playbackState: YouTubePlaybackState = .unstarted
    private(set) var isReady = false

    @ObservationIgnored weak var webView: WKWebView?
    @ObservationIgnored var onProgressUpdate: (@MainActor (Double, Double) -> Void)?
    @ObservationIgnored var onPlaybackStateChanged: (@MainActor (YouTubePlaybackState, Double, Double) -> Void)?

    func play() {
        webView?.evaluateJavaScript("window.svideoPlay && window.svideoPlay();")
    }

    func pause() {
        webView?.evaluateJavaScript("window.svideoPause && window.svideoPause();")
    }

    func seek(to seconds: Double) {
        let clamped = max(0, seconds)
        webView?.evaluateJavaScript("window.svideoSeek && window.svideoSeek(\(clamped));")
    }

    func setVolume(_ volume: Double) {
        let clamped = min(1.0, max(0.0, volume))
        webView?.evaluateJavaScript("window.svideoSetVolume && window.svideoSetVolume(\(clamped));")
    }

    fileprivate func handleMessage(_ body: [String: Any]) {
        guard let event = body["event"] as? String else { return }
        let time = (body["currentTime"] as? Double) ?? currentTime
        let dur = (body["duration"] as? Double) ?? duration

        if time.isFinite, time >= 0 { currentTime = time }
        if dur.isFinite, dur > 0 { duration = dur }

        switch event {
        case "ready":
            isReady = true
        case "progress":
            onProgressUpdate?(currentTime, duration)
        case "state":
            if let raw = body["state"] as? Int, let state = YouTubePlaybackState(rawValue: raw) {
                playbackState = state
                onPlaybackStateChanged?(state, currentTime, duration)
            }
        default:
            break
        }
    }
}

/// Direct top-level `WKWebView` player that loads the YouTube embed page directly
/// (native YouTube player UI, PiP, AirPlay, fullscreen, captions, quality) and observes
/// the page's HTML5 `<video>` element for timecode sync and Sleep Timer control.
struct YouTubeWebPlayer: UIViewRepresentable {
    let videoId: String
    let startSeconds: Double
    let controller: YouTubePlayerController

    func makeCoordinator() -> Coordinator {
        Coordinator(controller: controller)
    }

    func makeUIView(context: Context) -> WKWebView {
        let contentController = WKUserContentController()
        contentController.add(context.coordinator, name: "svideoPlayer")
        contentController.addUserScript(
            WKUserScript(
                source: Self.videoObserverScript,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            )
        )

        let config = WKWebViewConfiguration()
        config.userContentController = contentController
        config.allowsInlineMediaPlayback = true
        config.allowsPictureInPictureMediaPlayback = true
        config.allowsAirPlayForMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.preferences.isTextInteractionEnabled = false

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.backgroundColor = .black
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.navigationDelegate = context.coordinator

        // Ensure YouTube's native fullscreen button remains enabled on iPad
        if let defaultUA = webView.value(forKey: "userAgent") as? String {
            webView.customUserAgent = defaultUA.replacingOccurrences(of: "iPad", with: "iPhone")
        }

        controller.webView = webView
        context.coordinator.loadedVideoId = videoId
        loadDirectEmbed(in: webView, videoId: videoId, startSeconds: startSeconds)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        controller.webView = webView
        if context.coordinator.loadedVideoId != videoId {
            context.coordinator.loadedVideoId = videoId
            loadDirectEmbed(in: webView, videoId: videoId, startSeconds: startSeconds)
        }
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.pauseAllMediaPlayback()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "svideoPlayer")
    }

    private func loadDirectEmbed(in webView: WKWebView, videoId: String, startSeconds: Double) {
        let safeId = videoId.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
        let start = max(0, Int(startSeconds))
        let bundleId = (Bundle.main.bundleIdentifier ?? "io.bino.svideo").lowercased()
        let appOrigin = "https://\(bundleId)"

        var components = URLComponents(string: "https://www.youtube.com/embed/\(safeId)")!
        var items = [
            URLQueryItem(name: "playsinline", value: "1"),
            URLQueryItem(name: "rel", value: "0"),
            URLQueryItem(name: "fs", value: "1")
        ]
        if start > 0 {
            items.append(URLQueryItem(name: "start", value: "\(start)"))
        }
        components.queryItems = items

        guard let url = components.url else { return }
        var request = URLRequest(url: url)
        request.setValue("\(appOrigin)/", forHTTPHeaderField: "Referer")
        webView.load(request)
    }

    /// Observes the page's HTML5 `<video>` element directly without modifying ads or player UI.
    private static let videoObserverScript = """
    (function() {
      if (window.__svideoInstalled) return;
      window.__svideoInstalled = true;

      function post(payload) {
        if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.svideoPlayer) {
          window.webkit.messageHandlers.svideoPlayer.postMessage(payload);
        }
      }

      var attachedVideo = null;
      var lastReportedSec = -1;

      function getVideo() {
        return document.querySelector('video');
      }

      function attach(v) {
        if (!v || v === attachedVideo) return;
        attachedVideo = v;

        post({ event: 'ready', currentTime: v.currentTime || 0, duration: isFinite(v.duration) ? v.duration : 0 });

        v.addEventListener('play', function() {
          post({ event: 'state', state: 1, currentTime: v.currentTime || 0, duration: isFinite(v.duration) ? v.duration : 0 });
        });
        v.addEventListener('pause', function() {
          post({ event: 'state', state: 2, currentTime: v.currentTime || 0, duration: isFinite(v.duration) ? v.duration : 0 });
        });
        v.addEventListener('ended', function() {
          post({ event: 'state', state: 0, currentTime: v.currentTime || 0, duration: isFinite(v.duration) ? v.duration : 0 });
        });
        v.addEventListener('timeupdate', function() {
          var sec = Math.floor(v.currentTime || 0);
          if (sec !== lastReportedSec) {
            lastReportedSec = sec;
            post({ event: 'progress', currentTime: v.currentTime || 0, duration: isFinite(v.duration) ? v.duration : 0 });
          }
        });
      }

      attach(getVideo());
      var observer = new MutationObserver(function() {
        attach(getVideo());
      });
      observer.observe(document.documentElement, { childList: true, subtree: true });

      window.svideoPlay = function() {
        var v = getVideo();
        if (v) v.play();
      };
      window.svideoPause = function() {
        var v = getVideo();
        if (v) v.pause();
      };
      window.svideoSeek = function(s) {
        var v = getVideo();
        if (v) v.currentTime = s;
      };
      window.svideoSetVolume = function(vol) {
        var v = getVideo();
        if (v) v.volume = Math.max(0, Math.min(1, vol));
      };
    })();
    """

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        let controller: YouTubePlayerController
        var loadedVideoId: String = ""

        init(controller: YouTubePlayerController) {
            self.controller = controller
        }

        nonisolated func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard let body = message.body as? [String: Any] else { return }
            let event = body["event"] as? String
            let currentTime = body["currentTime"] as? Double
            let duration = body["duration"] as? Double
            let state = body["state"] as? Int
            Task { @MainActor in
                var payload: [String: Any] = [:]
                if let event { payload["event"] = event }
                if let currentTime { payload["currentTime"] = currentTime }
                if let duration { payload["duration"] = duration }
                if let state { payload["state"] = state }
                self.controller.handleMessage(payload)
            }
        }
    }
}
