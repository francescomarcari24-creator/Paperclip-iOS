import SwiftUI
import UniformTypeIdentifiers

struct AddEditItemView: View {
    @ObservedObject var viewModel: MainViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.paperclipPalette) private var palette

    let existingEntry: ArchiveItemWithDetails?

    @State private var itemType: ItemType
    @State private var title: String
    @State private var descriptionText: String
    @State private var contentUrl: String
    @State private var audioDurationMs: Int64?
    @State private var selectedFolderId: Int64?
    @State private var selectedTagIds: Set<Int64>
    @State private var checklistItems: [ChecklistItem]
    @State private var newChecklistText: String = ""
    @State private var isPinned: Bool
    @State private var isPrivate: Bool
    @State private var hasReminder: Bool
    @State private var reminderTime: Date
    @State private var newTagName: String = ""
    @State private var showingFileImporter: Bool = false
    @State private var showingCameraCapture: Bool = false
    @State private var showingDocScanner: Bool = false
    @State private var showingDrawingCanvas: Bool = false
    @State private var duplicateLinkAlertItem: ArchiveItem? = nil

    @StateObject private var audioRecorder = AudioRecorderManager()
    @StateObject private var richTextController = RichTextFormattingController()

    init(viewModel: MainViewModel, existingEntry: ArchiveItemWithDetails?, defaultType: ItemType) {
        self.viewModel = viewModel
        self.existingEntry = existingEntry
        let item = existingEntry?.item
        _itemType = State(initialValue: item?.itemType ?? defaultType)
        _title = State(initialValue: item?.title ?? "")
        _descriptionText = State(initialValue: item?.description ?? "")
        _contentUrl = State(initialValue: item?.contentUrl ?? "")
        _audioDurationMs = State(initialValue: item?.audioDurationMs)
        _selectedFolderId = State(initialValue: item?.folderId ?? viewModel.selectedFolderId)
        _selectedTagIds = State(initialValue: Set(existingEntry?.tags.map(\.id) ?? []))
        _checklistItems = State(initialValue: ChecklistItem.fromJson(item?.checklistJson))
        _isPinned = State(initialValue: item?.isPinned ?? false)
        _isPrivate = State(initialValue: item?.isPrivate ?? false)

        if let mins = item?.reminderMinutes {
            _hasReminder = State(initialValue: true)
            var comps = Calendar.current.dateComponents([.year, .month, .day], from: Date())
            comps.hour = mins / 60
            comps.minute = mins % 60
            _reminderTime = State(initialValue: Calendar.current.date(from: comps) ?? Date())
        } else {
            _hasReminder = State(initialValue: false)
            _reminderTime = State(initialValue: Date())
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if itemType != .CHECKLIST {
                    RichTextFormattingBar(controller: richTextController)
                }

                Form {
                    Section("Tipo di elemento") {
                        Picker("Tipo", selection: $itemType) {
                            ForEach(ItemType.allCases) { type in
                                Label(type.label, systemImage: type.systemIcon).tag(type)
                            }
                        }
                        .pickerStyle(.menu)
                    }

                    Section("Contenuto") {
                        TextField("Titolo", text: $title)
                            .font(.headline)

                        if itemType == .LINK {
                            TextField("Indirizzo URL (es. https://…)", text: $contentUrl)
                                .keyboardType(.URL)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        } else if ItemType.mediaTypes.contains(itemType) {
                            mediaCaptureSection
                        }

                        if itemType == .CHECKLIST {
                            checklistEditor
                        } else {
                            ZStack(alignment: .topLeading) {
                                if descriptionText.isEmpty {
                                    Text("Scrivi qui il contenuto della nota…")
                                        .font(.body)
                                        .foregroundStyle(.tertiary)
                                        .padding(.top, 10)
                                        .padding(.leading, 8)
                                        .allowsHitTesting(false)
                                }
                                VisualRichTextEditor(
                                    markdownText: $descriptionText,
                                    controller: richTextController
                                )
                                .frame(minHeight: 160)
                            }
                        }
                    }

                    Section("Organizzazione") {
                        Picker("Cartella", selection: $selectedFolderId) {
                            Text("Nessuna cartella").tag(Int64?.none)
                            ForEach(viewModel.folderTree.entries) { entry in
                                let indent = String(repeating: "— ", count: entry.depth)
                                Text("\(indent)\(entry.folder.name)").tag(Int64?.some(entry.folder.id))
                            }
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Tag")
                                .font(.subheadline.weight(.medium))

                            if !viewModel.tags.isEmpty {
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 8) {
                                        ForEach(viewModel.tags) { tag in
                                            FilterChip(
                                                title: "#\(tag.name)",
                                                icon: nil,
                                                isSelected: selectedTagIds.contains(tag.id)
                                            ) {
                                                if selectedTagIds.contains(tag.id) {
                                                    selectedTagIds.remove(tag.id)
                                                } else {
                                                    selectedTagIds.insert(tag.id)
                                                }
                                            }
                                        }
                                    }
                                }
                            }

                            HStack {
                                TextField("Nuovo tag…", text: $newTagName)
                                Button("Aggiungi") {
                                    let trimmed = newTagName.trimmingCharacters(in: .whitespacesAndNewlines)
                                    guard !trimmed.isEmpty else { return }
                                    if let existing = viewModel.tags.first(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
                                        selectedTagIds.insert(existing.id)
                                    } else {
                                        let newId = PaperclipDatabase.shared.saveTag(Tag(name: trimmed))
                                        viewModel.reloadAll()
                                        selectedTagIds.insert(newId)
                                    }
                                    newTagName = ""
                                }
                                .disabled(newTagName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }
                        }
                    }

                    Section("Opzioni e Sicurezza") {
                        Toggle(isOn: $isPinned) {
                            Label("Fissa in alto nel feed", systemImage: "pin.fill")
                        }

                        Toggle(isOn: $isPrivate) {
                            Label("Elemento privato (Face ID / Codice)", systemImage: "lock.fill")
                        }

                        Toggle(isOn: $hasReminder) {
                            Label("Promemoria", systemImage: "bell.fill")
                        }

                        if hasReminder {
                            DatePicker("Orario promemoria", selection: $reminderTime, displayedComponents: .hourAndMinute)
                        }
                    }
                }
            }
            .navigationTitle(existingEntry == nil ? "Nuovo elemento" : "Modifica elemento")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annulla") {
                        _ = audioRecorder.stopRecording()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Salva") {
                        if audioRecorder.isRecording, let res = audioRecorder.stopRecording() {
                            contentUrl = res.path
                            audioDurationMs = res.durationMs
                        }
                        attemptSave(ignoreDuplicateLink: false)
                    }
                    .bold()
                }
            }
            .fileImporter(
                isPresented: $showingFileImporter,
                allowedContentTypes: [.item, .pdf, .image, .audio, .movie],
                allowsMultipleSelection: false
            ) { result in
                if case .success(let urls) = result, let url = urls.first {
                    if let savedPath = try? FileStorageManager.shared.copyImportedFile(from: url, prefix: itemType.rawValue.lowercased()) {
                        contentUrl = savedPath
                        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            title = url.deletingPathExtension().lastPathComponent
                        }
                    }
                }
            }
            .sheet(isPresented: $showingCameraCapture) {
                CameraCaptureView { photoPath in
                    contentUrl = photoPath
                    if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        title = "Foto"
                    }
                }
            }
            .sheet(isPresented: $showingDocScanner) {
                DocumentScannerView { pdfPath, pages in
                    contentUrl = pdfPath
                    if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        title = "Scansione (\(pages) pag.)"
                    }
                }
            }
            .sheet(isPresented: $showingDrawingCanvas) {
                DrawingCanvasSheet(backgroundImagePath: itemType == .PHOTO && !contentUrl.isEmpty ? contentUrl : nil) { drawingPath in
                    contentUrl = drawingPath
                    if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        title = itemType == .PHOTO ? "Foto annotata" : "Disegno"
                    }
                }
            }
            .alert("Link già salvato", isPresented: Binding(
                get: { duplicateLinkAlertItem != nil },
                set: { if !$0 { duplicateLinkAlertItem = nil } }
            )) {
                Button("Annulla", role: .cancel) {
                    duplicateLinkAlertItem = nil
                }
                Button("Salva comunque") {
                    duplicateLinkAlertItem = nil
                    attemptSave(ignoreDuplicateLink: true)
                }
            } message: {
                if let dup = duplicateLinkAlertItem {
                    Text("Questo indirizzo è già presente nell'archivio come \"\(dup.title)\". Vuoi salvarlo di nuovo?")
                }
            }
        }
    }

    @ViewBuilder
    private var mediaCaptureSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(contentUrl.isEmpty ? "Nessun file selezionato" : (contentUrl as NSString).lastPathComponent)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                Spacer()
                Button("Scegli file…") {
                    showingFileImporter = true
                }
                .buttonStyle(.bordered)
            }

            if itemType == .PHOTO {
                HStack(spacing: 10) {
                    Button {
                        showingCameraCapture = true
                    } label: {
                        Label("Scatta foto", systemImage: "camera.fill")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent)

                    if !contentUrl.isEmpty {
                        Button {
                            showingDrawingCanvas = true
                        } label: {
                            Label("Disegna sopra", systemImage: "pencil.tip.crop.circle")
                                .font(.caption.weight(.semibold))
                        }
                        .buttonStyle(.bordered)
                    }
                }
            } else if itemType == .PDF {
                Button {
                    showingDocScanner = true
                } label: {
                    Label("Scansiona documento con fotocamera", systemImage: "doc.viewfinder")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
            } else if itemType == .DRAWING {
                Button {
                    showingDrawingCanvas = true
                } label: {
                    Label(contentUrl.isEmpty ? "Apri tela di disegno" : "Modifica disegno", systemImage: "scribble.variable")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
            } else if itemType == .AUDIO {
                HStack(spacing: 12) {
                    if audioRecorder.isRecording {
                        Button(role: .destructive) {
                            if let res = audioRecorder.stopRecording() {
                                contentUrl = res.path
                                audioDurationMs = res.durationMs
                                if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    title = "Nota vocale"
                                }
                            }
                        } label: {
                            Label("Ferma (\(formatMs(audioRecorder.elapsedMs)))", systemImage: "stop.circle.fill")
                                .font(.caption.weight(.bold))
                        }
                        .buttonStyle(.borderedProminent)
                    } else {
                        Button {
                            audioRecorder.startRecording()
                        } label: {
                            Label("Registra nota vocale", systemImage: "mic.circle.fill")
                                .font(.caption.weight(.semibold))
                        }
                        .buttonStyle(.borderedProminent)
                    }

                    if let dur = audioDurationMs, !audioRecorder.isRecording {
                        Text("Durata: \(formatMs(dur))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if let err = audioRecorder.errorMessage {
                    Text(err)
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    private func formatMs(_ ms: Int64) -> String {
        let totalSec = Int(ms / 1000)
        return String(format: "%02d:%02d", totalSec / 60, totalSec % 60)
    }

    private var checklistEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach($checklistItems) { $check in
                HStack {
                    Button {
                        check.isChecked.toggle()
                    } label: {
                        Image(systemName: check.isChecked ? "checkmark.square.fill" : "square")
                            .foregroundColor(check.isChecked ? palette.primary : .secondary)
                    }
                    .buttonStyle(.plain)

                    TextField("Voce", text: $check.text)
                        .strikethrough(check.isChecked)

                    Button(role: .destructive) {
                        checklistItems.removeAll { $0.id == check.id }
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .foregroundColor(.red.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack {
                TextField("Aggiungi voce alla checklist…", text: $newChecklistText)
                    .onSubmit {
                        appendChecklistItem()
                    }
                Button {
                    appendChecklistItem()
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.title3)
                }
                .disabled(newChecklistText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func appendChecklistItem() {
        let trimmed = newChecklistText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        checklistItems.append(ChecklistItem(text: trimmed, isChecked: false))
        newChecklistText = ""
    }

    private func attemptSave(ignoreDuplicateLink: Bool) {
        let original = existingEntry?.item
        if itemType == .LINK && !ignoreDuplicateLink {
            if let dup = viewModel.findLinkDuplicate(url: contentUrl, excludeId: original?.id ?? 0) {
                duplicateLinkAlertItem = dup
                return
            }
        }

        let effectiveTitle: String = {
            let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { return t }
            if itemType == .LINK && !contentUrl.isEmpty {
                return LinkUrls.defaultTitleForUrl(contentUrl) ?? contentUrl
            }
            return itemType.label
        }()

        let reminderMins: Int? = {
            guard hasReminder else { return nil }
            let comps = Calendar.current.dateComponents([.hour, .minute], from: reminderTime)
            return (comps.hour ?? 9) * 60 + (comps.minute ?? 0)
        }()

        let now = ArchiveItem.nowMillis()
        let item = ArchiveItem(
            id: original?.id ?? 0,
            title: effectiveTitle,
            description: itemType == .CHECKLIST ? nil : (descriptionText.isEmpty ? nil : descriptionText),
            itemType: itemType,
            contentUrl: contentUrl.isEmpty ? nil : contentUrl,
            previewImageUrl: original?.previewImageUrl,
            folderId: selectedFolderId,
            audioDurationMs: audioDurationMs ?? original?.audioDurationMs,
            checklistJson: itemType == .CHECKLIST ? ChecklistItem.toJson(checklistItems) : nil,
            highlightsJson: original?.highlightsJson,
            reminderMinutes: reminderMins,
            reminderDays: original?.reminderDays ?? 0,
            createdAt: original?.createdAt ?? now,
            updatedAt: now,
            isPinned: isPinned,
            isArchived: original?.isArchived ?? false,
            deletedAt: original?.deletedAt,
            readAt: original?.readAt,
            isPrivate: isPrivate
        )

        viewModel.saveItem(item, tagIds: Array(selectedTagIds))
        dismiss()
    }
}
