import SwiftData
import SwiftUI
import UIKit

final class SVideoAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        application.registerForRemoteNotifications()
        return true
    }
}

@main
struct SVideoApp: App {
    @UIApplicationDelegateAdaptor(SVideoAppDelegate.self) private var appDelegate

    private let modelContainer: ModelContainer
    @State private var coordinator = AppCoordinator()
    @State private var syncEngine = CloudSyncEngine()
    @State private var sleepTimer = SleepTimerManager()

    init() {
        do {
            self.modelContainer = try LocalStore.makeContainer()
        } catch {
            fatalError("Failed to create local SwiftData container: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootSplitView()
                .environment(coordinator)
                .environment(syncEngine)
                .environment(sleepTimer)
        }
        .modelContainer(modelContainer)
    }
}
