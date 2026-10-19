import SwiftUI

struct FoldersAndTagsView: View {
    @ObservedObject var viewModel: MainViewModel
    @Environment(\.paperclipPalette) private var palette

    @State private var showingFolderDialog: Bool = false
    @State private var editingFolder: Folder? = nil
    @State private var folderName: String = ""
    @State private var folderColorHex: String = "#6200EE"
    @State private var folderParentId: Int64? = nil

    @State private var showingTagDialog: Bool = false
    @State private var editingTag: Tag? = nil
    @State private var tagName: String = ""
    @State private var tagColorHex: String = "#03DAC6"

    private let colorChoices: [(String, String)] = [
        ("Viola", "#6200EE"),
        ("Blu", "#1E5BD8"),
        ("Verde acqua", "#00897B"),
        ("Verde", "#43A047"),
        ("Giallo", "#FDD835"),
        ("Arancione", "#F57C00"),
        ("Rosso", "#E53935"),
        ("Rosa", "#F48FB1")
    ]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if viewModel.folderTree.entries.isEmpty {
                        Text("Nessuna cartella creata.")
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(viewModel.folderTree.entries) { entry in
                            HStack(spacing: 10) {
                                if entry.depth > 0 {
                                    Spacer()
                                        .frame(width: CGFloat(entry.depth) * 18)
                                }
                                Circle()
                                    .fill(Color(hexString: entry.folder.colorHex))
                                    .frame(width: 12, height: 12)
                                Image(systemName: "folder.fill")
                                    .foregroundColor(Color(hexString: entry.folder.colorHex))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.folder.name)
                                        .font(.body.weight(.medium))
                                    if entry.depth > 0 {
                                        Text(viewModel.folderTree.pathLabel(entry.folder.id))
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }
                                }
                                Spacer()
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                beginEditFolder(entry.folder)
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    viewModel.deleteFolder(entry.folder)
                                } label: {
                                    Label("Elimina", systemImage: "trash")
                                }
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text("Cartelle e Sottocartelle")
                        Spacer()
                        Button {
                            beginNewFolder()
                        } label: {
                            Label("Nuova", systemImage: "folder.badge.plus")
                                .font(.caption.bold())
                        }
                    }
                } footer: {
                    Text("Eliminando una cartella, le sue sottocartelle e i suoi elementi salgono al livello superiore (come su Android).")
                }

                Section {
                    if viewModel.tags.isEmpty {
                        Text("Nessun tag creato.")
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(viewModel.tags) { tag in
                            HStack(spacing: 10) {
                                Circle()
                                    .fill(Color(hexString: tag.colorHex))
                                    .frame(width: 12, height: 12)
                                Text("#\(tag.name)")
                                    .font(.body.weight(.medium))
                                Spacer()
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                beginEditTag(tag)
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    viewModel.deleteTag(tag)
                                } label: {
                                    Label("Elimina", systemImage: "trash")
                                }
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text("Tag")
                        Spacer()
                        Button {
                            beginNewTag()
                        } label: {
                            Label("Nuovo", systemImage: "tag.fill")
                                .font(.caption.bold())
                        }
                    }
                }
            }
            .navigationTitle("Cartelle e Tag")
            .sheet(isPresented: $showingFolderDialog) {
                folderEditorSheet
            }
            .sheet(isPresented: $showingTagDialog) {
                tagEditorSheet
            }
        }
    }

    private func beginNewFolder() {
        editingFolder = nil
        folderName = ""
        folderColorHex = "#6200EE"
        folderParentId = nil
        showingFolderDialog = true
    }

    private func beginEditFolder(_ folder: Folder) {
        editingFolder = folder
        folderName = folder.name
        folderColorHex = folder.colorHex
        folderParentId = folder.parentId
        showingFolderDialog = true
    }

    private func beginNewTag() {
        editingTag = nil
        tagName = ""
        tagColorHex = "#03DAC6"
        showingTagDialog = true
    }

    private func beginEditTag(_ tag: Tag) {
        editingTag = tag
        tagName = tag.name
        tagColorHex = tag.colorHex
        showingTagDialog = true
    }

    private var folderEditorSheet: some View {
        NavigationStack {
            Form {
                Section("Nome cartella") {
                    TextField("Es. Lavoro, Progetti…", text: $folderName)
                }

                Section("Cartella superiore") {
                    Picker("Dentro", selection: $folderParentId) {
                        Text("Livello principale").tag(Int64?.none)
                        ForEach(viewModel.folderTree.entries.filter { $0.folder.id != editingFolder?.id }) { entry in
                            Text(viewModel.folderTree.pathLabel(entry.folder.id)).tag(Int64?.some(entry.folder.id))
                        }
                    }
                }

                Section("Colore") {
                    ForEach(colorChoices, id: \.1) { label, hex in
                        Button {
                            folderColorHex = hex
                        } label: {
                            HStack {
                                Circle()
                                    .fill(Color(hexString: hex))
                                    .frame(width: 18, height: 18)
                                Text(label)
                                    .foregroundColor(.primary)
                                Spacer()
                                if folderColorHex.caseInsensitiveCompare(hex) == .orderedSame {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(palette.primary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle(editingFolder == nil ? "Nuova cartella" : "Modifica cartella")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annulla") { showingFolderDialog = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Salva") {
                        let trimmed = folderName.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        let folder = Folder(
                            id: editingFolder?.id ?? 0,
                            name: trimmed,
                            colorHex: folderColorHex,
                            createdAt: editingFolder?.createdAt ?? ArchiveItem.nowMillis(),
                            parentId: folderParentId
                        )
                        viewModel.saveFolder(folder)
                        showingFolderDialog = false
                    }
                    .disabled(folderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private var tagEditorSheet: some View {
        NavigationStack {
            Form {
                Section("Nome tag") {
                    TextField("Es. importante, letture…", text: $tagName)
                }

                Section("Colore") {
                    ForEach(colorChoices, id: \.1) { label, hex in
                        Button {
                            tagColorHex = hex
                        } label: {
                            HStack {
                                Circle()
                                    .fill(Color(hexString: hex))
                                    .frame(width: 18, height: 18)
                                Text(label)
                                    .foregroundColor(.primary)
                                Spacer()
                                if tagColorHex.caseInsensitiveCompare(hex) == .orderedSame {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(palette.primary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle(editingTag == nil ? "Nuovo tag" : "Modifica tag")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annulla") { showingTagDialog = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Salva") {
                        let trimmed = tagName.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        let tag = Tag(
                            id: editingTag?.id ?? 0,
                            name: trimmed,
                            colorHex: tagColorHex
                        )
                        viewModel.saveTag(tag)
                        showingTagDialog = false
                    }
                    .disabled(tagName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
