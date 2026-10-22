import SwiftUI

enum MainTab: String, CaseIterable {
    case feed = "Feed"
    case folders = "Cartelle"
    case archive = "Archivio"
    case settings = "Impostazioni"
}

struct MainNavigationView: View {
    @ObservedObject var viewModel: MainViewModel
    @ObservedObject private var preferences = UiPreferences.shared
    @Environment(\.paperclipPalette) private var palette

    @State private var selectedTab: MainTab = .feed
    @State private var showingAddSheet: Bool = false
    @State private var initialAddType: ItemType = .NOTE
    @State private var selectedItemForDetail: ArchiveItemWithDetails? = nil
    @State private var itemToEdit: ArchiveItemWithDetails? = nil
    @State private var showingP2PSync: Bool = false
    @State private var showingHighlightsHub: Bool = false
    @State private var showingQuickScanner: Bool = false
    @State private var showingQuickDrawing: Bool = false
    @State private var showingQuickCamera: Bool = false

    var body: some View {
        ZStack(alignment: .bottom) {
            TabView(selection: $selectedTab) {
                feedTab
                    .tabItem {
                        Label("Feed", systemImage: "tray.full.fill")
                    }
                    .tag(MainTab.feed)

                FoldersAndTagsView(viewModel: viewModel)
                    .tabItem {
                        Label("Cartelle", systemImage: "folder.fill")
                    }
                    .tag(MainTab.folders)

                archiveTab
                    .tabItem {
                        Label("Archivio", systemImage: "archivebox.fill")
                    }
                    .tag(MainTab.archive)

                SettingsView(viewModel: viewModel, onOpenHighlights: { showingHighlightsHub = true })
                    .tabItem {
                        Label("Impostazioni", systemImage: "gearshape.fill")
                    }
                    .tag(MainTab.settings)
            }

            if let undo = viewModel.activeUndo {
                HStack(spacing: 12) {
                    Text(undo.message)
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(.white)
                    Spacer()
                    Button("Annulla") {
                        withAnimation {
                            viewModel.performUndo()
                        }
                    }
                    .font(.subheadline.bold())
                    .foregroundColor(palette.primaryContainer)
                    .fixedSize(horizontal: true, vertical: false)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Color.black.opacity(0.88))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding(.horizontal, 16)
                .padding(.bottom, 64)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .sheet(isPresented: $showingAddSheet) {
            AddEditItemView(viewModel: viewModel, existingEntry: nil, defaultType: initialAddType)
        }
        .sheet(item: $itemToEdit) { entry in
            AddEditItemView(viewModel: viewModel, existingEntry: entry, defaultType: entry.item.itemType)
        }
        .sheet(item: $selectedItemForDetail) { entry in
            let currentEntry = viewModel.allItemsWithDetails.first(where: { $0.id == entry.id }) ?? entry
            ItemDetailView(
                viewModel: viewModel,
                entry: currentEntry,
                onEdit: {
                    selectedItemForDetail = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        itemToEdit = currentEntry
                    }
                }
            )
        }
        .sheet(isPresented: $showingP2PSync) {
            P2PSyncView()
                .environmentObject(viewModel)
        }
        .sheet(isPresented: $showingHighlightsHub) {
            HighlightsHubSheet(viewModel: viewModel) { entry in
                showingHighlightsHub = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    selectedItemForDetail = entry
                }
            }
        }
        .sheet(isPresented: $showingQuickScanner) {
            DocumentScannerView { pdfPath, pages in
                let item = ArchiveItem(
                    title: "Scansione (\(pages) pag.)",
                    itemType: .PDF,
                    contentUrl: pdfPath,
                    folderId: viewModel.selectedFolderId
                )
                viewModel.saveItem(item, tagIds: [])
            }
        }
        .sheet(isPresented: $showingQuickDrawing) {
            DrawingCanvasSheet { drawingPath in
                let item = ArchiveItem(
                    title: "Disegno",
                    itemType: .DRAWING,
                    contentUrl: drawingPath,
                    folderId: viewModel.selectedFolderId
                )
                viewModel.saveItem(item, tagIds: [])
            }
        }
        .sheet(isPresented: $showingQuickCamera) {
            CameraCaptureView { photoPath in
                let item = ArchiveItem(
                    title: "Foto",
                    itemType: .PHOTO,
                    contentUrl: photoPath,
                    folderId: viewModel.selectedFolderId
                )
                viewModel.saveItem(item, tagIds: [])
            }
        }
    }

    // MARK: - Feed Tab

    private var feedTab: some View {
        NavigationStack {
            ZStack(alignment: .bottomTrailing) {
                palette.background.ignoresSafeArea()

                ScrollView {
                    LazyVStack(spacing: 12) {
                        if preferences.showFeedFilters {
                            filterBarSection
                        }

                        if !viewModel.resurfacedItems.isEmpty {
                            resurfaceSection
                        }

                        let items = viewModel.feedItems
                        if items.isEmpty {
                            emptyFeedPlaceholder
                        } else {
                            ForEach(items) { entry in
                                FeedCardView(
                                    viewModel: viewModel,
                                    entry: entry,
                                    onTap: {
                                        if entry.item.isPrivate && !viewModel.privateUnlocked {
                                            viewModel.unlockPrivateItems()
                                        } else {
                                            viewModel.markOpened(entry.item)
                                            selectedItemForDetail = entry
                                        }
                                    },
                                    onEdit: {
                                        itemToEdit = entry
                                    }
                                )
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 96)
                }
                .searchable(text: $viewModel.searchQuery, prompt: "Cerca nel testo, OCR, PDF, trascrizioni…")

                Menu {
                    Button {
                        initialAddType = .NOTE
                        showingAddSheet = true
                    } label: {
                        Label("Nuova nota", systemImage: "note.text")
                    }
                    Button {
                        initialAddType = .CHECKLIST
                        showingAddSheet = true
                    } label: {
                        Label("Nuova checklist", systemImage: "checklist")
                    }
                    Button {
                        initialAddType = .LINK
                        showingAddSheet = true
                    } label: {
                        Label("Nuovo link", systemImage: "link")
                    }
                    Divider()
                    Button {
                        showingQuickCamera = true
                    } label: {
                        Label("Scatta foto", systemImage: "camera.fill")
                    }
                    Button {
                        initialAddType = .AUDIO
                        showingAddSheet = true
                    } label: {
                        Label("Nota vocale", systemImage: "mic.fill")
                    }
                    Button {
                        showingQuickScanner = true
                    } label: {
                        Label("Scansiona documento (PDF)", systemImage: "doc.viewfinder")
                    }
                    Button {
                        showingQuickDrawing = true
                    } label: {
                        Label("Disegno a mano libera", systemImage: "scribble.variable")
                    }
                    Divider()
                    Button {
                        initialAddType = .PHOTO
                        showingAddSheet = true
                    } label: {
                        Label("Importa Foto / Video / PDF", systemImage: "photo.on.rectangle")
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.title2.bold())
                        .foregroundColor(palette.onPrimary)
                        .frame(width: 58, height: 58)
                        .background(palette.primary)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .shadow(color: Color.black.opacity(0.22), radius: 8, x: 0, y: 4)
                }
                .padding(.trailing, 20)
                .padding(.bottom, 20)
            }
            .navigationTitle("Paperclip")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    HStack(spacing: 12) {
                        Button {
                            showingP2PSync = true
                        } label: {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                        }
                        .accessibilityLabel("Sincronizzazione Wi-Fi P2P")

                        if viewModel.allItemsWithDetails.contains(where: { $0.item.isPrivate && $0.item.deletedAt == nil }) {
                            Button {
                                if viewModel.privateUnlocked {
                                    viewModel.lockPrivateItems()
                                } else {
                                    viewModel.unlockPrivateItems()
                                }
                            } label: {
                                Image(systemName: viewModel.privateUnlocked ? "lock.open.fill" : "lock.fill")
                            }
                            .accessibilityLabel(viewModel.privateUnlocked ? "Blocca elementi privati" : "Sblocca elementi privati")
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    ThinSwitch(
                        isOn: Binding(
                            get: { preferences.showFeedFilters },
                            set: { newValue in
                                withAnimation { preferences.showFeedFilters = newValue }
                            }
                        ),
                        accessibilityLabel: "Mostra filtri"
                    )
                }
            }
        }
    }

    // MARK: - Filter Bar

    /// Stesso ordine dei filtri per tipo di Android.
    private static let typeFilterOrder: [ItemType] = [
        .LINK, .PHOTO, .VIDEO, .AUDIO, .PDF, .CHECKLIST, .DRAWING, .NOTE
    ]

    private var filterBarSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    FilterChip(
                        title: "Tutti",
                        icon: "square.grid.2x2",
                        isSelected: viewModel.selectedType == nil && !viewModel.pinnedOnly && !viewModel.unreadOnly
                    ) {
                        viewModel.selectedType = nil
                        viewModel.pinnedOnly = false
                        viewModel.unreadOnly = false
                    }

                    FilterChip(
                        title: "Fissati",
                        icon: "pin.fill",
                        isSelected: viewModel.pinnedOnly
                    ) {
                        viewModel.pinnedOnly.toggle()
                    }

                    FilterChip(
                        title: "Da leggere",
                        icon: "book.closed.fill",
                        isSelected: viewModel.unreadOnly
                    ) {
                        viewModel.unreadOnly.toggle()
                    }

                    ForEach(Self.typeFilterOrder) { type in
                        FilterChip(
                            title: type == .PHOTO ? "Immagini" : type.pluralLabel,
                            icon: type.systemIcon,
                            isSelected: viewModel.selectedType == type
                        ) {
                            viewModel.selectedType = (viewModel.selectedType == type) ? nil : type
                        }
                    }
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Menu {
                        Button {
                            viewModel.selectedFolderId = nil
                        } label: {
                            Label("Tutte le cartelle", systemImage: viewModel.selectedFolderId == nil ? "checkmark" : "folder")
                        }
                        if viewModel.folders.isEmpty {
                            Text("Nessuna cartella creata")
                        }
                        ForEach(viewModel.folderTree.entries) { entry in
                            let prefix = String(repeating: "  ", count: entry.depth)
                            Button {
                                viewModel.selectedFolderId = entry.folder.id
                            } label: {
                                Label("\(prefix)\(entry.folder.name)", systemImage: viewModel.selectedFolderId == entry.folder.id ? "checkmark" : "folder")
                            }
                        }
                    } label: {
                        let label = viewModel.selectedFolderId.flatMap { viewModel.folderTree.pathLabel($0) } ?? "Cartella"
                        FilterChipLabel(
                            title: label,
                            icon: "folder.fill",
                            isSelected: viewModel.selectedFolderId != nil
                        )
                    }

                    Menu {
                        Button {
                            viewModel.selectedTagIds = []
                        } label: {
                            Label("Tutte le etichette", systemImage: viewModel.selectedTagIds.isEmpty ? "checkmark" : "tag")
                        }
                        if viewModel.tags.isEmpty {
                            Text("Nessuna etichetta creata")
                        }
                        ForEach(viewModel.tags) { tag in
                            Button {
                                viewModel.toggleTagFilter(tag.id)
                            } label: {
                                Label(tag.name, systemImage: viewModel.selectedTagIds.contains(tag.id) ? "checkmark" : "tag")
                            }
                        }
                    } label: {
                        let selected = viewModel.tags.filter { viewModel.selectedTagIds.contains($0.id) }
                        let label = selected.isEmpty ? "Etichette" : (selected.count == 1 ? selected[0].name : "\(selected.count) etichette")
                        FilterChipLabel(
                            title: label,
                            icon: "tag.fill",
                            isSelected: !selected.isEmpty
                        )
                    }

                    Menu {
                        Picker("Ordina per", selection: $preferences.sortOrder) {
                            ForEach(SortOrder.allCases) { order in
                                Text(order.label).tag(order)
                            }
                        }
                    } label: {
                        FilterChipLabel(
                            title: "Ordina",
                            icon: "arrow.up.arrow.down",
                            isSelected: preferences.sortOrder != .NEWEST
                        )
                    }
                }
            }
        }
        .padding(.bottom, 4)
    }

    // MARK: - Resurface ("Riscopri") Section

    private var resurfaceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Riscopri", systemImage: "sparkles")
                    .font(.subheadline.bold())
                    .foregroundColor(palette.primary)
                Spacer()
                Button("Nascondi tutti") {
                    for entry in viewModel.resurfacedItems {
                        viewModel.dismissedResurfacedIds.insert(entry.id)
                    }
                }
                .font(.caption)
            }

            ForEach(viewModel.resurfacedItems) { entry in
                HStack {
                    Image(systemName: entry.item.itemType.systemIcon)
                        .foregroundColor(palette.primary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.item.title)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Text(entry.item.itemType.label)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button {
                        viewModel.dismissedResurfacedIds.insert(entry.id)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                }
                .padding(10)
                .background(palette.primaryContainer.opacity(0.45))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .onTapGesture {
                    selectedItemForDetail = entry
                }
            }
        }
        .padding(12)
        .background(palette.surfaceContainer)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var emptyFeedPlaceholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "paperclip")
                .font(.system(size: 48))
                .foregroundColor(palette.primary.opacity(0.6))
            Text(viewModel.narrowsFeed ? "Nessun elemento corrisponde ai filtri" : "Il tuo archivio è vuoto")
                .font(.headline)
                .foregroundColor(palette.onSurface)
            Text(viewModel.narrowsFeed ? "Prova a modificare la ricerca o i filtri selezionati." : "Tocca il pulsante + in basso a destra per aggiungere una nota, una checklist, un link, una foto, una nota vocale o una scansione PDF.")
                .font(.subheadline)
                .foregroundColor(palette.onSurfaceVariant)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 64)
    }

    // MARK: - Archive Tab

    private var archiveTab: some View {
        NavigationStack {
            ZStack {
                palette.background.ignoresSafeArea()
                let items = viewModel.archivedItems
                if items.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "archivebox")
                            .font(.system(size: 44))
                            .foregroundColor(.secondary)
                        Text("Nessun elemento archiviato")
                            .font(.headline)
                        Text("Scorri verso sinistra su una scheda nel feed per archiviarla.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                    }
                } else {
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            ForEach(items) { entry in
                                FeedCardView(
                                    viewModel: viewModel,
                                    entry: entry,
                                    onTap: {
                                        if entry.item.isPrivate && !viewModel.privateUnlocked {
                                            viewModel.unlockPrivateItems()
                                        } else {
                                            selectedItemForDetail = entry
                                        }
                                    },
                                    onEdit: {
                                        itemToEdit = entry
                                    }
                                )
                            }
                        }
                        .padding(16)
                    }
                }
            }
            .navigationTitle("Archivio")
        }
    }
}

struct HighlightsHubSheet: View {
    @ObservedObject var viewModel: MainViewModel
    var onSelectEntry: (ArchiveItemWithDetails) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(viewModel.highlightedItems) { entry in
                    Section(entry.item.title) {
                        if entry.item.itemType == .LINK {
                            ForEach(ArticleHighlight.fromJson(entry.item.highlightsJson)) { h in
                                Button {
                                    onSelectEntry(entry)
                                } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("“\(h.text)”")
                                            .font(.subheadline)
                                            .foregroundStyle(.primary)
                                        if let note = h.note, !note.isEmpty {
                                            Text(note)
                                                .font(.caption)
                                                .italic()
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                        } else if entry.item.itemType == .PDF {
                            ForEach(PdfHighlight.fromJson(entry.item.highlightsJson)) { h in
                                Button {
                                    onSelectEntry(entry)
                                } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("“\(h.text ?? "Evidenziazione pag. \(h.page + 1)")”")
                                            .font(.subheadline)
                                            .foregroundStyle(.primary)
                                        Text("Pagina \(h.page + 1)")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Tutte le evidenziazioni")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Chiudi") { dismiss() }
                }
            }
        }
    }
}

/// Selettore a due posizioni (Filtri / Nascondi) che si comporta come la barra inferiore di iOS 26:
/// a riposo il cursore è una pillola colorata; alla pressione diventa una lente di vetro trasparente
/// più grande della barra, segue il dito allungandosi con la velocità, ingrandisce l'etichetta
/// sottostante e al rilascio scatta con rimbalzo sulla posizione più vicina.
struct ThinSwitch: View {
    @Binding var isOn: Bool
    let accessibilityLabel: String
    @Environment(\.paperclipPalette) private var palette
    @State private var dragX: CGFloat? = nil
    /// Allungamento orizzontale della lente (0 = fermo), calcolato dalla velocità del trascinamento.
    @State private var stretch: CGFloat = 0

    private let segmentWidth: CGFloat = 80
    private let height: CGFloat = 36
    private let inset: CGFloat = 3

    private var thumbWidth: CGFloat { segmentWidth - inset * 2 }
    private var restingX: CGFloat { isOn ? inset : segmentWidth + inset }
    private var thumbX: CGFloat { dragX ?? restingX }
    private var isPressed: Bool { dragX != nil }
    /// Il cursore è sopra "Filtri" se il suo centro sta nella metà sinistra.
    private var thumbOnLeft: Bool { thumbX + thumbWidth / 2 < segmentWidth }

    var body: some View {
        ZStack(alignment: .leading) {
            HStack(spacing: 0) {
                label("Filtri", highlighted: thumbOnLeft)
                label("Nascondi", highlighted: !thumbOnLeft)
            }

            Capsule()
                .fill(palette.primary.opacity(isPressed ? 0 : 0.22))
                .frame(width: thumbWidth, height: height - inset * 2)
                .modifier(GlassLens(isPressed: isPressed))
                .scaleEffect(x: (isPressed ? 1.18 : 1) * (1 + stretch),
                             y: (isPressed ? 1.32 : 1) * (1 - stretch * 0.5))
                .offset(x: thumbX)
                .allowsHitTesting(false)
        }
        .frame(width: segmentWidth * 2, height: height)
        .modifier(GlassBar(fallback: palette.surfaceVariant.opacity(0.6)))
        .contentShape(Capsule())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let x = min(max(value.location.x - thumbWidth / 2, inset), segmentWidth + inset)
                    let velocity = value.predictedEndLocation.x - value.location.x
                    withAnimation(.interactiveSpring(response: 0.25, dampingFraction: 0.7)) {
                        dragX = x
                        stretch = min(abs(velocity) / 900, 0.18)
                    }
                }
                .onEnded { _ in
                    let onLeft = thumbOnLeft
                    if onLeft != isOn {
                        UISelectionFeedbackGenerator().selectionChanged()
                    }
                    withAnimation(.spring(response: 0.38, dampingFraction: 0.62)) {
                        isOn = onLeft
                        dragX = nil
                        stretch = 0
                    }
                }
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(isOn ? "Filtri visibili" : "Filtri nascosti")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { isOn.toggle() }
    }

    private func label(_ title: String, highlighted: Bool) -> some View {
        Text(title)
            .font(.subheadline.weight(highlighted ? .semibold : .regular))
            .foregroundColor(highlighted ? palette.primary : palette.onSurfaceVariant)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .scaleEffect(isPressed && highlighted ? 1.12 : 1)
            .frame(width: segmentWidth, height: height)
    }
}

/// Fondo del selettore: su iOS 26 solo vetro Liquid Glass come la barra inferiore; prima un fondo pieno.
private struct GlassBar: ViewModifier {
    let fallback: Color

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: Capsule())
        } else {
            content.background(Capsule().fill(fallback))
        }
    }
}

/// Cursore del selettore: alla pressione diventa una lente di vetro trasparente come quella della barra inferiore.
private struct GlassLens: ViewModifier {
    let isPressed: Bool

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(isPressed ? .clear.interactive() : .identity, in: Capsule())
        } else {
            content.background(Capsule().fill(.ultraThinMaterial).opacity(isPressed ? 1 : 0))
        }
    }
}

struct FilterChip: View {
    let title: String
    let icon: String?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            FilterChipLabel(title: title, icon: icon, isSelected: isSelected)
        }
        .buttonStyle(.plain)
    }
}

struct FilterChipLabel: View {
    @Environment(\.paperclipPalette) private var palette
    let title: String
    let icon: String?
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 6) {
            if let icon = icon {
                Image(systemName: icon)
                    .font(.caption)
            }
            Text(title)
                .font(.caption.weight(.medium))
                .lineLimit(1)
        }
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(isSelected ? palette.primaryContainer : palette.surfaceContainer)
        .foregroundColor(isSelected ? palette.onPrimaryContainer : palette.onSurfaceVariant)
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .stroke(isSelected ? palette.primary : palette.outline.opacity(0.3), lineWidth: 1)
        )
    }
}
