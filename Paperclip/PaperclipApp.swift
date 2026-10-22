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
            .onAppear {
                // Con un dispositivo associato il P2P parte subito: serve alla sincronizzazione automatica
                P2PSyncManager.shared.onArchiveUpdated = { viewModel.reloadAll() }
                P2PSyncManager.shared.startIfPaired()
            }
            .onChange(of: scenePhase) { newPhase in
                switch newPhase {
                case .active:
                    viewModel.purgeExpiredTrash()
                    P2PSyncManager.shared.resumeAfterBackground()
                case .background:
                    viewModel.lockPrivateItems()
                    appLock.lockIfNeededOnBackground()
                    P2PSyncManager.shared.pauseForBackground()
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
    @Environment(\.scenePhase) private var scenePhase
    @State private var pinInput: String = ""
    @State private var errorText: String?
    @State private var didAutoAttempt: Bool = false
    @State private var showPin: Bool = true

    private var biometricsAvailable: Bool {
        appLock.biometricEnabled && appLock.canUseBiometrics()
    }

    /// Avvia Face ID una sola volta per blocco; il PIN compare solo se non riesce.
    private func attemptBiometricUnlock() {
        guard biometricsAvailable, !didAutoAttempt, !appLock.isAppUnlocked else { return }
        didAutoAttempt = true
        // Piccolo ritardo: con la scena appena attiva il sistema può annullare subito la richiesta.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            guard !appLock.isAppUnlocked else { return }
            appLock.authenticateWithBiometrics(reason: "Sblocca Paperclip") { ok in
                if ok {
                    appLock.isAppUnlocked = true
                } else {
                    showPin = true
                }
            }
        }
    }

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

                Text(showPin ? "Inserisci il tuo PIN o usa Face ID per sbloccare l'app." : "Sblocco con Face ID in corso…")
                    .font(.subheadline)
                    .foregroundStyle(palette.onSurfaceVariant)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                if showPin {
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
                }

                HStack(spacing: 14) {
                    if showPin {
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
                    }

                    if biometricsAvailable {
                        Button {
                            appLock.authenticateWithBiometrics(reason: "Sblocca Paperclip") { ok in
                                if ok {
                                    appLock.isAppUnlocked = true
                                } else {
                                    showPin = true
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
            showPin = !biometricsAvailable
            if scenePhase == .active {
                attemptBiometricUnlock()
            }
        }
        .onChange(of: scenePhase) { newPhase in
            switch newPhase {
            case .active:
                attemptBiometricUnlock()
            case .background:
                // Al prossimo ritorno in primo piano si riprova con Face ID prima del PIN.
                didAutoAttempt = false
                showPin = !biometricsAvailable
            default:
                break
            }
        }
    }
}
