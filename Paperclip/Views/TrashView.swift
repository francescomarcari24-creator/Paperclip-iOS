import SwiftUI

struct TrashView: View {
    @ObservedObject var viewModel: MainViewModel
    @Environment(\.paperclipPalette) private var palette
    @State private var showingEmptyConfirm: Bool = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if viewModel.trashedItems.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "trash")
                                .font(.system(size: 36))
                                .foregroundColor(.secondary)
                            Text("Il cestino è vuoto")
                                .font(.headline)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 32)
                    } else {
                        ForEach(viewModel.trashedItems) { entry in
                            let item = entry.item
                            let isLockedPrivate = item.isPrivate && !viewModel.privateUnlocked
                            HStack(spacing: 12) {
                                Image(systemName: isLockedPrivate ? "lock.fill" : item.itemType.systemIcon)
                                    .foregroundColor(palette.primary)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(isLockedPrivate ? "Elemento privato" : item.title)
                                        .font(.body.weight(.medium))
                                        .lineLimit(1)
                                    Text(daysRemainingText(deletedAt: item.deletedAt))
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                Button {
                                    viewModel.restoreFromTrash([item])
                                } label: {
                                    Image(systemName: "arrow.uturn.backward.circle.fill")
                                        .font(.title3)
                                        .foregroundColor(palette.primary)
                                }
                                .buttonStyle(.plain)
                            }
                            .swipeActions(edge: .leading) {
                                Button {
                                    viewModel.restoreFromTrash([item])
                                } label: {
                                    Label("Ripristina", systemImage: "arrow.uturn.backward")
                                }
                                .tint(palette.primary)
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    viewModel.deleteForever([item])
                                } label: {
                                    Label("Elimina", systemImage: "trash.slash.fill")
                                }
                            }
                        }
                    }
                } footer: {
                    Text("Gli elementi nel cestino vengono eliminati definitivamente dopo \(ArchiveItem.trashDays) giorni.")
                }
            }
            .navigationTitle("Cestino")
            .toolbar {
                if !viewModel.trashedItems.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Svuota", role: .destructive) {
                            showingEmptyConfirm = true
                        }
                    }
                }
            }
            .alert("Svuotare il cestino?", isPresented: $showingEmptyConfirm) {
                Button("Annulla", role: .cancel) {}
                Button("Elimina definitivamente", role: .destructive) {
                    viewModel.deleteForever(viewModel.trashedItems.map(\.item))
                }
            } message: {
                Text("Tutti gli elementi nel cestino e i relativi file multimediali verranno eliminati per sempre.")
            }
        }
    }

    private func daysRemainingText(deletedAt: Int64?) -> String {
        guard let deletedAt = deletedAt else { return "" }
        let elapsedMs = ArchiveItem.nowMillis() - deletedAt
        let elapsedDays = Int(elapsedMs / (24 * 60 * 60 * 1000))
        let remaining = max(0, ArchiveItem.trashDays - elapsedDays)
        return "Eliminazione tra \(remaining) giorni"
    }
}
