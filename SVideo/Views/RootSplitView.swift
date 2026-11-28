import SwiftData
import SwiftUI

enum SidebarDestination: String, CaseIterable, Identifiable {
    case timeline = "Timeline"
    case subscriptions = "All Sources"
    case settings = "Settings"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .timeline: "play.rectangle.on.rectangle"
        case .subscriptions: "rectangle.stack.badge.plus"
        case .settings: "gearshape"
        }
    }
}

struct RootSplitView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(CloudSyncEngine.self) private var syncEngine

    @AppStorage("autoHideSidebar") private var autoHideSidebar = false

    @State private var selection: SidebarDestination? = .timeline
    @State private var detailPath = NavigationPath()
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var hasStarted = false

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List(SidebarDestination.allCases) { item in
                Button {
                    var tx = Transaction()
                    tx.disablesAnimations = true
                    withTransaction(tx) {
                        detailPath = NavigationPath()
                        selection = item
                    }
                    if autoHideSidebar {
                        columnVisibility = .detailOnly
                    }
                } label: {
                    Label(item.rawValue, systemImage: item.systemImage)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowBackground(
                    selection == item
                        ? RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.16))
                        : nil
                )
                .foregroundStyle(selection == item ? Color.accentColor : Color.primary)
                .accessibilityAddTraits(selection == item ? [.isSelected] : [])
            }
            .listStyle(.sidebar)
            .navigationTitle("S-Video")
            .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 260)
        } detail: {
            NavigationStack(path: $detailPath) {
                switch selection ?? .timeline {
                case .timeline:
                    TimelineView(onOpenSyncSettings: {
                        detailPath = NavigationPath()
                        selection = .settings
                    })
                case .subscriptions:
                    SubscriptionsView()
                case .settings:
                    BackupSettingsView()
                }
            }
            .id(selection ?? .timeline)
        }
        .navigationSplitViewStyle(.balanced)
        .task {
            guard !hasStarted else { return }
            hasStarted = true
            if autoHideSidebar {
                columnVisibility = .detailOnly
            }
            syncEngine.start(modelContext: modelContext) {
                Task {
                    await coordinator.refreshFeeds(in: modelContext)
                }
            }
            await coordinator.refreshFeeds(in: modelContext)
        }
        .onChange(of: autoHideSidebar) { _, shouldHide in
            columnVisibility = shouldHide ? .detailOnly : .all
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                Task {
                    await syncEngine.refreshAccountStatus()
                    if syncEngine.isEnabled {
                        await coordinator.syncAndRefresh(syncEngine: syncEngine, in: modelContext)
                    } else {
                        await coordinator.refreshFeeds(in: modelContext)
                    }
                }
            }
        }
    }
}
