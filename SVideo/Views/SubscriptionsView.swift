import SwiftData
import SwiftUI

struct SubscriptionsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openURL) private var openURL
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(CloudSyncEngine.self) private var syncEngine

    @AppStorage("confirmBeforeDeletingSources") private var confirmBeforeDeletingSources = true

    @Query(
        filter: #Predicate<Channel> { $0.isSubscribed },
        sort: \Channel.title
    ) private var channels: [Channel]

    @State private var channelInput = ""
    @State private var isAdding = false
    @State private var errorMessage: String?
    @State private var selectedSourceIds: Set<String> = []
    @State private var pendingDeleteChannels: [Channel] = []
    @State private var showDeleteConfirmation = false

    private var selectedChannels: [Channel] {
        channels.filter { selectedSourceIds.contains($0.channelId) }
    }

    var body: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    TextField("Source URL (RSS/Atom), channel URL, @handle, or video link", text: $channelInput)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .onSubmit { addChannel() }
                        .accessibilityLabel("Video source address")

                    Button {
                        addChannel()
                    } label: {
                        if isAdding {
                            ProgressView()
                                .accessibilityLabel("Adding video source")
                        } else {
                            Label("Add Source", systemImage: "plus.circle.fill")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(channelInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isAdding)
                    .accessibilityLabel("Add Video Source")
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .accessibilityLabel("Error: \(errorMessage)")
                }
            } header: {
                Text("Add Video Source")
            } footer: {
                Text("Supports any RSS 2.0 or Atom video source (video podcasts, PeerTube, Vimeo, YouTube channels, etc.) with no content-type filtering.")
            }

            Section("All Sources (\(channels.count))") {
                if channels.isEmpty {
                    Text("No video sources added yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(channels) { channel in
                        let isSelected = selectedSourceIds.contains(channel.channelId)
                        HStack(spacing: 12) {
                            Button {
                                toggleSelection(for: channel.channelId)
                            } label: {
                                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                    .font(.title3)
                                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Select \(channel.title)")
                            .accessibilityValue(isSelected ? "Selected" : "Not selected")

                            VStack(alignment: .leading, spacing: 3) {
                                Text(channel.title)
                                    .font(.headline)
                                Text(channel.handle ?? channel.channelId)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                            .accessibilityElement(children: .combine)

                            Spacer()

                            if let url = channel.channelURL {
                                Button {
                                    openURL(url)
                                } label: {
                                    Image(systemName: "safari")
                                }
                                .buttonStyle(.borderless)
                                .help("Open source in browser")
                                .accessibilityLabel("Open \(channel.title) in browser")
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: !confirmBeforeDeletingSources) {
                            Button("Delete", role: .destructive) {
                                requestDelete([channel])
                            }
                            .accessibilityLabel("Delete \(channel.title)")
                        }
                    }
                }
            }
        }
        .navigationTitle("All Sources")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if !selectedSourceIds.isEmpty {
                    Button("Clear") {
                        selectedSourceIds.removeAll()
                    }
                    .accessibilityLabel("Deselect all sources")
                }

                Button(role: .destructive) {
                    requestDelete(selectedChannels)
                } label: {
                    Image(systemName: "trash")
                }
                .disabled(selectedChannels.isEmpty)
                .accessibilityLabel(
                    selectedChannels.isEmpty
                        ? "Delete selected sources"
                        : "Delete \(selectedChannels.count) selected \(selectedChannels.count == 1 ? "source" : "sources")"
                )
            }
        }
        .confirmationDialog(
            pendingDeleteChannels.count == 1
                ? "Delete \"\(pendingDeleteChannels[0].title)\"?"
                : "Delete \(pendingDeleteChannels.count) Video Sources?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                performDelete(pendingDeleteChannels)
            }
            Button("Cancel", role: .cancel) {
                pendingDeleteChannels = []
            }
        } message: {
            Text("Removed sources will stop appearing in your timeline and sync across your iPads.")
        }
    }

    private func toggleSelection(for channelId: String) {
        if selectedSourceIds.contains(channelId) {
            selectedSourceIds.remove(channelId)
        } else {
            selectedSourceIds.insert(channelId)
        }
    }

    private func requestDelete(_ targets: [Channel]) {
        guard !targets.isEmpty else { return }
        if confirmBeforeDeletingSources {
            pendingDeleteChannels = targets
            showDeleteConfirmation = true
        } else {
            performDelete(targets)
        }
    }

    private func performDelete(_ targets: [Channel]) {
        for channel in targets {
            selectedSourceIds.remove(channel.channelId)
            coordinator.unsubscribe(channel, syncEngine: syncEngine, in: modelContext)
        }
        pendingDeleteChannels = []
    }

    private func addChannel() {
        let input = channelInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty, !isAdding else { return }
        isAdding = true
        errorMessage = nil

        Task {
            defer { isAdding = false }
            do {
                _ = try await coordinator.subscribe(input: input, syncEngine: syncEngine, in: modelContext)
                channelInput = ""
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
