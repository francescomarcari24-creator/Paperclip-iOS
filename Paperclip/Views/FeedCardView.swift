import SwiftUI

struct FeedCardView: View {
    @ObservedObject var viewModel: MainViewModel
    @Environment(\.paperclipPalette) private var palette
    let entry: ArchiveItemWithDetails
    let onTap: () -> Void
    let onEdit: () -> Void

    @State private var dragOffset: CGFloat = 0

    private var item: ArchiveItem { entry.item }
    private var isLockedPrivate: Bool { item.isPrivate && !viewModel.privateUnlocked }

    var body: some View {
        ZStack {
            // Swipe background matching Android SwipeableCard (right -> Trash, left -> Archive)
            HStack {
                if dragOffset > 20 {
                    Label("Cestino", systemImage: "trash.fill")
                        .font(.subheadline.bold())
                        .foregroundColor(.white)
                        .padding(.leading, 20)
                    Spacer()
                } else if dragOffset < -20 {
                    Spacer()
                    Label(item.isArchived ? "Ripristina" : "Archivia", systemImage: "archivebox.fill")
                        .font(.subheadline.bold())
                        .foregroundColor(.white)
                        .padding(.trailing, 20)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(dragOffset > 20 ? Color.red.opacity(0.85) : (dragOffset < -20 ? palette.primary : Color.clear))
            )

            cardContent
                .offset(x: dragOffset)
                .gesture(
                    DragGesture(minimumDistance: 24, coordinateSpace: .local)
                        .onChanged { value in
                            if abs(value.translation.width) > abs(value.translation.height) {
                                dragOffset = value.translation.width
                            }
                        }
                        .onEnded { value in
                            if value.translation.width > 110 {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                    dragOffset = 0
                                    viewModel.moveToTrash(entry)
                                }
                            } else if value.translation.width < -110 {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                    dragOffset = 0
                                    viewModel.toggleArchive(entry)
                                }
                            } else {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                    dragOffset = 0
                                }
                            }
                        }
                )
        }
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            if isLockedPrivate {
                HStack(spacing: 12) {
                    Image(systemName: "lock.fill")
                        .font(.title3)
                        .foregroundColor(palette.primary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Elemento privato")
                            .font(.headline)
                            .foregroundColor(palette.onSurface)
                        Text("Tocca per sbloccare con Face ID o codice")
                            .font(.caption)
                            .foregroundColor(palette.onSurfaceVariant)
                    }
                    Spacer()
                }
                .padding(.vertical, 6)
            } else {
                // Header row
                HStack(spacing: 8) {
                    Image(systemName: item.itemType.systemIcon)
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(palette.primary)
                        .padding(6)
                        .background(palette.primaryContainer)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                    Text(item.title.isEmpty ? item.itemType.label : item.title)
                        .font(.headline)
                        .foregroundColor(palette.onSurface)
                        .lineLimit(2)

                    Spacer()

                    if item.isPrivate {
                        Image(systemName: "lock.open.fill")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    if item.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.caption)
                            .foregroundColor(palette.primary)
                    }

                    if item.isUnread {
                        Text("Da leggere")
                            .font(.caption2.weight(.semibold))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(palette.primaryContainer)
                            .foregroundColor(palette.onPrimaryContainer)
                            .clipShape(Capsule())
                    }

                    if let broken = viewModel.brokenLinksMap[item.id] {
                        Label(broken.status == .BROKEN ? "Link rotto" : "Offline", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption2.weight(.bold))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.red.opacity(0.18))
                            .foregroundColor(.red)
                            .clipShape(Capsule())
                    }
                }

                // Body preview
                if item.itemType == .CHECKLIST {
                    let checklist = ChecklistItem.fromJson(item.checklistJson)
                    if !checklist.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(checklist.prefix(5)) { check in
                                Button {
                                    viewModel.toggleChecklistItem(in: entry, checklistItemId: check.id)
                                } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: check.isChecked ? "checkmark.square.fill" : "square")
                                            .foregroundColor(check.isChecked ? palette.primary : palette.outline)
                                        Text(check.text)
                                            .font(.subheadline)
                                            .strikethrough(check.isChecked)
                                            .foregroundColor(check.isChecked ? palette.onSurfaceVariant : palette.onSurface)
                                            .lineLimit(1)
                                        Spacer()
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                            if checklist.count > 5 {
                                Text("+\(checklist.count - 5) altre voci…")
                                    .font(.caption)
                                    .foregroundColor(palette.onSurfaceVariant)
                            }
                        }
                    }
                } else if let desc = item.description, !desc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(RichText.render(desc))
                        .font(.subheadline)
                        .foregroundColor(palette.onSurfaceVariant)
                        .lineLimit(4)
                }

                if item.itemType == .LINK, let url = item.contentUrl, !url.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "globe")
                            .font(.caption2)
                        Text(url)
                            .font(.caption)
                            .lineLimit(1)
                    }
                    .foregroundColor(palette.primary)
                }

                // Footer badges (Folder, Tags, Reminder, Date)
                HStack(spacing: 8) {
                    if let folder = entry.folder {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(Color(hexString: folder.colorHex))
                                .frame(width: 8, height: 8)
                            Text(viewModel.folderTree.pathLabel(folder.id))
                                .font(.caption2.weight(.medium))
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(palette.surfaceVariant.opacity(0.6))
                        .clipShape(Capsule())
                    }

                    ForEach(entry.tags.prefix(2)) { tag in
                        Text("#\(tag.name)")
                            .font(.caption2.weight(.medium))
                            .lineLimit(1)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color(hexString: tag.colorHex).opacity(0.2))
                            .foregroundColor(palette.onSurface)
                            .clipShape(Capsule())
                    }

                    if let mins = item.reminderMinutes {
                        HStack(spacing: 3) {
                            Image(systemName: "bell.fill")
                                .font(.caption2)
                            Text(String(format: "%02d:%02d", mins / 60, mins % 60))
                                .font(.caption2)
                                .lineLimit(1)
                        }
                        .fixedSize(horizontal: true, vertical: false)
                        .foregroundColor(palette.primary)
                    }

                    Spacer()

                    Text(Self.formatDate(item.createdAt))
                        .font(.caption2)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .foregroundColor(palette.onSurfaceVariant)
                }
            }
        }
        .padding(14)
        .background(palette.surfaceContainer)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(item.isPinned ? palette.primary.opacity(0.55) : palette.outline.opacity(0.15), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onTapGesture(perform: onTap)
        .contextMenu {
            if !isLockedPrivate {
                Button {
                    onEdit()
                } label: {
                    Label("Modifica", systemImage: "pencil")
                }

                Button {
                    viewModel.togglePin(entry)
                } label: {
                    Label(item.isPinned ? "Rimuovi fissato" : "Fissa in alto", systemImage: item.isPinned ? "pin.slash" : "pin")
                }

                if item.hasReadState {
                    Button {
                        viewModel.setRead(item, read: item.isUnread)
                    } label: {
                        Label(item.isUnread ? "Segna come letto" : "Segna da leggere", systemImage: item.isUnread ? "checkmark.circle" : "book.closed")
                    }
                }

                Button {
                    viewModel.toggleArchive(entry)
                } label: {
                    Label(item.isArchived ? "Ripristina nel feed" : "Archivia", systemImage: "archivebox")
                }

                Divider()

                Button(role: .destructive) {
                    viewModel.moveToTrash(entry)
                } label: {
                    Label("Sposta nel cestino", systemImage: "trash")
                }
            }
        }
    }

    private static func formatDate(_ millis: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(millis) / 1000.0)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "it_IT")
        formatter.dateStyle = .short
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }
}
