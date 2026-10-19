import SwiftUI
import UniformTypeIdentifiers

struct BackupFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.zip, .data] }

    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        self.data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

struct SettingsView: View {
    @ObservedObject var viewModel: MainViewModel
    @ObservedObject private var preferences = UiPreferences.shared
    @ObservedObject private var logger = AppLogger.shared
    @Environment(\.paperclipPalette) private var palette

    // Backup state
    @State private var backupDocument: BackupFileDocument? = nil
    @State private var showingBackupExporter: Bool = false
    @State private var showingBackupImporter: Bool = false
    @State private var pendingImportUrl: URL? = nil
    @State private var showingRestorePasswordPrompt: Bool = false
    @State private var restorePasswordInput: String = ""
    @State private var showingConfigurePasswordSheet: Bool = false
    @State private var newBackupPassword: String = ""
    @State private var hasBackupPassword: Bool = BackupPassword.isSet
    @State private var statusBannerMessage: String? = nil

    var body: some View {
        NavigationStack {
            Form {
                if let msg = statusBannerMessage {
                    Section {
                        HStack {
                            Image(systemName: "info.circle.fill")
                                .foregroundColor(palette.primary)
                            Text(msg)
                                .font(.subheadline)
                            Spacer()
                            Button("OK") {
                                statusBannerMessage = nil
                            }
                            .font(.caption.bold())
                        }
                    }
                }

                // Aspetto e Tema
                Section("Aspetto e Tema") {
                    Picker("Modalità tema", selection: $preferences.themeMode) {
                        ForEach(ThemeMode.allCases) { mode in
                            Label(mode.label, systemImage: mode.systemIcon).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

                    Picker("Colore dell'app", selection: $preferences.accentColor) {
                        ForEach(AccentColor.allCases) { accent in
                            HStack {
                                if let hex = accent.seedHex {
                                    Circle()
                                        .fill(Color(hex: hex))
                                        .frame(width: 14, height: 14)
                                }
                                Text(accent.label)
                            }
                            .tag(accent)
                        }
                    }
                }

                // Backup e Compatibilità Android (.zip / PCLIPENC)
                Section {
                    Toggle("Proteggi i backup con password (PCLIPENC)", isOn: Binding(
                        get: { hasBackupPassword },
                        set: { enabled in
                            if enabled {
                                newBackupPassword = ""
                                showingConfigurePasswordSheet = true
                            } else {
                                BackupPassword.set(nil)
                                hasBackupPassword = false
                                statusBannerMessage = "Password di backup rimossa."
                            }
                        }
                    ))

                    Button {
                        exportBackupNow()
                    } label: {
                        Label("Esporta backup (.zip / PCLIPENC)", systemImage: "square.and.arrow.up")
                    }

                    Button {
                        showingBackupImporter = true
                    } label: {
                        Label("Ripristina backup da Android o iOS", systemImage: "square.and.arrow.down")
                    }
                } header: {
                    Text("Backup e Sincronizzazione Dati")
                } footer: {
                    Text("I backup creati su Android (anche cifrati con PCLIPENC) sono compatibili al 100% con iOS e viceversa.")
                }

                // Riscopri
                Section("Riscopri nel Feed") {
                    Toggle("Mostra 'Riscopri' in cima al feed", isOn: $preferences.resurfaceEnabled)
                    if preferences.resurfaceEnabled {
                        Stepper("Elementi al giorno: \(preferences.resurfaceCount)", value: $preferences.resurfaceCount, in: 1...6)
                        Stepper("Età minima: \(preferences.resurfaceMinDays) giorni", value: $preferences.resurfaceMinDays, in: 7...365, step: 7)
                    }
                }

                // Sicurezza / Elementi privati
                Section("Sicurezza") {
                    HStack {
                        Label(
                            viewModel.privateUnlocked ? "Elementi privati sbloccati" : "Elementi privati bloccati",
                            systemImage: viewModel.privateUnlocked ? "lock.open.fill" : "lock.fill"
                        )
                        Spacer()
                        Button(viewModel.privateUnlocked ? "Blocca" : "Sblocca") {
                            if viewModel.privateUnlocked {
                                viewModel.lockPrivateItems()
                            } else {
                                viewModel.unlockPrivateItems()
                            }
                        }
                    }
                }

                // Console di Debug e Diagnostica in-app (utile da Windows senza Xcode)
                Section {
                    NavigationLink {
                        DiagnosticsLogView(logger: logger)
                    } label: {
                        HStack {
                            Label("Console Diagnostica e Log", systemImage: "terminal.fill")
                            Spacer()
                            Text("\(logger.entries.count)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                } header: {
                    Text("Sviluppo e Diagnostica")
                } footer: {
                    Text("Commit Android di riferimento: 99d8319 • Database SQLite compatibile Room v6")
                }
            }
            .navigationTitle("Impostazioni")
            .fileExporter(
                isPresented: $showingBackupExporter,
                document: backupDocument,
                contentType: .zip,
                defaultFilename: "paperclip_backup_\(Self.timestampString()).zip"
            ) { result in
                switch result {
                case .success:
                    statusBannerMessage = "Backup esportato con successo."
                case .failure(let err):
                    statusBannerMessage = "Errore esportazione: \(err.localizedDescription)"
                }
            }
            .fileImporter(
                isPresented: $showingBackupImporter,
                allowedContentTypes: [.zip, .data, .item],
                allowsMultipleSelection: false
            ) { result in
                if case .success(let urls) = result, let url = urls.first {
                    handleImport(url: url, password: nil)
                }
            }
            .alert("Backup protetto da password", isPresented: $showingRestorePasswordPrompt) {
                SecureField("Password del backup", text: $restorePasswordInput)
                Button("Annulla", role: .cancel) {
                    pendingImportUrl = nil
                    restorePasswordInput = ""
                }
                Button("Decrittografa e Ripristina") {
                    if let url = pendingImportUrl {
                        handleImport(url: url, password: restorePasswordInput)
                    }
                }
            } message: {
                Text("Inserisci la password con cui è stato cifrato questo backup (formato PCLIPENC).")
            }
            .sheet(isPresented: $showingConfigurePasswordSheet) {
                NavigationStack {
                    Form {
                        Section("Imposta password per i backup") {
                            SecureField("Password", text: $newBackupPassword)
                        }
                        Section {
                            Text("La password viene salvata nel Keychain di iOS e usata per cifrare i backup in formato PCLIPENC compatibile con Android.")
                                .font(.footnote)
                                .foregroundColor(.secondary)
                        }
                    }
                    .navigationTitle("Password di backup")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Annulla") {
                                hasBackupPassword = BackupPassword.isSet
                                showingConfigurePasswordSheet = false
                            }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Salva") {
                                BackupPassword.set(newBackupPassword)
                                hasBackupPassword = BackupPassword.isSet
                                showingConfigurePasswordSheet = false
                                statusBannerMessage = "Password di backup salvata nel Keychain."
                            }
                            .disabled(newBackupPassword.isEmpty)
                        }
                    }
                }
            }
        }
    }

    private func exportBackupNow() {
        do {
            let data = try BackupManager.shared.createBackupData()
            backupDocument = BackupFileDocument(data: data)
            showingBackupExporter = true
        } catch {
            statusBannerMessage = "Errore creazione backup: \(error.localizedDescription)"
        }
    }

    private func handleImport(url: URL, password: String?) {
        let outcome = BackupManager.shared.importBackup(from: url, password: password)
        switch outcome {
        case .success(let itemsCount, let foldersCount, let tagsCount):
            viewModel.reloadAll()
            pendingImportUrl = nil
            restorePasswordInput = ""
            statusBannerMessage = "Ripristinati \(itemsCount) elementi, \(foldersCount) cartelle e \(tagsCount) tag."
        case .passwordNeeded:
            pendingImportUrl = url
            restorePasswordInput = ""
            showingRestorePasswordPrompt = true
        case .wrongPassword:
            pendingImportUrl = url
            restorePasswordInput = ""
            statusBannerMessage = "Password errata per il backup selezionato."
            showingRestorePasswordPrompt = true
        case .failed(let reason):
            statusBannerMessage = "Ripristino non riuscito: \(reason)"
        }
    }

    private static func timestampString() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd_HHmmss"
        return fmt.string(from: Date())
    }
}

struct DiagnosticsLogView: View {
    @ObservedObject var logger: AppLogger

    var body: some View {
        List {
            if logger.entries.isEmpty {
                Text("Nessun evento registrato.")
                    .foregroundColor(.secondary)
            } else {
                ForEach(logger.entries) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(entry.category)
                                .font(.caption.bold())
                                .foregroundColor(entry.isError ? .red : .accentColor)
                            Spacer()
                            Text(entry.timestamp, style: .time)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        Text(entry.message)
                            .font(.footnote.monospaced())
                            .foregroundColor(entry.isError ? .red : .primary)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .navigationTitle("Log Diagnostica")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack {
                    Button {
                        UIPasteboard.general.string = logger.exportText()
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    Button(role: .destructive) {
                        logger.clear()
                    } label: {
                        Image(systemName: "trash")
                    }
                }
            }
        }
    }
}
