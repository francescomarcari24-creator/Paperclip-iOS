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
    var onOpenHighlights: () -> Void = {}
    @ObservedObject private var preferences = UiPreferences.shared
    @ObservedObject private var logger = AppLogger.shared
    @ObservedObject private var appLock = AppLockManager.shared
    @ObservedObject private var trustedDevices = TrustedDevices.shared

    @State private var showingP2PSync: Bool = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink {
                        AppearanceSettingsView()
                    } label: {
                        SettingsRowLabel(title: "Aspetto", systemImage: "paintpalette.fill", color: .indigo, value: preferences.themeMode.label)
                    }

                    NavigationLink {
                        SecuritySettingsView(viewModel: viewModel)
                    } label: {
                        SettingsRowLabel(title: "Sicurezza e privacy", systemImage: "lock.fill", color: .blue, value: appLock.hasPin ? "PIN attivo" : nil)
                    }
                }

                Section {
                    NavigationLink {
                        ContentSettingsView(viewModel: viewModel, onOpenHighlights: onOpenHighlights)
                    } label: {
                        SettingsRowLabel(title: "Feed e contenuti", systemImage: "square.stack.fill", color: .orange)
                    }

                    NavigationLink {
                        AutomationSettingsView(viewModel: viewModel)
                    } label: {
                        SettingsRowLabel(title: "Automazioni", systemImage: "wand.and.stars", color: .purple)
                    }
                }

                Section {
                    Button {
                        showingP2PSync = true
                    } label: {
                        HStack {
                            SettingsRowLabel(
                                title: "Sincronizzazione Wi-Fi",
                                systemImage: "antenna.radiowaves.left.and.right",
                                color: .green,
                                value: trustedDevices.devices.isEmpty ? nil : "\(trustedDevices.devices.count) associati"
                            )
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .foregroundStyle(.primary)

                    NavigationLink {
                        BackupSettingsView(viewModel: viewModel)
                    } label: {
                        SettingsRowLabel(title: "Backup e ripristino", systemImage: "externaldrive.fill", color: .teal)
                    }

                    NavigationLink {
                        ImportExportSettingsView(viewModel: viewModel)
                    } label: {
                        SettingsRowLabel(title: "Importa ed esporta", systemImage: "arrow.up.arrow.down", color: .pink)
                    }
                }

                Section {
                    NavigationLink {
                        DiagnosticsLogView(logger: logger)
                    } label: {
                        SettingsRowLabel(title: "Diagnostica", systemImage: "terminal.fill", color: .gray, value: "\(logger.entries.count)")
                    }
                } footer: {
                    Text("Commit Android di riferimento: 99d8319 • Database SQLite compatibile Room v6")
                }
            }
            .navigationTitle("Impostazioni")
            .sheet(isPresented: $showingP2PSync) {
                P2PSyncView()
                    .environmentObject(viewModel)
            }
        }
    }
}

// MARK: - Componenti comuni

/// Riga della schermata principale delle impostazioni: icona su quadrato colorato, titolo e valore attuale.
private struct SettingsRowLabel: View {
    let title: String
    let systemImage: String
    let color: Color
    var value: String? = nil

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 29, height: 29)
                .background(color, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            Text(title)
                .lineLimit(1)
            Spacer(minLength: 8)
            if let value {
                Text(value)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
    }
}

/// Messaggio di esito mostrato in cima a una schermata delle impostazioni.
private struct SettingsStatusBanner: View {
    @Binding var message: String?
    @Environment(\.paperclipPalette) private var palette

    var body: some View {
        if let message {
            Section {
                HStack {
                    Image(systemName: "info.circle.fill")
                        .foregroundColor(palette.primary)
                    Text(message)
                        .font(.subheadline)
                    Spacer()
                    Button("OK") {
                        self.message = nil
                    }
                    .font(.caption.bold())
                }
            }
        }
    }
}

// MARK: - Aspetto

private struct AppearanceSettingsView: View {
    @ObservedObject private var preferences = UiPreferences.shared

    var body: some View {
        Form {
            Section("Tema") {
                Picker("Modalità tema", selection: $preferences.themeMode) {
                    ForEach(ThemeMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section("Colore dell'app") {
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
                .pickerStyle(.inline)
                .labelsHidden()
            }
        }
        .navigationTitle("Aspetto")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Sicurezza e privacy

private struct SecuritySettingsView: View {
    @ObservedObject var viewModel: MainViewModel
    @ObservedObject private var appLock = AppLockManager.shared

    @State private var showingSetPinSheet: Bool = false
    @State private var newPinInput: String = ""
    @State private var statusBannerMessage: String? = nil

    var body: some View {
        Form {
            SettingsStatusBanner(message: $statusBannerMessage)

            Section("Elementi privati") {
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
                    .fixedSize(horizontal: true, vertical: false)
                }
            }

            Section("PIN e blocco dell'app") {
                if appLock.hasPin {
                    Toggle("Blocca l'intera app con PIN", isOn: Binding(
                        get: { appLock.appLockEnabled },
                        set: { appLock.setAppLockEnabled($0) }
                    ))

                    if appLock.canUseBiometrics() {
                        Toggle("Sblocco rapido con Face ID / Touch ID", isOn: Binding(
                            get: { appLock.biometricEnabled },
                            set: { appLock.setBiometricEnabled($0) }
                        ))
                    }

                    Button("Cambia PIN di sicurezza") {
                        newPinInput = ""
                        showingSetPinSheet = true
                    }

                    Button("Rimuovi PIN di sicurezza", role: .destructive) {
                        appLock.removePin()
                        statusBannerMessage = "PIN di sicurezza rimosso."
                    }
                } else {
                    Button {
                        newPinInput = ""
                        showingSetPinSheet = true
                    } label: {
                        Label("Imposta PIN di sicurezza (4-8 cifre)", systemImage: "key.fill")
                    }
                }
            }
        }
        .navigationTitle("Sicurezza e privacy")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingSetPinSheet) {
            NavigationStack {
                Form {
                    Section("Nuovo PIN numerico (4-8 cifre)") {
                        SecureField("Inserisci PIN", text: $newPinInput)
                            .keyboardType(.numberPad)
                    }
                }
                .navigationTitle("Imposta PIN")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Annulla") { showingSetPinSheet = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Salva") {
                            appLock.setPin(newPinInput)
                            showingSetPinSheet = false
                            statusBannerMessage = "PIN di sicurezza configurato."
                        }
                        .disabled(newPinInput.count < 4 || newPinInput.count > 8)
                    }
                }
            }
            .presentationDetents([.medium])
        }
    }
}

// MARK: - Feed e contenuti

private struct ContentSettingsView: View {
    @ObservedObject var viewModel: MainViewModel
    var onOpenHighlights: () -> Void
    @ObservedObject private var preferences = UiPreferences.shared

    @State private var showingTrash: Bool = false

    var body: some View {
        Form {
            Section {
                Toggle("Mostra 'Riscopri' in cima al feed", isOn: $preferences.resurfaceEnabled)
                if preferences.resurfaceEnabled {
                    Stepper("Elementi al giorno: \(preferences.resurfaceCount)", value: $preferences.resurfaceCount, in: 1...6)
                    Stepper("Età minima: \(preferences.resurfaceMinDays) giorni", value: $preferences.resurfaceMinDays, in: 7...365, step: 7)
                }
            } header: {
                Text("Riscopri")
            } footer: {
                Text("Ripropone ogni giorno alcuni elementi salvati da tempo.")
            }

            Section("Fonti") {
                NavigationLink {
                    RssFeedsManagementView(viewModel: viewModel)
                } label: {
                    Label("Feed RSS e Atom (\(RssFeeds.list().count))", systemImage: "dot.radiowaves.up.forward")
                }
            }

            Section("Archivio") {
                Button {
                    onOpenHighlights()
                } label: {
                    Label("Evidenziazioni", systemImage: "highlighter")
                }

                Button {
                    showingTrash = true
                } label: {
                    Label("Cestino", systemImage: "trash")
                }
            }
        }
        .navigationTitle("Feed e contenuti")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingTrash) {
            TrashView(viewModel: viewModel)
        }
    }
}

// MARK: - Automazioni

private struct AutomationSettingsView: View {
    @ObservedObject var viewModel: MainViewModel

    @State private var isCheckingLinks: Bool = false
    @State private var linkCheckProgress: String = ""
    @State private var statusBannerMessage: String? = nil

    var body: some View {
        Form {
            SettingsStatusBanner(message: $statusBannerMessage)

            Section {
                NavigationLink {
                    AutoRulesManagementView(viewModel: viewModel)
                } label: {
                    Label("Regole Automatiche (\(AutoRules.list().count))", systemImage: "wand.and.stars")
                }
            } footer: {
                Text("Spostano in una cartella o aggiungono tag agli elementi che soddisfano una condizione.")
            }

            Section {
                Button {
                    guard !isCheckingLinks else { return }
                    isCheckingLinks = true
                    linkCheckProgress = "Avvio controllo…"
                    Task {
                        let (summary, _) = await LinkChecker.checkAllLinks { done, total in
                            Task { @MainActor in
                                linkCheckProgress = "\(done)/\(total)"
                            }
                        }
                        await MainActor.run {
                            isCheckingLinks = false
                            viewModel.reloadAll()
                            statusBannerMessage = "Controllati \(summary.checked) link: \(summary.broken) interrotti, \(summary.unreachable) non raggiungibili."
                        }
                    }
                } label: {
                    HStack {
                        Label("Verifica Link Interrotti (404 / Offline)", systemImage: "link.badge.plus")
                        Spacer()
                        if isCheckingLinks {
                            Text(linkCheckProgress)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                            ProgressView()
                        }
                    }
                }
                .disabled(isCheckingLinks)
            } footer: {
                Text("Controlla se i link salvati rispondono ancora e segnala quelli interrotti.")
            }
        }
        .navigationTitle("Automazioni")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Backup e ripristino

private struct BackupSettingsView: View {
    @ObservedObject var viewModel: MainViewModel

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
        Form {
            SettingsStatusBanner(message: $statusBannerMessage)

            Section {
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
            } footer: {
                Text("I backup creati su Android (anche cifrati con PCLIPENC) sono compatibili con iOS e viceversa.")
            }

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
            } footer: {
                Text("La password viene salvata nel Keychain e usata per cifrare i backup.")
            }
        }
        .navigationTitle("Backup e ripristino")
        .navigationBarTitleDisplayMode(.inline)
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
            viewModel.indexPendingItemsInBackground()
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

// MARK: - Importa ed esporta

private struct ImportExportSettingsView: View {
    @ObservedObject var viewModel: MainViewModel

    @State private var showingExternalImporter: Bool = false
    @State private var exportedShareUrl: URL? = nil
    @State private var exportedShareLabel: String = ""
    @State private var statusBannerMessage: String? = nil

    var body: some View {
        Form {
            SettingsStatusBanner(message: $statusBannerMessage)

            if let shareUrl = exportedShareUrl {
                Section("File pronto per la condivisione") {
                    ShareLink(item: shareUrl) {
                        Label("Condividi / Salva \(exportedShareLabel)", systemImage: "square.and.arrow.up.fill")
                            .font(.subheadline.bold())
                    }
                }
            }

            Section {
                Button {
                    showingExternalImporter = true
                } label: {
                    Label("Importa da Google Keep / Pocket / Browser…", systemImage: "tray.and.arrow.down.fill")
                }
            } header: {
                Text("Importa")
            } footer: {
                Text("Supporta Google Keep Takeout (.zip/.json), Pocket (.csv) e Segnalibri di Chrome/Safari/Firefox (.html).")
            }

            Section("Esporta") {
                Button {
                    do {
                        let res = try ArchiveExporter.writeMarkdownZip()
                        exportedShareUrl = res.fileUrl
                        exportedShareLabel = "Markdown/Obsidian (\(res.count) note)"
                        statusBannerMessage = "Archivio Markdown generato (\(res.count) elementi). Tocca 'Condividi / Salva' in alto."
                    } catch {
                        statusBannerMessage = "Errore esportazione Markdown: \(error.localizedDescription)"
                    }
                } label: {
                    Label("Esporta Markdown / Obsidian (.zip)", systemImage: "doc.zipper")
                }

                Button {
                    do {
                        let res = try ArchiveExporter.writeBookmarksHtml()
                        exportedShareUrl = res.fileUrl
                        exportedShareLabel = "Segnalibri (\(res.count) link)"
                        statusBannerMessage = "File Segnalibri HTML generato (\(res.count) link). Tocca 'Condividi / Salva' in alto."
                    } catch {
                        statusBannerMessage = "Errore esportazione Segnalibri: \(error.localizedDescription)"
                    }
                } label: {
                    Label("Esporta Segnalibri Browser (.html)", systemImage: "bookmark.fill")
                }

                Button {
                    do {
                        let res = try ArchiveExporter.writeReadwiseCsv()
                        exportedShareUrl = res.fileUrl
                        exportedShareLabel = "Evidenziazioni CSV (\(res.count))"
                        statusBannerMessage = "File Readwise CSV generato (\(res.count) evidenziazioni). Tocca 'Condividi / Salva' in alto."
                    } catch {
                        statusBannerMessage = "Errore esportazione CSV: \(error.localizedDescription)"
                    }
                } label: {
                    Label("Esporta Evidenziazioni Readwise (.csv)", systemImage: "highlighter")
                }
            }
        }
        .navigationTitle("Importa ed esporta")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(
            isPresented: $showingExternalImporter,
            allowedContentTypes: [.zip, .json, .commaSeparatedText, .html, .text, .item],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                do {
                    let res = try ExternalImporter.importFromUrl(url)
                    viewModel.reloadAll()
                    viewModel.indexPendingItemsInBackground()
                    statusBannerMessage = "Importati \(res.imported) elementi (\(res.skipped) ignorati o duplicati)."
                } catch {
                    statusBannerMessage = "Errore importazione: \(error.localizedDescription)"
                }
            }
        }
    }
}

// MARK: - AutoRulesManagementView

struct AutoRulesManagementView: View {
    @ObservedObject var viewModel: MainViewModel
    @State private var rules: [AutoRules.AutoRule] = AutoRules.list()
    @State private var showingAddRule = false
    @State private var conditionKind: AutoRules.ConditionKind = .LINK_CONTAINS
    @State private var conditionValue: String = ""
    @State private var selectedItemType: ItemType = .LINK
    @State private var actionKind: AutoRules.ActionKind = .MOVE_TO_FOLDER
    @State private var targetId: Int64 = 0
    @State private var bannerMessage: String?

    var body: some View {
        List {
            if let msg = bannerMessage {
                Section {
                    Text(msg)
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }

            Section {
                Button {
                    let touched = AutoRules.applyToAll()
                    viewModel.reloadAll()
                    bannerMessage = "Regole applicate a \(touched) elementi esistenti."
                } label: {
                    Label("Applica ora a tutto l'archivio", systemImage: "play.fill")
                }
                .disabled(rules.isEmpty)
            }

            Section("Regole attive (\(rules.count))") {
                if rules.isEmpty {
                    Text("Nessuna regola configurata. Tocca + in alto a destra per crearne una.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(rules) { rule in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(rule.conditionKind.label): \"\(rule.conditionValue)\"")
                                    .font(.subheadline.weight(.semibold))
                                Text("\(rule.actionKind.label) → \(targetLabel(for: rule))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Toggle("", isOn: Binding(
                                get: { rule.enabled },
                                set: { on in
                                    if let idx = rules.firstIndex(where: { $0.id == rule.id }) {
                                        rules[idx].enabled = on
                                        AutoRules.save(rules)
                                    }
                                }
                            ))
                            .labelsHidden()
                        }
                        .swipeActions {
                            Button(role: .destructive) {
                                rules.removeAll { $0.id == rule.id }
                                AutoRules.save(rules)
                            } label: {
                                Label("Elimina", systemImage: "trash")
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Regole Automatiche")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    conditionValue = ""
                    targetId = viewModel.folders.first?.id ?? viewModel.tags.first?.id ?? 0
                    showingAddRule = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showingAddRule) {
            NavigationStack {
                Form {
                    Section("Se l'elemento soddisfa questa condizione") {
                        Picker("Condizione", selection: $conditionKind) {
                            ForEach(AutoRules.ConditionKind.allCases) { k in
                                Text(k.label).tag(k)
                            }
                        }

                        if conditionKind == .TYPE_IS {
                            Picker("Tipo", selection: $selectedItemType) {
                                ForEach(ItemType.allCases) { t in
                                    Text(t.label).tag(t)
                                }
                            }
                        } else {
                            TextField(conditionKind == .LINK_CONTAINS ? "Es. youtube.com, github.com…" : "Parola chiave…", text: $conditionValue)
                                .textInputAutocapitalization(.never)
                        }
                    }

                    Section("Allora esegui questa azione") {
                        Picker("Azione", selection: $actionKind) {
                            ForEach(AutoRules.ActionKind.allCases) { a in
                                Text(a.label).tag(a)
                            }
                        }

                        if actionKind == .MOVE_TO_FOLDER {
                            Picker("Cartella", selection: $targetId) {
                                ForEach(viewModel.folders) { f in
                                    Text(f.name).tag(f.id)
                                }
                            }
                        } else {
                            Picker("Tag", selection: $targetId) {
                                ForEach(viewModel.tags) { t in
                                    Text("#\(t.name)").tag(t.id)
                                }
                            }
                        }
                    }
                }
                .navigationTitle("Nuova Regola")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Annulla") { showingAddRule = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Salva") {
                            let val = conditionKind == .TYPE_IS ? selectedItemType.rawValue : conditionValue.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !val.isEmpty, targetId != 0 else { return }
                            let rule = AutoRules.AutoRule(
                                conditionKind: conditionKind,
                                conditionValue: val,
                                actionKind: actionKind,
                                targetId: targetId,
                                enabled: true
                            )
                            rules.append(rule)
                            AutoRules.save(rules)
                            showingAddRule = false
                        }
                    }
                }
            }
            .presentationDetents([.medium])
        }
    }

    private func targetLabel(for rule: AutoRules.AutoRule) -> String {
        switch rule.actionKind {
        case .MOVE_TO_FOLDER:
            return viewModel.folders.first(where: { $0.id == rule.targetId })?.name ?? "Cartella #\(rule.targetId)"
        case .ADD_TAG:
            if let t = viewModel.tags.first(where: { $0.id == rule.targetId }) {
                return "#\(t.name)"
            }
            return "Tag #\(rule.targetId)"
        }
    }
}

// MARK: - RssFeedsManagementView

struct RssFeedsManagementView: View {
    @ObservedObject var viewModel: MainViewModel
    @State private var feeds: [RssFeeds.RssFeed] = RssFeeds.list()
    @State private var showingAddFeed = false
    @State private var feedUrlInput = ""
    @State private var selectedFolderId: Int64?
    @State private var selectedTagId: Int64?
    @State private var isRefreshing = false
    @State private var statusMessage: String?

    var body: some View {
        List {
            if let msg = statusMessage {
                Section {
                    Text(msg)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Button {
                    guard !isRefreshing else { return }
                    isRefreshing = true
                    Task {
                        let res = await RssFeeds.refreshAll()
                        await MainActor.run {
                            feeds = RssFeeds.list()
                            viewModel.reloadAll()
                            viewModel.indexPendingItemsInBackground()
                            isRefreshing = false
                            statusMessage = "Controllati \(res.feedsChecked) feed: \(res.newItems) nuovi articoli salvati."
                        }
                    }
                } label: {
                    HStack {
                        Label("Aggiorna tutti i feed ora", systemImage: "arrow.clockwise")
                        Spacer()
                        if isRefreshing { ProgressView() }
                    }
                }
                .disabled(feeds.isEmpty || isRefreshing)
            }

            Section("Feed sottoscritti (\(feeds.count))") {
                if feeds.isEmpty {
                    Text("Nessun feed RSS o Atom sottoscritto. Tocca + per aggiungere un sito o l'URL di un feed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(feeds) { feed in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(feed.title)
                                .font(.subheadline.weight(.semibold))
                            Text(feed.url)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .swipeActions {
                            Button(role: .destructive) {
                                RssFeeds.remove(id: feed.id)
                                feeds = RssFeeds.list()
                            } label: {
                                Label("Rimuovi", systemImage: "trash")
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Feed RSS e Atom")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    feedUrlInput = ""
                    selectedFolderId = nil
                    selectedTagId = nil
                    showingAddFeed = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showingAddFeed) {
            NavigationStack {
                Form {
                    Section("Indirizzo del feed o del sito web") {
                        TextField("https://esempio.it/feed.xml", text: $feedUrlInput)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    Section("Destinazione (opzionale)") {
                        Picker("Cartella", selection: $selectedFolderId) {
                            Text("Nessuna cartella").tag(Int64?.none)
                            ForEach(viewModel.folders) { f in
                                Text(f.name).tag(Int64?.some(f.id))
                            }
                        }
                        Picker("Tag", selection: $selectedTagId) {
                            Text("Nessun tag").tag(Int64?.none)
                            ForEach(viewModel.tags) { t in
                                Text("#\(t.name)").tag(Int64?.some(t.id))
                            }
                        }
                    }
                }
                .navigationTitle("Aggiungi Feed RSS")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Annulla") { showingAddFeed = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Iscriviti") {
                            let url = feedUrlInput.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !url.isEmpty else { return }
                            isRefreshing = true
                            showingAddFeed = false
                            Task {
                                do {
                                    let (feed, added) = try await RssFeeds.subscribe(
                                        rawUrl: url,
                                        folderId: selectedFolderId,
                                        tagId: selectedTagId
                                    )
                                    await MainActor.run {
                                        feeds = RssFeeds.list()
                                        viewModel.reloadAll()
                                        viewModel.indexPendingItemsInBackground()
                                        isRefreshing = false
                                        statusMessage = "Iscritto a \"\(feed.title)\" (\(added) articoli importati)."
                                    }
                                } catch {
                                    await MainActor.run {
                                        isRefreshing = false
                                        statusMessage = "Errore feed: \(error.localizedDescription)"
                                    }
                                }
                            }
                        }
                        .disabled(feedUrlInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .presentationDetents([.medium])
        }
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
