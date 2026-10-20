import SwiftUI
import PDFKit

struct ItemDetailView: View {
    @ObservedObject var viewModel: MainViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.paperclipPalette) private var palette
    @Environment(\.openURL) private var openURL

    let entry: ArchiveItemWithDetails
    let onEdit: () -> Void

    @StateObject private var audioPlayer = AudioPlayerManager()
    @StateObject private var readAloud = ReadAloudManager()
    @State private var showingReaderMode: Bool = false
    @State private var showingDrawingCanvas: Bool = false
    @State private var isIndexing: Bool = false
    @State private var sharePackageUrl: URL? = nil
    @State private var shareHtmlUrl: URL? = nil

    private var item: ArchiveItem { entry.item }
    private var isLockedPrivate: Bool { item.isPrivate && !viewModel.privateUnlocked }
    private var itemContent: ItemContent? { viewModel.itemContentsById[item.id] }
    private var extractedArticle: ExtractedArticle? { ExtractedArticle.fromJson(itemContent?.articleJson) }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                palette.background.ignoresSafeArea()

                if isLockedPrivate {
                    VStack(spacing: 16) {
                        Image(systemName: "lock.shield.fill")
                            .font(.system(size: 56))
                            .foregroundColor(palette.primary)
                        Text("Elemento protetto")
                            .font(.title3.bold())
                        Text("Autenticati con Face ID o il codice del dispositivo per visualizzare questo elemento.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                        Button("Sblocca ora") {
                            viewModel.unlockPrivateItems()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            // Header metadata
                            HStack(spacing: 8) {
                                Label(item.itemType.label, systemImage: item.itemType.systemIcon)
                                    .font(.caption.weight(.semibold))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(palette.primaryContainer)
                                    .foregroundColor(palette.onPrimaryContainer)
                                    .clipShape(Capsule())

                                if let folder = entry.folder {
                                    Label(viewModel.folderTree.pathLabel(folder.id), systemImage: "folder.fill")
                                        .font(.caption)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 5)
                                        .background(palette.surfaceContainer)
                                        .clipShape(Capsule())
                                }

                                Spacer()
                            }

                            Text(item.title)
                                .font(.title2.bold())
                                .foregroundColor(palette.onSurface)

                            if !entry.tags.isEmpty {
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 8) {
                                        ForEach(entry.tags) { tag in
                                            Text("#\(tag.name)")
                                                .font(.caption.weight(.medium))
                                                .padding(.horizontal, 10)
                                                .padding(.vertical, 5)
                                                .background(Color(hexString: tag.colorHex).opacity(0.22))
                                                .clipShape(Capsule())
                                        }
                                    }
                                }
                            }

                            Divider()

                            // Broken link warning banner
                            if let broken = viewModel.brokenLinksMap[item.id],
                               let rawUrl = item.contentUrl {
                                VStack(alignment: .leading, spacing: 8) {
                                    Label(
                                        broken.status == .BROKEN ? "Link non funzionante (HTTP \(broken.code))" : "Dominio non raggiungibile",
                                        systemImage: "exclamationmark.triangle.fill"
                                    )
                                    .font(.subheadline.bold())
                                    .foregroundStyle(.red)

                                    Button {
                                        if let wb = URL(string: LinkChecker.waybackUrl(for: rawUrl)) {
                                            openURL(wb)
                                        }
                                    } label: {
                                        Label("Cerca su Wayback Machine (Internet Archive)", systemImage: "clock.arrow.circlepath")
                                            .font(.caption.weight(.semibold))
                                    }
                                    .buttonStyle(.bordered)
                                }
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                            }

                            // Link section
                            if item.itemType == .LINK, let rawUrl = item.contentUrl, !rawUrl.isEmpty {
                                VStack(alignment: .leading, spacing: 10) {
                                    Text(rawUrl)
                                        .font(.footnote)
                                        .foregroundColor(palette.primary)
                                        .textSelection(.enabled)

                                    ScrollView(.horizontal, showsIndicators: false) {
                                        HStack(spacing: 10) {
                                            Button {
                                                let withScheme = rawUrl.contains("://") ? rawUrl : "https://\(rawUrl)"
                                                if let url = URL(string: withScheme) {
                                                    viewModel.markOpened(item)
                                                    openURL(url)
                                                }
                                            } label: {
                                                Label("Apri nel browser", systemImage: "safari.fill")
                                            }
                                            .buttonStyle(.borderedProminent)

                                            Button {
                                                if extractedArticle != nil {
                                                    showingReaderMode = true
                                                } else {
                                                    isIndexing = true
                                                    Task {
                                                        _ = await ContentIndexer.shared.indexItem(item, force: true)
                                                        await MainActor.run {
                                                            viewModel.reloadAll()
                                                            isIndexing = false
                                                            if ExtractedArticle.fromJson(viewModel.itemContentsById[item.id]?.articleJson) != nil {
                                                                showingReaderMode = true
                                                            }
                                                        }
                                                    }
                                                }
                                            } label: {
                                                Label(isIndexing ? "Scaricamento…" : "Modalità lettura", systemImage: "doc.plaintext")
                                            }
                                            .buttonStyle(.bordered)
                                            .disabled(isIndexing)

                                            Button {
                                                viewModel.setRead(item, read: item.isUnread)
                                            } label: {
                                                Label(item.isUnread ? "Segna letto" : "Da leggere", systemImage: item.isUnread ? "checkmark.circle" : "book.closed")
                                            }
                                            .buttonStyle(.bordered)
                                        }
                                    }
                                }
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(palette.surfaceContainer)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }

                            // Audio player section
                            if item.itemType == .AUDIO,
                               let fileUrl = FileStorageManager.shared.resolveMediaFile(item.contentUrl),
                               FileManager.default.fileExists(atPath: fileUrl.path) {
                                VStack(alignment: .leading, spacing: 10) {
                                    HStack(spacing: 14) {
                                        Button {
                                            audioPlayer.loadAndToggle(url: fileUrl)
                                        } label: {
                                            Image(systemName: audioPlayer.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                                                .font(.system(size: 42))
                                                .foregroundStyle(palette.primary)
                                        }
                                        .buttonStyle(.plain)

                                        VStack(alignment: .leading, spacing: 4) {
                                            Text("Registrazione vocale / Audio")
                                                .font(.subheadline.weight(.semibold))
                                            let total = max(audioPlayer.durationMs, item.audioDurationMs ?? 0)
                                            Text("\(formatMs(audioPlayer.currentTimeMs)) / \(formatMs(total))")
                                                .font(.caption.monospacedDigit())
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer()

                                        Button {
                                            isIndexing = true
                                            Task {
                                                _ = await ContentIndexer.shared.indexItem(item, force: true)
                                                await MainActor.run {
                                                    viewModel.reloadAll()
                                                    isIndexing = false
                                                }
                                            }
                                        } label: {
                                            Label(isIndexing ? "Trascrizione…" : "Trascrivi", systemImage: "waveform.and.mic")
                                                .font(.caption.weight(.semibold))
                                        }
                                        .buttonStyle(.bordered)
                                        .disabled(isIndexing)
                                    }
                                }
                                .padding(14)
                                .background(palette.surfaceContainer)
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            }

                            // Media preview (Photo / Drawing / PDF)
                            if (item.itemType == .PHOTO || item.itemType == .DRAWING),
                               let fileUrl = FileStorageManager.shared.resolveMediaFile(item.contentUrl),
                               let uiImage = UIImage(contentsOfFile: fileUrl.path) {
                                VStack(alignment: .leading, spacing: 10) {
                                    Image(uiImage: uiImage)
                                        .resizable()
                                        .scaledToFit()
                                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                                    HStack(spacing: 10) {
                                        Button {
                                            showingDrawingCanvas = true
                                        } label: {
                                            Label("Disegna sopra", systemImage: "pencil.tip.crop.circle")
                                                .font(.caption.weight(.semibold))
                                        }
                                        .buttonStyle(.bordered)

                                        Button {
                                            isIndexing = true
                                            Task {
                                                _ = await ContentIndexer.shared.indexItem(item, force: true)
                                                await MainActor.run {
                                                    viewModel.reloadAll()
                                                    isIndexing = false
                                                }
                                            }
                                        } label: {
                                            Label(isIndexing ? "OCR in corso…" : "Estrai testo (OCR)", systemImage: "text.viewfinder")
                                                .font(.caption.weight(.semibold))
                                        }
                                        .buttonStyle(.bordered)
                                        .disabled(isIndexing)
                                    }
                                }
                            } else if item.itemType == .PDF,
                                      let fileUrl = FileStorageManager.shared.resolveMediaFile(item.contentUrl),
                                      FileManager.default.fileExists(atPath: fileUrl.path) {
                                VStack(alignment: .leading, spacing: 10) {
                                    PdfQuickPreview(url: fileUrl)
                                        .frame(height: 420)
                                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                                    HStack(spacing: 10) {
                                        Button {
                                            isIndexing = true
                                            Task {
                                                _ = await ContentIndexer.shared.indexItem(item, force: true)
                                                await MainActor.run {
                                                    viewModel.reloadAll()
                                                    isIndexing = false
                                                }
                                            }
                                        } label: {
                                            Label(isIndexing ? "Estrazione…" : "Estrai testo PDF / OCR", systemImage: "doc.text.magnifyingglass")
                                                .font(.caption.weight(.semibold))
                                        }
                                        .buttonStyle(.bordered)
                                        .disabled(isIndexing)
                                    }
                                }
                            }

                            // Checklist
                            if item.itemType == .CHECKLIST {
                                let checklist = ChecklistItem.fromJson(item.checklistJson)
                                VStack(alignment: .leading, spacing: 10) {
                                    ForEach(checklist) { check in
                                        Button {
                                            viewModel.toggleChecklistItem(in: entry, checklistItemId: check.id)
                                        } label: {
                                            HStack(spacing: 10) {
                                                Image(systemName: check.isChecked ? "checkmark.square.fill" : "square")
                                                    .font(.title3)
                                                    .foregroundColor(check.isChecked ? palette.primary : palette.outline)
                                                Text(check.text)
                                                    .font(.body)
                                                    .strikethrough(check.isChecked)
                                                    .foregroundColor(check.isChecked ? palette.onSurfaceVariant : palette.onSurface)
                                                Spacer()
                                            }
                                            .padding(.vertical, 4)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                                .padding(14)
                                .background(palette.surfaceContainer)
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            }

                            // RichText Description / Note
                            if let desc = item.description, !desc.isEmpty {
                                VStack(alignment: .leading, spacing: 10) {
                                    Text(RichText.render(desc))
                                        .font(.body)
                                        .foregroundColor(palette.onSurface)
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)

                                    Button {
                                        readAloud.start(title: item.title, body: RichText.toPlainString(desc))
                                    } label: {
                                        Label("Leggi ad alta voce", systemImage: "speaker.wave.2.fill")
                                            .font(.caption.weight(.semibold))
                                    }
                                    .buttonStyle(.bordered)
                                }
                                .padding(14)
                                .background(palette.surfaceContainer)
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            }

                            // Extracted content / OCR / Offline text if present
                            if let content = itemContent,
                               let extracted = content.text,
                               !extracted.isEmpty {
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        Label("Testo estratto / Copia offline", systemImage: "doc.text.magnifyingglass")
                                            .font(.caption.bold())
                                            .foregroundColor(palette.primary)
                                        Spacer()
                                        Button {
                                            readAloud.start(title: item.title, body: extracted)
                                        } label: {
                                            Label("Ascolta", systemImage: "speaker.wave.2.fill")
                                                .font(.caption2.weight(.semibold))
                                        }
                                        .buttonStyle(.bordered)
                                    }
                                    Text(extracted)
                                        .font(.footnote)
                                        .foregroundColor(palette.onSurfaceVariant)
                                        .textSelection(.enabled)
                                }
                                .padding(14)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(palette.surfaceContainer)
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            }
                        }
                        .padding(16)
                        .padding(.bottom, readAloud.isActive ? 90 : 20)
                    }

                    ReadAloudBar(manager: readAloud)
                        .padding(.bottom, 8)
                }
            }
            .navigationTitle("Dettaglio")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                prepareShareFiles()
            }
            .onDisappear {
                audioPlayer.stop()
                readAloud.stop()
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Chiudi") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if !isLockedPrivate {
                        HStack(spacing: 12) {
                            Button {
                                viewModel.togglePin(entry)
                            } label: {
                                Image(systemName: item.isPinned ? "pin.fill" : "pin")
                            }

                            Button {
                                onEdit()
                            } label: {
                                Image(systemName: "pencil")
                            }

                            Menu {
                                if let pkgUrl = sharePackageUrl {
                                    ShareLink(item: pkgUrl) {
                                        Label("Condividi pacchetto (.paperclip)", systemImage: "shippingbox.fill")
                                    }
                                }
                                if let htmlUrl = shareHtmlUrl {
                                    ShareLink(item: htmlUrl) {
                                        Label("Condividi pagina web (.html)", systemImage: "globe")
                                    }
                                }

                                Divider()

                                Button {
                                    viewModel.toggleArchive(entry)
                                    dismiss()
                                } label: {
                                    Label(item.isArchived ? "Ripristina nel feed" : "Archivia", systemImage: "archivebox")
                                }

                                Divider()

                                Button(role: .destructive) {
                                    viewModel.moveToTrash(entry)
                                    dismiss()
                                } label: {
                                    Label("Sposta nel cestino", systemImage: "trash")
                                }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                            }
                        }
                    }
                }
            }
            .sheet(isPresented: $showingReaderMode) {
                if let art = extractedArticle {
                    ReaderModeSheet(item: item, article: art) { updatedHighlights in
                        viewModel.updateArticleHighlights(for: item, highlights: updatedHighlights)
                    }
                }
            }
            .sheet(isPresented: $showingDrawingCanvas) {
                DrawingCanvasSheet(backgroundImagePath: item.contentUrl) { newPath in
                    var updated = item
                    updated.contentUrl = newPath
                    updated.updatedAt = ArchiveItem.nowMillis()
                    viewModel.saveItem(updated, tagIds: entry.tags.map(\.id))
                }
            }
        }
    }

    private func prepareShareFiles() {
        let sel = ShareSelection.forItems([item.id], label: item.title)
        sharePackageUrl = try? SharePackage.writePackageToTempFile(selection: sel)
        shareHtmlUrl = try? SharePackage.writeHtmlToTempFile(selection: sel)
    }

    private func formatMs(_ ms: Int64) -> String {
        let sec = Int(max(0, ms) / 1000)
        return String(format: "%02d:%02d", sec / 60, sec % 60)
    }
}

struct PdfQuickPreview: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.document = PDFDocument(url: url)
        return view
    }

    func updateUIView(_ uiView: PDFView, context: Context) {
        if uiView.document?.documentURL != url {
            uiView.document = PDFDocument(url: url)
        }
    }
}
