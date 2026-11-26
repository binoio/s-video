import SwiftData
import SwiftUI
import UIKit

enum TimelineFilter: String, CaseIterable, Identifiable {
    case timeline = "Timeline"
    case unwatched = "Unwatched"
    case inProgress = "In Progress"
    case completed = "Completed"

    var id: String { rawValue }
}

struct TimelineView: View {
    var onOpenSyncSettings: () -> Void = {}

    @Environment(\.modelContext) private var modelContext
    @Environment(\.openURL) private var openURL
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(CloudSyncEngine.self) private var syncEngine
    @Environment(SleepTimerManager.self) private var sleepTimer

    @AppStorage("recentlyCompletedDays") private var recentlyCompletedDays = 7

    @Query(sort: \VideoItem.publishedAt, order: .reverse) private var allVideos: [VideoItem]
    @Query(filter: #Predicate<Channel> { $0.isSubscribed }) private var subscribedChannels: [Channel]

    @State private var selectedFilter: TimelineFilter = .timeline
    @State private var searchText = ""
    @State private var browserURL: IdentifiableURL?
    @State private var toastMessage: String?
    @State private var showSyncStatusInfo = false

    private var subscribedChannelIds: Set<String> {
        Set(subscribedChannels.map(\.channelId))
    }

    private var visibleVideos: [VideoItem] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -recentlyCompletedDays, to: .now) ?? .distantPast
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        return allVideos.filter { video in
            guard !video.title.isEmpty else { return false }
            guard subscribedChannelIds.contains(video.channelId) else { return false }

            let matchesStatus: Bool
            switch selectedFilter {
            case .timeline:
                switch video.watchStatus {
                case .unwatched, .inProgress:
                    matchesStatus = true
                case .watched:
                    matchesStatus = (video.completedAt ?? video.stateUpdatedAt) >= cutoff
                }
            case .unwatched:
                matchesStatus = video.watchStatus == .unwatched
            case .inProgress:
                matchesStatus = video.watchStatus == .inProgress
            case .completed:
                matchesStatus = video.watchStatus == .watched
            }

            guard matchesStatus else { return false }
            if query.isEmpty { return true }
            return video.title.lowercased().contains(query)
                || video.channelTitle.lowercased().contains(query)
        }
    }

    var body: some View {
        Group {
            if subscribedChannels.isEmpty {
                ContentUnavailableView(
                    "No Sources Yet",
                    systemImage: "play.tv",
                    description: Text("Add a video source in All Sources, or import an OPML backup to populate your timeline.")
                )
            } else if visibleVideos.isEmpty {
                ContentUnavailableView(
                    "No Videos to Show",
                    systemImage: "checkmark.circle",
                    description: Text(coordinator.isRefreshing ? "Refreshing video sources…" : "Pull down to refresh your video sources.")
                )
            } else {
                List {
                    ForEach(visibleVideos) { video in
                        NavigationLink(value: video) {
                            VideoRowView(video: video)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button {
                                toggleWatched(video)
                            } label: {
                                Label(
                                    video.watchStatus == .watched ? "Unwatched" : "Watched",
                                    systemImage: video.watchStatus == .watched ? "arrow.uturn.backward" : "checkmark"
                                )
                            }
                            .tint(video.watchStatus == .watched ? .orange : .green)
                        }
                        .contextMenu {
                            videoContextMenu(for: video)
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .refreshable {
                    await coordinator.syncAndRefresh(syncEngine: syncEngine, in: modelContext)
                }
            }
        }
        .navigationTitle("Timeline")
        .searchable(text: $searchText, prompt: "Search videos or channels")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu {
                    Picker("Filter", selection: $selectedFilter) {
                        ForEach(TimelineFilter.allCases) { filter in
                            Text(filter.rawValue).tag(filter)
                        }
                    }
                } label: {
                    Label(selectedFilter.rawValue, systemImage: "line.3.horizontal.decrease.circle")
                        .labelStyle(.titleAndIcon)
                }
                .accessibilityLabel("Filter timeline")
                .accessibilityValue(selectedFilter.rawValue)

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
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(Color.accentColor)
                    } else {
                        Label("Sleep Timer", systemImage: "moon.zzz")
                    }
                }
                .accessibilityLabel("Sleep Timer")
                .accessibilityValue(sleepTimer.badgeLabel ?? "Off")

                syncStatusBadge

                Button {
                    Task {
                        await coordinator.syncAndRefresh(syncEngine: syncEngine, in: modelContext)
                    }
                } label: {
                    if coordinator.isRefreshing {
                        ProgressView()
                            .accessibilityLabel("Refreshing video sources")
                    } else {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(coordinator.isRefreshing)
                .accessibilityLabel("Refresh video sources")
            }
        }
        .navigationDestination(for: VideoItem.self) { video in
            VideoPlayerScreen(video: video, queue: visibleVideos)
        }
        .sheet(item: $browserURL) { item in
            SafariBrowserSheet(url: item.url)
                .ignoresSafeArea()
        }
        .alert(syncInfoTitle, isPresented: $showSyncStatusInfo) {
            Button("Open Settings") {
                onOpenSyncSettings()
            }
            Button("OK", role: .cancel) {}
        } message: {
            Text(syncInfoMessage)
        }
        .overlay(alignment: .bottom) {
            if let toastMessage {
                Text(toastMessage)
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.bottom, 20)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    private var syncStatusBadge: some View {
        Button {
            showSyncStatusInfo = true
        } label: {
            Label(syncEngine.status.label, systemImage: syncEngine.status.systemImage)
                .labelStyle(.iconOnly)
                .foregroundStyle(syncEngine.status.isProblem ? .red : .secondary)
        }
        .help(syncEngine.status.label)
        .accessibilityLabel("iCloud Sync Status")
        .accessibilityValue(syncEngine.status.label)
        .accessibilityHint("Shows iCloud sync details and option to open Settings")
    }

    private var syncInfoTitle: String {
        switch syncEngine.status {
        case .disabled: "iCloud Sync Is Off"
        case .idle, .synced: "iCloud Sync Active"
        case .syncing: "Syncing with iCloud"
        case .unavailable: "iCloud Sync Unavailable"
        case .error: "iCloud Sync Error"
        }
    }

    private var syncInfoMessage: String {
        switch syncEngine.status {
        case .disabled:
            return "iCloud Sync is currently turned off on this iPad. Turn it on in Settings to keep your video sources and watch progress in sync across iPads."
        case .idle:
            return "iCloud Sync is ready to keep your video sources and watch progress synced across your iPads."
        case .syncing:
            return "S-Video is currently syncing your sources and watch progress with iCloud."
        case .synced(let date):
            return "Last synced \(date.formatted(.relative(presentation: .named)))."
        case .unavailable(let reason):
            return "\(reason). Sign in to iCloud in iPadOS Settings, then enable iCloud Sync in Settings."
        case .error(let message):
            return "iCloud Sync encountered an error: \(message). You can check settings or retry in Settings."
        }
    }

    @ViewBuilder
    private func videoContextMenu(for video: VideoItem) -> some View {
        Button {
            toggleWatched(video)
        } label: {
            Label(
                video.watchStatus == .watched ? "Mark as Unwatched" : "Mark as Watched",
                systemImage: video.watchStatus == .watched ? "arrow.uturn.backward.circle" : "checkmark.circle"
            )
        }

        Divider()

        Button {
            UIPasteboard.general.string = VideoLinkBuilder.shareURL(
                videoId: video.videoId,
                videoURLString: video.videoURLString
            ).absoluteString
            showToast("Copied video link")
        } label: {
            Label("Copy Link", systemImage: "link")
        }

        if video.positionSeconds >= 1 {
            Button {
                UIPasteboard.general.string = VideoLinkBuilder.shareURL(
                    videoId: video.videoId,
                    videoURLString: video.videoURLString,
                    atSeconds: video.positionSeconds
                ).absoluteString
                showToast("Copied link at \(VideoLinkBuilder.formatTimecode(video.positionSeconds))")
            } label: {
                Label(
                    "Copy Link at \(VideoLinkBuilder.formatTimecode(video.positionSeconds))",
                    systemImage: "clock.badge.checkmark"
                )
            }
        }

        Divider()

        Button {
            browserURL = IdentifiableURL(
                url: VideoLinkBuilder.browserURL(
                    videoId: video.videoId,
                    videoURLString: video.videoURLString,
                    atSeconds: video.positionSeconds
                )
            )
        } label: {
            Label("View in In-App Browser", systemImage: "safari")
        }

        Button {
            openURL(
                VideoLinkBuilder.browserURL(
                    videoId: video.videoId,
                    videoURLString: video.videoURLString,
                    atSeconds: video.positionSeconds
                )
            )
        } label: {
            Label("Open in Safari", systemImage: "arrow.up.right.square")
        }
    }

    private func toggleWatched(_ video: VideoItem) {
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

private struct VideoRowView: View {
    let video: VideoItem

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack(alignment: .bottom) {
                AsyncImage(url: video.thumbnailURL) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    default:
                        Rectangle()
                            .fill(Color.secondary.opacity(0.2))
                            .overlay {
                                Image(systemName: "play.rectangle.fill")
                                    .foregroundStyle(.secondary)
                            }
                    }
                }
                .frame(width: 176, height: 99)
                .clipShape(RoundedRectangle(cornerRadius: 10))

                if video.watchStatus == .inProgress, video.progressFraction > 0 {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Rectangle().fill(Color.black.opacity(0.45))
                            Rectangle()
                                .fill(Color.accentColor)
                                .frame(width: geo.size.width * video.progressFraction)
                        }
                    }
                    .frame(height: 4)
                    .clipShape(RoundedRectangle(cornerRadius: 2))
                    .padding(.horizontal, 4)
                    .padding(.bottom, 4)
                }
            }
            .frame(width: 176, height: 99)
            .opacity(video.watchStatus == .watched ? 0.55 : 1.0)

            VStack(alignment: .leading, spacing: 6) {
                Text(video.title)
                    .font(.headline)
                    .lineLimit(2)
                    .foregroundStyle(video.watchStatus == .watched ? .secondary : .primary)

                Text(video.channelTitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                HStack(spacing: 10) {
                    Text(video.publishedAt.formatted(.relative(presentation: .named)))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if video.watchStatus == .inProgress, video.positionSeconds > 0 {
                        Label(
                            VideoLinkBuilder.formatTimecode(video.positionSeconds),
                            systemImage: "play.circle.fill"
                        )
                        .font(.caption.monospacedDigit().weight(.medium))
                        .foregroundStyle(Color.accentColor)
                    } else if video.watchStatus == .watched {
                        Label("Watched", systemImage: "checkmark.circle.fill")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.green)
                    }
                }
            }
            .padding(.vertical, 2)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(rowAccessibilityLabel)
        .accessibilityHint("Double tap to play video")
    }

    private var rowAccessibilityLabel: String {
        var parts = [video.title]
        if !video.channelTitle.isEmpty {
            parts.append(video.channelTitle)
        }
        parts.append(video.publishedAt.formatted(.relative(presentation: .named)))
        switch video.watchStatus {
        case .unwatched:
            parts.append("Unwatched")
        case .inProgress:
            if video.positionSeconds > 0 {
                parts.append("In progress at \(VideoLinkBuilder.formatTimecode(video.positionSeconds))")
            } else {
                parts.append("In progress")
            }
        case .watched:
            parts.append("Watched")
        }
        return parts.joined(separator: ", ")
    }
}
