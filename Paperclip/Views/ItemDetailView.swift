import SwiftUI
import PDFKit

struct ItemDetailView: View {
    @ObservedObject var viewModel: MainViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.paperclipPalette) private var palette
    @Environment(\.openURL) private var openURL

    let entry: ArchiveItemWithDetails
    let onEdit: () -> Void

    private var item: ArchiveItem { entry.item }
    private var isLockedPrivate: Bool { item.isPrivate && !viewModel.privateUnlocked }

    var body: some View {
        NavigationStack {
            ZStack {
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

                            // Link section
                            if item.itemType == .LINK, let rawUrl = item.contentUrl, !rawUrl.isEmpty {
                                VStack(alignment: .leading, spacing: 10) {
                                    Text(rawUrl)
                                        .font(.footnote)
                                        .foregroundColor(palette.primary)
                                        .textSelection(.enabled)

                                    HStack(spacing: 12) {
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
                                            viewModel.setRead(item, read: item.isUnread)
                                        } label: {
                                            Label(item.isUnread ? "Segna letto" : "Da leggere", systemImage: item.isUnread ? "checkmark.circle" : "book.closed")
                                        }
                                        .buttonStyle(.bordered)
                                    }
                                }
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(palette.surfaceContainer)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }

                            // Media preview (Photo / Drawing / PDF)
                            if (item.itemType == .PHOTO || item.itemType == .DRAWING),
                               let fileUrl = FileStorageManager.shared.resolveMediaFile(item.contentUrl),
                               let uiImage = UIImage(contentsOfFile: fileUrl.path) {
                                Image(uiImage: uiImage)
                                    .resizable()
                                    .scaledToFit()
                                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            } else if item.itemType == .PDF,
                                      let fileUrl = FileStorageManager.shared.resolveMediaFile(item.contentUrl),
                                      FileManager.default.fileExists(atPath: fileUrl.path) {
                                PdfQuickPreview(url: fileUrl)
                                    .frame(height: 420)
                                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
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
                                Text(RichText.render(desc))
                                    .font(.body)
                                    .foregroundColor(palette.onSurface)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(14)
                                    .background(palette.surfaceContainer)
                                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            }

                            // Extracted content / OCR / Offline text if present
                            if let content = viewModel.itemContentsById[item.id],
                               let extracted = content.text,
                               !extracted.isEmpty {
                                VStack(alignment: .leading, spacing: 6) {
                                    Label("Testo estratto / Copia offline", systemImage: "doc.text.magnifyingglass")
                                        .font(.caption.bold())
                                        .foregroundColor(palette.primary)
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
                    }
                }
            }
            .navigationTitle("Dettaglio")
            .navigationBarTitleDisplayMode(.inline)
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
        }
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
