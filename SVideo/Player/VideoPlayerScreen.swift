import SwiftData
import SwiftUI
import UIKit

struct VideoPlayerScreen: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openURL) private var openURL
    @Environment(CloudSyncEngine.self) private var syncEngine
    @Environment(SleepTimerManager.self) private var sleepTimer

    @AppStorage("autoPlayNextInList") private var autoPlayNextInList = false

    @State private var video: VideoItem
    private let queue: [VideoItem]

    @State private var playerController = YouTubePlayerController()
    @State private var directCurrentTime: Double = 0
    @State private var directDuration: Double = 0
    @State private var directPlaybackFailed = false
    @State private var pauseTrigger = 0
    @State private var dimOpacity: Double = 0.0
    @State private var browserURL: IdentifiableURL?
    @State private var toastMessage: String?
    @State private var lastPersistedAt: Date = .distantPast

    init(video: VideoItem, queue: [VideoItem] = []) {
        _video = State(initialValue: video)
        self.queue = queue
    }

    private var activeTime: Double {
        max(playerController.currentTime, directCurrentTime, video.positionSeconds)
    }

    private var activeDuration: Double {
        max(playerController.duration, directDuration, video.durationSeconds)
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                playerSurface
                    .id(video.videoId)
                    .onChange(of: video.videoId) { _, _ in
                        directPlaybackFailed = false
                    }
                if dimOpacity > 0 {
                    Color.black
                        .opacity(dimOpacity)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                        .animation(.easeInOut(duration: 0.3), value: dimOpacity)
                }
            }
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .background(Color.black)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    headerSection
                    actionBar
                }
                .padding(24)
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(video.channelTitle.isEmpty ? "S-Video" : video.channelTitle)
        .navigationBarTitleDisplayMode(.inline)
        .overlay(alignment: .bottom) {
            if let toastMessage {
                Text(toastMessage)
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .sheet(item: $browserURL) { item in
            SafariBrowserSheet(url: item.url)
                .ignoresSafeArea()
        }
        .onAppear {
            configureCallbacks()
        }
        .onDisappear {
            persistProgress(currentTime: activeTime, duration: activeDuration, force: true)
        }
    }

    @ViewBuilder
    private var playerSurface: some View {
        if let mediaURL = video.mediaURL, !directPlaybackFailed {
            DirectMediaPlayerView(
                url: mediaURL,
                startSeconds: video.watchStatus == .watched ? 0 : video.positionSeconds,
                onProgress: { current, duration in
                    directCurrentTime = current
                    if duration > 0 { directDuration = duration }
                    persistProgress(currentTime: current, duration: duration, force: false)
                },
                onPaused: { current, duration in
                    directCurrentTime = current
                    if duration > 0 { directDuration = duration }
                    persistProgress(currentTime: current, duration: duration, force: true)
                },
                onEnded: { duration in
                    handleVideoEnded(duration: duration)
                },
                onFailed: {
                    directPlaybackFailed = true
                },
                volume: sleepTimer.currentVolume,
                pauseTrigger: $pauseTrigger
            )
        } else if let youtubeId = video.youtubeVideoId {
            YouTubeWebPlayer(
                videoId: youtubeId,
                startSeconds: video.watchStatus == .watched ? 0 : video.positionSeconds,
                controller: playerController
            )
        } else {
            GenericWebVideoPlayer(
                url: VideoLinkBuilder.browserURL(videoId: video.videoId, videoURLString: video.videoURLString),
                pauseTrigger: pauseTrigger
            )
        }
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(video.title.isEmpty ? video.videoId : video.title)
                .font(.title2.bold())

            HStack(spacing: 12) {
                if !video.channelTitle.isEmpty {
                    Text(video.channelTitle)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Text(video.publishedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Spacer()

                Label(video.watchStatus.label, systemImage: video.watchStatus.symbolName)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.secondary.opacity(0.15), in: Capsule())
            }

            if activeDuration > 0 || activeTime > 0 {
                HStack(spacing: 6) {
                    Text(VideoLinkBuilder.formatTimecode(activeTime))
                    if activeDuration > 0 {
                        Text("/")
                        Text(VideoLinkBuilder.formatTimecode(activeDuration))
                    }
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
        }
    }

    private var actionBar: some View {
        HStack(spacing: 12) {
            Menu {
                Button {
                    let url = VideoLinkBuilder.shareURL(videoId: video.videoId, videoURLString: video.videoURLString)
                    UIPasteboard.general.string = url.absoluteString
                    showToast("Copied link")
                } label: {
                    Label("Copy Link", systemImage: "link")
                }

                Button {
                    let url = VideoLinkBuilder.shareURL(
                        videoId: video.videoId,
                        videoURLString: video.videoURLString,
                        atSeconds: activeTime
                    )
                    UIPasteboard.general.string = url.absoluteString
                    showToast("Copied link at \(VideoLinkBuilder.formatTimecode(activeTime))")
                } label: {
                    Label(
                        "Copy Link at \(VideoLinkBuilder.formatTimecode(activeTime))",
                        systemImage: "clock.badge.checkmark"
                    )
                }
            } label: {
                Label("Copy Link", systemImage: "link")
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("Copy Link")
            .accessibilityHint("Copy video link or link at current timecode")

            Menu {
                ForEach([15, 30, 45, 60], id: \.self) { minutes in
                    Button("\(minutes) minutes") {
                        sleepTimer.start(minutes: minutes)
                        showToast("Sleep timer set for \(minutes)m")
                    }
                }
                Button("End of Video") {
                    sleepTimer.setEndOfVideo()
                    showToast("Sleep timer: End of Video")
                }
                if sleepTimer.isActive {
                    Divider()
                    Button("+15 minutes") {
                        sleepTimer.addMinutes(15)
                    }
                    Button("Cancel Sleep Timer", role: .destructive) {
                        sleepTimer.cancel()
                        showToast("Sleep timer cancelled")
                    }
                }
            } label: {
                if let badge = sleepTimer.badgeLabel {
                    Label(badge, systemImage: "moon.zzz.fill")
                        .font(.subheadline.monospacedDigit())
                } else {
                    Image(systemName: "moon.zzz")
                }
            }
            .buttonStyle(.bordered)
            .tint(sleepTimer.isActive ? .accentColor : nil)
            .accessibilityLabel("Sleep Timer")
            .accessibilityValue(sleepTimer.badgeLabel ?? "Off")
            .accessibilityHint("Set a countdown or end-of-video sleep timer")

            Menu {
                Button("Off") { dimOpacity = 0.0 }
                Button("Dim 40%") { dimOpacity = 0.40 }
                Button("Dim 65%") { dimOpacity = 0.65 }
                Button("Dim 80%") { dimOpacity = 0.80 }
            } label: {
                Image(systemName: dimOpacity > 0 ? "sun.min.fill" : "sun.min")
            }
            .buttonStyle(.bordered)
            .tint(dimOpacity > 0 ? .accentColor : nil)
            .accessibilityLabel("Dim Screen")
            .accessibilityValue(dimOpacity > 0 ? "\(Int(dimOpacity * 100)) percent" : "Off")
            .accessibilityHint("Adjust nightstand screen dimming")

            Menu {
                Button {
                    pausePlayback()
                    browserURL = IdentifiableURL(
                        url: VideoLinkBuilder.browserURL(
                            videoId: video.videoId,
                            videoURLString: video.videoURLString,
                            atSeconds: activeTime
                        )
                    )
                } label: {
                    Label("Open in In-App Browser", systemImage: "safari")
                }

                Button {
                    pausePlayback()
                    openURL(
                        VideoLinkBuilder.browserURL(
                            videoId: video.videoId,
                            videoURLString: video.videoURLString,
                            atSeconds: activeTime
                        )
                    )
                } label: {
                    Label("Open in Safari", systemImage: "arrow.up.right.square")
                }
            } label: {
                Label("Open in Browser", systemImage: "safari")
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("Open in Browser")
            .accessibilityHint("Open video in an in-app browser or Safari")

            Spacer()

            Button {
                toggleWatchedStatus()
            } label: {
                Image(systemName: video.watchStatus == .watched ? "checkmark.circle.fill" : "checkmark.circle")
            }
            .buttonStyle(.borderedProminent)
            .accessibilityLabel(video.watchStatus == .watched ? "Mark as Unwatched" : "Mark as Watched")
            .accessibilityValue(video.watchStatus.label)
        }
    }

    private func pausePlayback() {
        playerController.pause()
        pauseTrigger += 1
    }

    private func configureCallbacks() {
        sleepTimer.onExpire = {
            pausePlayback()
        }
        sleepTimer.onVolumeChange = { volume in
            playerController.setVolume(volume)
        }

        playerController.onProgressUpdate = { currentTime, duration in
            persistProgress(currentTime: currentTime, duration: duration, force: false)
        }

        playerController.onPlaybackStateChanged = { state, currentTime, duration in
            switch state {
            case .paused:
                persistProgress(currentTime: currentTime, duration: duration, force: true)
            case .ended:
                handleVideoEnded(duration: duration)
            default:
                break
            }
        }
    }

    private func handleVideoEnded(duration: Double) {
        let stoppedByEndOfVideoTimer = sleepTimer.mode == .endOfVideo
        markCompleted(duration: duration)
        sleepTimer.handleVideoEnded()

        guard !stoppedByEndOfVideoTimer, autoPlayNextInList else { return }
        advanceToNextVideoIfAvailable()
    }

    private func advanceToNextVideoIfAvailable() {
        guard let currentIndex = queue.firstIndex(where: { $0.videoId == video.videoId }) else { return }
        let nextIndex = queue.index(after: currentIndex)
        guard queue.indices.contains(nextIndex) else { return }

        let nextVideo = queue[nextIndex]
        video = nextVideo
        directCurrentTime = 0
        directDuration = 0
        lastPersistedAt = .distantPast
        playerController = YouTubePlayerController()
        configureCallbacks()
        let nextTitle = nextVideo.title.isEmpty ? nextVideo.videoId : nextVideo.title
        showToast("Up next: \(nextTitle)")
    }

    private func persistProgress(currentTime: Double, duration: Double, force: Bool) {
        guard currentTime >= 1 else { return }
        if !force, Date.now.timeIntervalSince(lastPersistedAt) < 15 {
            return
        }
        lastPersistedAt = .now

        if duration > 0 {
            video.durationSeconds = duration
        }
        video.positionSeconds = currentTime

        let isNearEnd = duration > 30 && (currentTime / duration) >= 0.95
        if isNearEnd {
            video.watchStatus = .watched
            video.completedAt = video.completedAt ?? .now
        } else if video.watchStatus != .watched {
            video.watchStatus = .inProgress
        }
        video.stateUpdatedAt = .now
        try? modelContext.save()
        syncEngine.enqueueVideoStateSave(video.stateSnapshot)
    }

    private func markCompleted(duration: Double) {
        if duration > 0 {
            video.durationSeconds = duration
            video.positionSeconds = duration
        }
        video.watchStatus = .watched
        video.completedAt = .now
        video.stateUpdatedAt = .now
        try? modelContext.save()
        syncEngine.enqueueVideoStateSave(video.stateSnapshot)
    }

    private func toggleWatchedStatus() {
        if video.watchStatus == .watched {
            video.watchStatus = .unwatched
            video.positionSeconds = 0
            video.completedAt = nil
        } else {
            video.watchStatus = .watched
            video.completedAt = .now
        }
        video.stateUpdatedAt = .now
        try? modelContext.save()
        syncEngine.enqueueVideoStateSave(video.stateSnapshot)
        showToast(video.watchStatus == .watched ? "Marked as watched" : "Marked as unwatched")
    }

    private func showToast(_ message: String) {
        withAnimation { toastMessage = message }
        Task {
            try? await Task.sleep(for: .seconds(2))
            withAnimation {
                if toastMessage == message { toastMessage = nil }
            }
        }
    }
}

struct IdentifiableURL: Identifiable {
    let id = UUID()
    let url: URL
}
