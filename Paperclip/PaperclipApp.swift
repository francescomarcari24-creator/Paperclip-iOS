import SwiftUI

@main
struct PaperclipApp: App {
    @StateObject private var viewModel = MainViewModel()
    @StateObject private var preferences = UiPreferences.shared
    @StateObject private var appLock = AppLockManager.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var importedPackageBanner: String?

    var body: some Scene {
        WindowGroup {
            PaperclipThemeContainer(preferences: preferences) {
                ZStack {
                    MainNavigationView(viewModel: viewModel)
                        .environmentObject(viewModel)

                    if appLock.appLockEnabled && appLock.hasPin && !appLock.isAppUnlocked {
                        AppLockOverlayView(appLock: appLock)
                            .transition(.opacity)
                            .zIndex(100)
                    }
                }
                .alert(
                    "Pacchetto condiviso importato",
                    isPresented: Binding(
                        get: { importedPackageBanner != nil },
                        set: { if !$0 { importedPackageBanner = nil } }
                    )
                ) {
                    Button("OK", role: .cancel) { importedPackageBanner = nil }
                } message: {
                    Text(importedPackageBanner ?? "")
                }
            }
            .onOpenURL { url in
                if let res = try? SharePackage.importPackage(from: url) {
                    viewModel.reloadAll()
                    let count = res.result.added + res.result.updated
                    importedPackageBanner = "Importato \"\(res.title)\" (\(count) elementi)."
                }
            }
            .onChange(of: scenePhase) { newPhase in
                switch newPhase {
                case .active:
                    viewModel.purgeExpiredTrash()
                case .background:
                    viewModel.lockPrivateItems()
                    appLock.lockIfNeededOnBackground()
                case .inactive:
                    break
                @unknown default:
                    break
                }
            }
        }
    }
}

struct AppLockOverlayView: View {
    @ObservedObject var appLock: AppLockManager
    @Environment(\.paperclipPalette) private var palette
    @State private var pinInput: String = ""
    @State private var errorText: String?

    var body: some View {
        ZStack {
            palette.background.ignoresSafeArea()
            VStack(spacing: 20) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(palette.primary)

                Text("Paperclip è bloccato")
                    .font(.title2.bold())
                    .foregroundStyle(palette.onSurface)

                Text("Inserisci il tuo PIN o usa Face ID per sbloccare l'app.")
                    .font(.subheadline)
                    .foregroundStyle(palette.onSurfaceVariant)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                SecureField("PIN", text: $pinInput)
                    .keyboardType(.numberPad)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)
                    .multilineTextAlignment(.center)

                if let err = errorText {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                HStack(spacing: 14) {
                    Button {
                        if appLock.verifyPin(pinInput) {
                            pinInput = ""
                            errorText = nil
                            appLock.isAppUnlocked = true
                        } else {
                            errorText = "PIN non corretto"
                            pinInput = ""
                        }
                    } label: {
                        Label("Sblocca", systemImage: "lock.open.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(pinInput.count < 4)

                    if appLock.biometricEnabled && appLock.canUseBiometrics() {
                        Button {
                            appLock.authenticateWithBiometrics(reason: "Sblocca Paperclip") { ok in
                                if ok {
                                    appLock.isAppUnlocked = true
                                }
                            }
                        } label: {
                            Label("Face ID", systemImage: "faceid")
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
            .padding(24)
        }
        .onAppear {
            if appLock.biometricEnabled && appLock.canUseBiometrics() {
                appLock.authenticateWithBiometrics(reason: "Sblocca Paperclip") { ok in
                    if ok {
                        appLock.isAppUnlocked = true
                    }
                }
            }
        }
    }
}
