import AVKit
import SwiftUI
import WebKit

/// Native `AVPlayer` wrapper for direct RSS/Atom video enclosures (`.mp4`, `.m4v`, `.mov`, `.m3u8`).
struct DirectMediaPlayerView: View {
    let url: URL
    let startSeconds: Double
    let onProgress: (Double, Double) -> Void
    let onPaused: (Double, Double) -> Void
    let onEnded: (Double) -> Void
    var onFailed: (() -> Void)? = nil
    let volume: Double
    @Binding var pauseTrigger: Int

    @State private var player: AVPlayer?
    @State private var timeObserver: Any?
    @State private var endObserver: NSObjectProtocol?
    @State private var statusObserver: NSKeyValueObservation?

    var body: some View {
        VideoPlayer(player: player)
            .onAppear { setupPlayer() }
            .onDisappear { tearDownPlayer() }
            .onChange(of: volume) { _, newVolume in
                player?.volume = Float(min(1.0, max(0.0, newVolume)))
            }
            .onChange(of: pauseTrigger) { _, _ in
                player?.pause()
                if let player {
                    let current = player.currentTime().seconds
                    let duration = player.currentItem?.duration.seconds ?? 0
                    onPaused(current.isFinite ? current : 0, duration.isFinite ? duration : 0)
                }
            }
    }

    private func setupPlayer() {
        let avPlayer = AVPlayer(url: url)
        if startSeconds > 1 {
            avPlayer.seek(to: CMTime(seconds: startSeconds, preferredTimescale: 600))
        }
        avPlayer.play()

        let interval = CMTime(seconds: 1, preferredTimescale: 600)
        timeObserver = avPlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
            Task { @MainActor in
                let current = time.seconds
                let duration = avPlayer.currentItem?.duration.seconds ?? 0
                if current.isFinite {
                    onProgress(current, duration.isFinite ? duration : 0)
                }
            }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: avPlayer.currentItem,
            queue: .main
        ) { _ in
            Task { @MainActor in
                let duration = avPlayer.currentItem?.duration.seconds ?? 0
                onEnded(duration.isFinite ? duration : 0)
            }
        }

        statusObserver = avPlayer.currentItem?.observe(\.status, options: [.new]) { item, _ in
            if item.status == .failed {
                Task { @MainActor in
                    onFailed?()
                }
            }
        }

        player = avPlayer
    }

    private func tearDownPlayer() {
        statusObserver?.invalidate()
        statusObserver = nil
        if let player {
            let current = player.currentTime().seconds
            let duration = player.currentItem?.duration.seconds ?? 0
            onPaused(current.isFinite ? current : 0, duration.isFinite ? duration : 0)
            player.pause()
            if let timeObserver {
                player.removeTimeObserver(timeObserver)
            }
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        timeObserver = nil
        endObserver = nil
        player = nil
    }
}

/// Generic inline `WKWebView` for web-hosted video pages (Vimeo, PeerTube, etc.) without direct enclosures.
struct GenericWebVideoPlayer: UIViewRepresentable {
    let url: URL
    let pauseTrigger: Int

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.allowsPictureInPictureMediaPlayback = true
        config.allowsAirPlayForMediaPlayback = true

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.backgroundColor = .black
        context.coordinator.lastURL = url
        context.coordinator.lastPauseTrigger = pauseTrigger
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        if context.coordinator.lastURL != url {
            context.coordinator.lastURL = url
            webView.load(URLRequest(url: url))
        }
        if context.coordinator.lastPauseTrigger != pauseTrigger {
            context.coordinator.lastPauseTrigger = pauseTrigger
            webView.evaluateJavaScript(
                "document.querySelectorAll('video,audio').forEach(function(el){ el.pause(); });"
            )
        }
    }

    final class Coordinator {
        var lastURL: URL?
        var lastPauseTrigger: Int = 0
    }
}
