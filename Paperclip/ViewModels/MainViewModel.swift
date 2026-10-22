import Foundation
import SwiftUI
import LocalAuthentication
import UserNotifications

struct UndoAction: Identifiable, Equatable {
    enum Kind: Equatable {
        case trashed(Int64)
        case archived(Int64, previousArchived: Bool)
    }
    let id = UUID()
    let message: String
    let kind: Kind
}

@MainActor
final class MainViewModel: ObservableObject {
    private let database = PaperclipDatabase.shared
    private let fileStorage = FileStorageManager.shared
    let uiPreferences = UiPreferences.shared

    // Raw DB snapshots
    @Published private(set) var allItemsWithDetails: [ArchiveItemWithDetails] = []
    @Published private(set) var folders: [Folder] = []
    @Published private(set) var tags: [Tag] = []
    @Published private(set) var itemContentsById: [Int64: ItemContent] = [:]
    @Published var brokenLinksMap: [Int64: LinkChecker.BrokenInfo] = LinkChecker.loadMap()

    // Filters
    @Published var selectedType: ItemType? = nil
    @Published var selectedFolderId: Int64? = nil
    @Published var searchQuery: String = ""
    @Published var selectedTagIds: Set<Int64> = []
    @Published var pinnedOnly: Bool = false
    @Published var unreadOnly: Bool = false

    // Multi-selection
    @Published var selectedItemIds: Set<Int64> = []

    // Security / Private items
    @Published var privateUnlocked: Bool = false

    // Undo snackbar
    @Published var activeUndo: UndoAction? = nil

    // Dismissed resurfaced IDs today
    @Published var dismissedResurfacedIds: Set<Int64> = []

    init() {
        reloadAll()
        purgeExpiredTrash()
        indexPendingItemsInBackground()
    }

    var folderTree: FolderTree {
        FolderTree(folders: folders)
    }

    var narrowsFeed: Bool {
        selectedType != nil ||
        selectedFolderId != nil ||
        !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
        !selectedTagIds.isEmpty
    }

    var feedItems: [ArchiveItemWithDetails] {
        let validTagIds = Set(tags.map { $0.id })
        let activeTags = selectedTagIds.intersection(validTagIds)

        let allowedFolderIds: Set<Int64> = {
            guard let fid = selectedFolderId, folders.contains(where: { $0.id == fid }) else {
                return []
            }
            return folderTree.withDescendants(fid)
        }()

        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        let filtered = allItemsWithDetails.filter { entry in
            let item = entry.item
            guard !item.isArchived && item.deletedAt == nil else { return false }

            if let type = selectedType, item.itemType != type {
                return false
            }
            if !allowedFolderIds.isEmpty {
                guard let fid = item.folderId, allowedFolderIds.contains(fid) else { return false }
            }
            if !activeTags.isEmpty {
                let itemTagIds = Set(entry.tags.map { $0.id })
                guard activeTags.isSubset(of: itemTagIds) else { return false }
            }
            if !query.isEmpty {
                let matchesTitle = item.title.lowercased().contains(query)
                let matchesDesc = item.description?.lowercased().contains(query) == true
                let matchesChecklist = item.checklistJson?.lowercased().contains(query) == true
                let matchesHighlights = item.highlightsJson?.lowercased().contains(query) == true
                let matchesLink = item.itemType == .LINK && (item.contentUrl?.lowercased().contains(query) == true)
                let matchesContent = itemContentsById[item.id]?.text?.lowercased().contains(query) == true
                guard matchesTitle || matchesDesc || matchesChecklist || matchesHighlights || matchesLink || matchesContent else {
                    return false
                }
            }
            if !privateUnlocked && item.isPrivate && (narrowsFeed || pinnedOnly || unreadOnly) {
                return false
            }
            if pinnedOnly && !item.isPinned {
                return false
            }
            if unreadOnly && !item.isUnread {
                return false
            }
            return true
        }

        return sortItems(filtered, by: uiPreferences.sortOrder)
    }

    var archivedItems: [ArchiveItemWithDetails] {
        allItemsWithDetails
            .filter { $0.item.isArchived && $0.item.deletedAt == nil }
            .sorted { $0.item.updatedAt > $1.item.updatedAt }
    }

    var trashedItems: [ArchiveItemWithDetails] {
        allItemsWithDetails
            .filter { $0.item.deletedAt != nil }
            .sorted { ($0.item.deletedAt ?? 0) > ($1.item.deletedAt ?? 0) }
    }

    var highlightedItems: [ArchiveItemWithDetails] {
        allItemsWithDetails
            .filter {
                $0.item.deletedAt == nil &&
                !($0.item.highlightsJson ?? "").isEmpty &&
                (privateUnlocked || !$0.item.isPrivate)
            }
            .sorted { $0.item.updatedAt > $1.item.updatedAt }
    }

    var resurfacedItems: [ArchiveItemWithDetails] {
        guard uiPreferences.resurfaceEnabled, !narrowsFeed, !pinnedOnly, !unreadOnly else { return [] }
        let minAgeMs = Int64(uiPreferences.resurfaceMinDays) * 24 * 60 * 60 * 1000
        let cutoff = ArchiveItem.nowMillis() - minAgeMs
        let candidates = allItemsWithDetails.filter {
            $0.item.deletedAt == nil &&
            !$0.item.isPrivate &&
            $0.item.createdAt <= cutoff &&
            !dismissedResurfacedIds.contains($0.item.id)
        }
        guard !candidates.isEmpty else { return [] }
        let daySeed = Int(Date().timeIntervalSince1970 / 86400)
        let sorted = candidates.sorted { a, b in
            let hashA = Int(a.item.id) ^ daySeed
            let hashB = Int(b.item.id) ^ daySeed
            return hashA < hashB
        }
        return Array(sorted.prefix(uiPreferences.resurfaceCount))
    }

    func reloadAll() {
        folders = database.getAllFolders()
        tags = database.getAllTags()
        allItemsWithDetails = database.getAllItemsWithDetails()
        let contents = database.getAllItemContents()
        itemContentsById = Dictionary(uniqueKeysWithValues: contents.map { ($0.itemId, $0) })
        brokenLinksMap = LinkChecker.loadMap()
    }

    private func sortItems(_ list: [ArchiveItemWithDetails], by order: SortOrder) -> [ArchiveItemWithDetails] {
        let locale = Locale(identifier: "it_IT")
        return list.sorted { a, b in
            if a.item.isPinned != b.item.isPinned {
                return a.item.isPinned && !b.item.isPinned
            }
            switch order {
            case .NEWEST:
                return a.item.createdAt > b.item.createdAt
            case .OLDEST:
                return a.item.createdAt < b.item.createdAt
            case .UPDATED:
                return a.item.updatedAt > b.item.updatedAt
            case .TITLE:
                let cmp = a.item.title.compare(b.item.title, options: [.caseInsensitive, .diacriticInsensitive], range: nil, locale: locale)
                if cmp != .orderedSame { return cmp == .orderedAscending }
                return a.item.createdAt > b.item.createdAt
            case .TYPE:
                if a.item.itemType.ordinal != b.item.itemType.ordinal {
                    return a.item.itemType.ordinal < b.item.itemType.ordinal
                }
                return a.item.createdAt > b.item.createdAt
            }
        }
    }

    // MARK: - Item CRUD & Actions

    /// Dopo una creazione, modifica o eliminazione avvisa il P2P, che sincronizza se ci sono dispositivi collegati.
    private func archiveChangedLocally() {
        P2PSyncManager.shared.scheduleSyncAfterLocalChange()
    }

    @discardableResult
    func saveItem(_ item: ArchiveItem, tagIds: [Int64]) -> Int64 {
        let isNew = item.id == 0
        let (finalItem, finalTags): (ArchiveItem, [Int64]) = isNew
            ? AutoRules.apply(item: item, tagIds: tagIds)
            : (item, tagIds)

        let savedId = database.saveItemWithTags(finalItem, tagIds: finalTags)
        reloadAll()
        archiveChangedLocally()
        if let updated = allItemsWithDetails.first(where: { $0.id == savedId })?.item {
            scheduleReminderIfNeeded(for: updated)
            Task {
                _ = await ContentIndexer.shared.indexItem(updated, force: false, db: self.database)
                await MainActor.run {
                    self.reloadAll()
                }
            }
        }
        return savedId
    }

    func reindexItem(_ item: ArchiveItem) {
        Task {
            _ = await ContentIndexer.shared.indexItem(item, force: true, db: self.database)
            await MainActor.run {
                self.reloadAll()
            }
        }
    }

    func indexPendingItemsInBackground() {
        let items = allItemsWithDetails.map(\.item).filter { $0.deletedAt == nil }
        Task.detached(priority: .utility) {
            var didUpdate = false
            for item in items.prefix(15) {
                if await ContentIndexer.shared.indexItem(item, force: false) != nil {
                    didUpdate = true
                }
            }
            if didUpdate {
                await MainActor.run {
                    self.reloadAll()
                }
            }
        }
    }

    func updateArticleHighlights(for item: ArchiveItem, highlights: [ArticleHighlight]) {
        var updated = item
        updated.highlightsJson = ArticleHighlight.toJson(highlights)
        updated.updatedAt = ArchiveItem.nowMillis()
        database.insertOrReplaceItem(updated)
        reloadAll()
        archiveChangedLocally()
    }

    func findLinkDuplicate(url: String?, excludeId: Int64 = 0) -> ArchiveItem? {
        guard let key = LinkUrls.normalize(url) else { return nil }
        return allItemsWithDetails
            .map(\.item)
            .first { $0.id != excludeId && $0.deletedAt == nil && $0.itemType == .LINK && LinkUrls.normalize($0.contentUrl) == key }
    }

    func togglePin(_ entry: ArchiveItemWithDetails) {
        var updated = entry.item
        updated.isPinned.toggle()
        updated.updatedAt = ArchiveItem.nowMillis()
        database.insertOrReplaceItem(updated)
        reloadAll()
        archiveChangedLocally()
    }

    func toggleArchive(_ entry: ArchiveItemWithDetails, showUndo: Bool = true) {
        let previous = entry.item.isArchived
        var updated = entry.item
        updated.isArchived.toggle()
        updated.updatedAt = ArchiveItem.nowMillis()
        database.insertOrReplaceItem(updated)
        reloadAll()
        archiveChangedLocally()
        if showUndo {
            activeUndo = UndoAction(
                message: updated.isArchived ? "Elemento archiviato" : "Ripristinato nel feed",
                kind: .archived(updated.id, previousArchived: previous)
            )
        }
    }

    func moveToTrash(_ entry: ArchiveItemWithDetails, showUndo: Bool = true) {
        var updated = entry.item
        updated.deletedAt = ArchiveItem.nowMillis()
        updated.updatedAt = ArchiveItem.nowMillis()
        database.insertOrReplaceItem(updated)
        cancelReminder(itemId: updated.id)
        reloadAll()
        archiveChangedLocally()
        if showUndo {
            activeUndo = UndoAction(
                message: "Spostato nel cestino",
                kind: .trashed(updated.id)
            )
        }
    }

    func performUndo() {
        guard let undo = activeUndo else { return }
        activeUndo = nil
        switch undo.kind {
        case .trashed(let id):
            if var item = allItemsWithDetails.first(where: { $0.id == id })?.item {
                item.deletedAt = nil
                item.updatedAt = ArchiveItem.nowMillis()
                database.insertOrReplaceItem(item)
                scheduleReminderIfNeeded(for: item)
                reloadAll()
                archiveChangedLocally()
            }
        case .archived(let id, let previousArchived):
            if var item = allItemsWithDetails.first(where: { $0.id == id })?.item {
                item.isArchived = previousArchived
                item.updatedAt = ArchiveItem.nowMillis()
                database.insertOrReplaceItem(item)
                reloadAll()
                archiveChangedLocally()
            }
        }
    }

    func restoreFromTrash(_ items: [ArchiveItem]) {
        let now = ArchiveItem.nowMillis()
        database.inTransaction {
            for var item in items {
                item.deletedAt = nil
                item.updatedAt = now
                database.insertOrReplaceItem(item)
                scheduleReminderIfNeeded(for: item)
            }
        }
        reloadAll()
        archiveChangedLocally()
    }

    func deleteForever(_ items: [ArchiveItem]) {
        database.inTransaction {
            for item in items {
                database.deleteItemPermanently(item.id)
                cancelReminder(itemId: item.id)
                LinkChecker.clearForItem(item.id)
                if ItemType.mediaTypes.contains(item.itemType) {
                    fileStorage.deleteFile(item.contentUrl)
                }
            }
        }
        reloadAll()
        archiveChangedLocally()
    }

    func purgeExpiredTrash() {
        let cutoff = ArchiveItem.nowMillis() - Int64(ArchiveItem.trashDays) * 24 * 60 * 60 * 1000
        let expired = allItemsWithDetails
            .map(\.item)
            .filter { ($0.deletedAt ?? Int64.max) < cutoff }
        if !expired.isEmpty {
            deleteForever(expired)
            AppLogger.shared.info("Cestino", "Eliminati definitivamente \(expired.count) elementi scaduti (>30 giorni)")
        }
    }

    func setRead(_ item: ArchiveItem, read: Bool) {
        var updated = item
        updated.readAt = read ? ArchiveItem.nowMillis() : nil
        updated.updatedAt = ArchiveItem.nowMillis()
        database.insertOrReplaceItem(updated)
        reloadAll()
        archiveChangedLocally()
    }

    func markOpened(_ item: ArchiveItem) {
        if item.isUnread {
            setRead(item, read: true)
        }
    }

    func toggleChecklistItem(in entry: ArchiveItemWithDetails, checklistItemId: String) {
        var items = ChecklistItem.fromJson(entry.item.checklistJson)
        guard let idx = items.firstIndex(where: { $0.id == checklistItemId }) else { return }
        items[idx].isChecked.toggle()
        var updated = entry.item
        updated.checklistJson = ChecklistItem.toJson(items)
        updated.updatedAt = ArchiveItem.nowMillis()
        database.insertOrReplaceItem(updated)
        reloadAll()
        archiveChangedLocally()
    }

    func setReminder(for item: ArchiveItem, minutes: Int?, days: Int) {
        var updated = item
        updated.reminderMinutes = minutes
        updated.reminderDays = minutes == nil ? 0 : days
        updated.updatedAt = ArchiveItem.nowMillis()
        database.insertOrReplaceItem(updated)
        scheduleReminderIfNeeded(for: updated)
        reloadAll()
        archiveChangedLocally()
    }

    // MARK: - Folders & Tags

    func saveFolder(_ folder: Folder) {
        database.saveFolder(folder)
        reloadAll()
    }

    func deleteFolder(_ folder: Folder) {
        database.deleteFolder(folder)
        if selectedFolderId == folder.id {
            selectedFolderId = nil
        }
        reloadAll()
    }

    func saveTag(_ tag: Tag) {
        database.saveTag(tag)
        reloadAll()
    }

    func deleteTag(_ tag: Tag) {
        database.deleteTag(tag)
        selectedTagIds.remove(tag.id)
        reloadAll()
    }

    func toggleTagFilter(_ tagId: Int64) {
        if selectedTagIds.contains(tagId) {
            selectedTagIds.remove(tagId)
        } else {
            selectedTagIds.insert(tagId)
        }
    }

    // MARK: - Private Items (PIN / Face ID)

    func unlockPrivateItems() {
        let context = LAContext()
        var error: NSError?
        if context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) {
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Sblocca gli elementi privati di Paperclip") { success, _ in
                Task { @MainActor in
                    if success {
                        self.privateUnlocked = true
                        AppLockManager.shared.isPrivateVaultUnlocked = true
                        AppLogger.shared.info("Sicurezza", "Elementi privati sbloccati con successo")
                    }
                }
            }
        } else {
            privateUnlocked = true
            AppLockManager.shared.isPrivateVaultUnlocked = true
        }
    }

    func lockPrivateItems() {
        privateUnlocked = false
        AppLockManager.shared.isPrivateVaultUnlocked = false
    }

    // MARK: - Local Reminders

    func scheduleReminderIfNeeded(for item: ArchiveItem) {
        cancelReminder(itemId: item.id)
        guard item.deletedAt == nil, let reminderMinutes = item.reminderMinutes else { return }

        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = item.isPrivate ? "Promemoria Paperclip" : item.title
            if !item.isPrivate, let desc = item.description, !desc.isEmpty {
                content.body = RichText.strip(desc)
            } else {
                content.body = "Tocca per aprire in Paperclip"
            }
            content.sound = .default

            var dateComponents = DateComponents()
            dateComponents.hour = reminderMinutes / 60
            dateComponents.minute = reminderMinutes % 60

            let trigger = UNCalendarNotificationTrigger(dateMatching: dateComponents, repeats: item.reminderDays != 0)
            let req = UNNotificationRequest(identifier: "paperclip_reminder_\(item.id)", content: content, trigger: trigger)
            center.add(req)
        }
    }

    func cancelReminder(itemId: Int64) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["paperclip_reminder_\(itemId)"])
    }
}
