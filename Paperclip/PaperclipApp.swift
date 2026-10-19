import SwiftUI

@main
struct PaperclipApp: App {
    @StateObject private var viewModel = MainViewModel()
    @StateObject private var preferences = UiPreferences.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            PaperclipThemeContainer(preferences: preferences) {
                MainNavigationView(viewModel: viewModel)
            }
            .onChange(of: scenePhase) { newPhase in
                switch newPhase {
                case .active:
                    viewModel.purgeExpiredTrash()
                case .background, .inactive:
                    // Match Android MainActivity.onStop: lock private items when leaving the app
                    viewModel.lockPrivateItems()
                @unknown default:
                    break
                }
            }
        }
    }
}
