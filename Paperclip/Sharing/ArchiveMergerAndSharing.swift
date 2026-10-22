import Foundation
import CryptoKit
import UIKit
import UserNotifications

// MARK: - ArchiveRows & ArchiveMerger

struct ArchiveRows: Codable {
    var folders: [Folder]
    var tags: [Tag]
    var items: [ArchiveItem]
    var crossRefs: [ItemTagCrossRef]
    var contents: [ItemContent]? = nil

    static func load(db: PaperclipDatabase = .shared) -> ArchiveRows {
        ArchiveRows(
            folders: db.getAllFolders(),
            tags: db.getAllTags(),
            items: db.getAllItems(),
            crossRefs: db.getAllCrossRefs(),
            contents: db.getAllItemContents()
        )
    }

    func activeOnly(includePrivate: Bool = false) -> ArchiveRows {
        let activeItems = items.filter { $0.deletedAt == nil && (includePrivate || !$0.isPrivate) }
        let activeIds = Set(activeItems.map(\.id))
        return ArchiveRows(
            folders: folders,
            tags: tags,
            items: activeItems,
            crossRefs: crossRefs.filter { activeIds.contains($0.itemId) },
            contents: (contents ?? []).filter { activeIds.contains($0.itemId) }
        )
    }
}

// MARK: - ItemMatcher & DeletedItems

/// Ciò che identifica un elemento fra archivi diversi, dove gli id sono locali.
struct ItemIdentity: Hashable {
    let title: String
    let createdAt: Int64
    let itemType: ItemType

    var key: String { "\(title)|\(createdAt)" }
    var instant: String { "\(createdAt)|\(itemType.rawValue)" }
}

protocol ItemIdentifiable {
    var identity: ItemIdentity { get }
}

extension ArchiveItem: ItemIdentifiable {
    var identity: ItemIdentity { ItemIdentity(title: title, createdAt: createdAt, itemType: itemType) }
}

/**
 * Trova fra [local] lo stesso elemento di uno di [remote]: per titolo e data di creazione, oppure,
 * se il titolo è stato cambiato, per data di creazione e tipo, purché indichino un solo elemento da
 * entrambe le parti (un'importazione può dare lo stesso istante a più elementi: allora nessuna
 * corrispondenza, meglio un doppione che unire elementi diversi).
 */
struct ItemMatcher<Local: ItemIdentifiable> {
    private let byKey: [String: Local]
    private let unclaimedByInstant: [String: [Local]]
    private let remoteCountByInstant: [String: Int]

    init(local: [Local], remote: [ItemIdentity]) {
        var byKey: [String: Local] = [:]
        for element in local { byKey[element.identity.key] = element }
        let remoteKeys = Set(remote.map(\.key))
        self.byKey = byKey
        self.unclaimedByInstant = Dictionary(grouping: local.filter { !remoteKeys.contains($0.identity.key) }, by: { $0.identity.instant })
        self.remoteCountByInstant = remote.reduce(into: [:]) { $0[$1.instant, default: 0] += 1 }
    }

    func match(_ remote: ItemIdentity) -> Local? {
        if let exact = byKey[remote.key] { return exact }
        guard remoteCountByInstant[remote.instant] == 1,
              let candidates = unclaimedByInstant[remote.instant], candidates.count == 1 else { return nil }
        return candidates[0]
    }
}

/// Un elemento eliminato definitivamente: viaggia con la sincronizzazione perché gli altri dispositivi
/// lo eliminino a loro volta invece di rimandarlo indietro.
struct DeletedItem: Codable, Equatable, ItemIdentifiable {
    var title: String
    var createdAt: Int64
    var itemType: ItemType
    var deletedAt: Int64
    /// Cartella dell'elemento sul dispositivo che lo ha eliminato: decide a quali cartelle condivise mandarlo.
    var folderId: Int64? = nil

    var identity: ItemIdentity { ItemIdentity(title: title, createdAt: createdAt, itemType: itemType) }

    init(item: ArchiveItem, deletedAt: Int64) {
        self.title = item.title
        self.createdAt = item.createdAt
        self.itemType = item.itemType
        self.deletedAt = deletedAt
        self.folderId = item.folderId
    }
}

/// Gli elementi eliminati definitivamente negli ultimi [keepDays] giorni.
final class DeletedItems {
    static let shared = DeletedItems()
    static let keepDays: Int64 = 180

    private let key = "paperclip_deleted_items"
    private let lock = NSLock()

    var all: [DeletedItem] {
        lock.lock()
        defer { lock.unlock() }
        return load()
    }

    func record(_ deleted: [DeletedItem]) {
        guard !deleted.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        var byKey: [String: DeletedItem] = [:]
        for entry in load() + deleted {
            if let existing = byKey[entry.identity.key], existing.deletedAt >= entry.deletedAt { continue }
            byKey[entry.identity.key] = entry
        }
        let cutoff = ArchiveItem.nowMillis() - Self.keepDays * 24 * 60 * 60 * 1000
        let kept = byKey.values.filter { $0.deletedAt >= cutoff }.sorted { $0.deletedAt < $1.deletedAt }
        if let data = try? JSONEncoder().encode(kept) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private func load() -> [DeletedItem] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([DeletedItem].self, from: data) else { return [] }
        return decoded
    }
}

/// Eliminazione definitiva di elementi con i loro file, promemoria e controlli dei link.
enum PermanentDeletion {
    static func delete(_ items: [ArchiveItem], database: PaperclipDatabase = .shared) {
        guard !items.isEmpty else { return }
        database.inTransaction {
            for item in items {
                database.deleteItemPermanently(item.id)
            }
        }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: items.map { "paperclip_reminder_\($0.id)" })
        for item in items {
            LinkChecker.clearForItem(item.id)
            if ItemType.mediaTypes.contains(item.itemType) {
                FileStorageManager.shared.deleteFile(item.contentUrl)
            }
        }
    }

    /**
     * Applica le eliminazioni arrivate da un altro dispositivo: elimina gli elementi corrispondenti non
     * modificati dopo l'eliminazione (solo quelli fra [allowedItemIds], se indicati) e le ricorda per
     * propagarle. Restituisce quanti elementi ha eliminato.
     */
    @discardableResult
    static func applyRemote(_ deleted: [DeletedItem], allowedItemIds: Set<Int64>? = nil, database: PaperclipDatabase = .shared) -> Int {
        guard !deleted.isEmpty else { return 0 }
        let candidates = database.getAllItems().filter { allowedItemIds?.contains($0.id) ?? true }
        let matcher = ItemMatcher(local: candidates, remote: deleted.map(\.identity))
        var toDelete: [Int64: ArchiveItem] = [:]
        for entry in deleted {
            if let item = matcher.match(entry.identity), item.updatedAt <= entry.deletedAt {
                toDelete[item.id] = item
            }
        }
        delete(Array(toDelete.values), database: database)
        DeletedItems.shared.record(deleted)
        return toDelete.count
    }

    /// [items] senza quelli eliminati qui dopo la loro ultima modifica: non devono tornare.
    static func withoutDeleted(_ items: [ArchiveItem]) -> [ArchiveItem] {
        let deleted = DeletedItems.shared.all
        guard !deleted.isEmpty else { return items }
        let matcher = ItemMatcher(local: deleted, remote: items.map(\.identity))
        return items.filter { item in
            guard let entry = matcher.match(item.identity) else { return true }
            return item.updatedAt > entry.deletedAt
        }
    }
}

final class ArchiveMerger {
    enum FolderPlacement {
        case byPath
        case intoFolder(remoteRootId: Int64, localRootId: Int64)
    }

    struct Result: Equatable {
        let added: Int
        let updated: Int
    }

    private let database: PaperclipDatabase

    init(database: PaperclipDatabase = .shared) {
        self.database = database
    }

    func merge(
        rows: ArchiveRows,
        placement: FolderPlacement,
        localizeMedia: (String?) -> String?
    ) -> Result {
        let matcher = ItemMatcher(local: database.getAllItems(), remote: rows.items.map(\.identity))

        let itemsToApply: [ArchiveItem] = rows.items.compactMap { remote in
            if let local = matcher.match(remote.identity), remote.updatedAt <= local.updatedAt {
                return nil
            }
            var copy = remote
            copy.contentUrl = localizeMedia(remote.contentUrl)
            copy.previewImageUrl = localizeMedia(remote.previewImageUrl)
            return copy
        }

        var remoteTagIdsByItem: [Int64: [Int64]] = [:]
        for ref in rows.crossRefs {
            remoteTagIdsByItem[ref.itemId, default: []].append(ref.tagId)
        }

        let remoteUrls = Dictionary(uniqueKeysWithValues: rows.items.map { ($0.id, $0.contentUrl) })
        var remoteContents: [Int64: ItemContent] = [:]
        for content in rows.contents ?? [] {
            if remoteUrls[content.itemId] == content.sourceKey {
                remoteContents[content.itemId] = content
            }
        }

        var added = 0
        var updated = 0

        database.inTransaction {
            let folderIdMap = mapFolders(rows.folders, placement: placement)
            let localTags = Dictionary(uniqueKeysWithValues: database.getAllTags().map { ($0.name, $0) })
            var tagIdMap: [Int64: Int64] = [:]
            for tag in rows.tags {
                if let existing = localTags[tag.name] {
                    tagIdMap[tag.id] = existing.id
                } else {
                    var newTag = tag
                    newTag.id = 0
                    tagIdMap[tag.id] = database.saveTag(newTag)
                }
            }

            for remote in itemsToApply {
                let local = matcher.match(remote.identity)
                var merged = remote
                merged.id = local?.id ?? 0
                merged.folderId = remote.folderId.flatMap { folderIdMap[$0] }

                let mappedTags = (remoteTagIdsByItem[remote.id] ?? []).compactMap { tagIdMap[$0] }
                let savedId = database.saveItemWithTags(merged, tagIds: mappedTags)
                if local != nil {
                    updated += 1
                } else {
                    added += 1
                }

                if var content = remoteContents[remote.id], let mergedUrl = merged.contentUrl {
                    content.itemId = savedId
                    content.sourceKey = mergedUrl
                    database.upsertItemContent(content)
                }
            }
        }

        return Result(added: added, updated: updated)
    }

    private func mapFolders(_ remoteFolders: [Folder], placement: FolderPlacement) -> [Int64: Int64] {
        let localTree = FolderTree(folders: database.getAllFolders())
        let remoteTree = FolderTree(folders: remoteFolders)
        var folderIdMap: [Int64: Int64] = [:]

        switch placement {
        case .byPath:
            var localByPath: [[String]: Int64] = [:]
            for entry in localTree.entries {
                localByPath[localTree.pathOf(entry.folder.id)] = entry.folder.id
            }
            for entry in remoteTree.entries {
                let path = remoteTree.pathOf(entry.folder.id)
                if let existingId = localByPath[path] {
                    folderIdMap[entry.folder.id] = existingId
                } else {
                    var newFolder = entry.folder
                    newFolder.id = 0
                    newFolder.parentId = entry.folder.parentId.flatMap { folderIdMap[$0] }
                    let createdId = database.saveFolder(newFolder)
                    localByPath[path] = createdId
                    folderIdMap[entry.folder.id] = createdId
                }
            }

        case .intoFolder(let remoteRootId, let localRootId):
            folderIdMap[remoteRootId] = localRootId
            let localRootPath = localTree.pathOf(localRootId)
            var localBySubpath: [[String]: Int64] = [:]
            for entry in localTree.entries {
                let path = localTree.pathOf(entry.folder.id)
                if path.count > localRootPath.count && Array(path.prefix(localRootPath.count)) == localRootPath {
                    localBySubpath[Array(path.dropFirst(localRootPath.count))] = entry.folder.id
                }
            }
            let remoteRootPath = remoteTree.pathOf(remoteRootId)
            for entry in remoteTree.entries {
                let path = remoteTree.pathOf(entry.folder.id)
                guard path.count > remoteRootPath.count && Array(path.prefix(remoteRootPath.count)) == remoteRootPath else {
                    continue
                }
                let subpath = Array(path.dropFirst(remoteRootPath.count))
                if let existingId = localBySubpath[subpath] {
                    folderIdMap[entry.folder.id] = existingId
                } else {
                    var newFolder = entry.folder
                    newFolder.id = 0
                    newFolder.parentId = entry.folder.parentId.flatMap { folderIdMap[$0] }
                    let createdId = database.saveFolder(newFolder)
                    localBySubpath[subpath] = createdId
                    folderIdMap[entry.folder.id] = createdId
                }
            }
        }
        return folderIdMap
    }
}

// MARK: - ShareSelection & SharePackage (.paperclip) & HtmlPage

enum ShareSelection {
    static var deviceName: String {
        UIDevice.current.name
    }

    static func ofItems(database: PaperclipDatabase = .shared, itemIds: Set<Int64>, includePrivate: Bool) -> ArchiveRows {
        let items = database.getAllItems()
            .filter { itemIds.contains($0.id) && $0.deletedAt == nil && (!($0.isPrivate) || includePrivate) }
            .map { var c = $0; c.folderId = nil; return c }
        return withTagsAndContent(database: database, itemIds: Set(items.map(\.id)), folders: [], items: items)
    }

    static func ofFolder(database: PaperclipDatabase = .shared, folderId: Int64, includeTrashed: Bool = false) -> ArchiveRows {
        let allFolders = database.getAllFolders()
        let ids = FolderTree(folders: allFolders).withDescendants(folderId)
        let folders = allFolders.filter { ids.contains($0.id) }.map { folder -> Folder in
            if folder.id == folderId {
                var root = folder
                root.parentId = nil
                return root
            }
            return folder
        }
        let items = database.getAllItems().filter {
            guard let fid = $0.folderId else { return false }
            return ids.contains(fid) && !$0.isPrivate && (includeTrashed || $0.deletedAt == nil)
        }
        return withTagsAndContent(database: database, itemIds: Set(items.map(\.id)), folders: folders, items: items)
    }

    private static func withTagsAndContent(
        database: PaperclipDatabase,
        itemIds: Set<Int64>,
        folders: [Folder],
        items: [ArchiveItem]
    ) -> ArchiveRows {
        let crossRefs = database.getAllCrossRefs().filter { itemIds.contains($0.itemId) }
        let tagIds = Set(crossRefs.map(\.tagId))
        let tags = database.getAllTags().filter { tagIds.contains($0.id) }
        let contents = database.getAllItemContents().filter { itemIds.contains($0.itemId) && $0.indexedAt != nil }
        return ArchiveRows(folders: folders, tags: tags, items: items, crossRefs: crossRefs, contents: contents)
    }
}

enum SharePackage {
    static let fileExtension = ".paperclip"
    static let dataEntry = "paperclip_share.json"
    private static let mediaPrefix = "media/"

    struct PackageData: Codable {
        var version: Int = 1
        var title: String
        var sender: String?
        var folders: [Folder]
        var tags: [Tag]
        var items: [ArchiveItem]
        var crossRefs: [ItemTagCrossRef]
        var contents: [ItemContent]?
    }

    static func writePackage(rows: ArchiveRows, title: String) throws -> URL {
        let pkg = PackageData(
            version: 1,
            title: title,
            sender: ShareSelection.deviceName,
            folders: rows.folders,
            tags: rows.tags,
            items: rows.items,
            crossRefs: rows.crossRefs,
            contents: rows.contents
        )
        let jsonData = try JSONEncoder().encode(pkg)
        var entries: [ZipEntryData] = [ZipEntryData(name: dataEntry, data: jsonData)]

        var addedNames: Set<String> = []
        for item in rows.items {
            for rawPath in [item.contentUrl, item.previewImageUrl].compactMap({ $0 }) {
                if let url = FileStorageManager.shared.resolveMediaFile(rawPath),
                   FileManager.default.fileExists(atPath: url.path),
                   addedNames.insert(url.lastPathComponent).inserted,
                   let data = try? Data(contentsOf: url) {
                    entries.append(ZipEntryData(name: "\(mediaPrefix)\(url.lastPathComponent)", data: data))
                }
            }
        }

        let zipData = ZipArchive.createZip(entries: entries)
        let outDir = FileManager.default.temporaryDirectory
        let safeTitle = safeFileName(title)
        let fileUrl = outDir.appendingPathComponent("\(safeTitle)\(fileExtension)")
        try zipData.write(to: fileUrl, options: .atomic)
        return fileUrl
    }

    static func importPackage(from url: URL, targetFolderId: Int64? = nil) throws -> (title: String, sender: String?, result: ArchiveMerger.Result) {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        let archiveData = try Data(contentsOf: url)
        let entries = try ZipArchive.readZip(archiveData)
        var pkgData: PackageData?

        for entry in entries {
            if entry.name == dataEntry {
                pkgData = try JSONDecoder().decode(PackageData.self, from: entry.data)
            } else if entry.name.hasPrefix(mediaPrefix) {
                let fileName = (entry.name as NSString).lastPathComponent
                if !fileName.isEmpty {
                    _ = try? FileStorageManager.shared.saveMediaData(entry.data, preferredFileName: fileName)
                }
            }
        }

        guard let received = pkgData else {
            throw NSError(domain: "Paperclip", code: 400, userInfo: [NSLocalizedDescriptionKey: "Non è un pacchetto .paperclip valido"])
        }

        var items = received.items
        if let targetId = targetFolderId, received.folders.isEmpty {
            items = items.map { var c = $0; c.folderId = targetId; return c }
        }

        let rows = ArchiveRows(
            folders: received.folders,
            tags: received.tags,
            items: items,
            crossRefs: received.crossRefs,
            contents: received.contents
        )
        let placement: ArchiveMerger.FolderPlacement
        if let targetId = targetFolderId, let rootFolder = received.folders.first(where: { $0.parentId == nil }) {
            placement = .intoFolder(remoteRootId: rootFolder.id, localRootId: targetId)
        } else {
            placement = .byPath
        }
        let res = ArchiveMerger.init().merge(rows: rows, placement: placement) { path in
            guard let path = path, !path.isEmpty else { return path }
            if path.hasPrefix("http://") || path.hasPrefix("https://") { return path }
            let name = (path as NSString).lastPathComponent
            return FileStorageManager.shared.mediaDirectory.appendingPathComponent(name).path
        }
        return (received.title, received.sender, res)
    }

    static func writeItemPackage(item: ArchiveItem) -> URL? {
        let rows = ShareSelection.ofItems(itemIds: [item.id], includePrivate: true)
        return try? writePackage(rows: rows, title: item.title.isEmpty ? item.itemType.label : item.title)
    }

    static func writeItemHtml(item: ArchiveItem) -> URL? {
        let rows = ShareSelection.ofItems(itemIds: [item.id], includePrivate: true)
        return try? writeHtmlPage(rows: rows, title: item.title.isEmpty ? item.itemType.label : item.title)
    }

    static func writeFolderPackage(folder: Folder) -> URL? {
        let rows = ShareSelection.ofFolder(folderId: folder.id)
        return try? writePackage(rows: rows, title: folder.name)
    }

    static func writeFolderHtml(folder: Folder) -> URL? {
        let rows = ShareSelection.ofFolder(folderId: folder.id)
        return try? writeHtmlPage(rows: rows, title: folder.name)
    }

    static func writeHtmlPage(rows: ArchiveRows, title: String) throws -> URL {
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "it_IT")
        dateFormatter.dateFormat = "d MMMM yyyy"

        let tagsById = Dictionary(uniqueKeysWithValues: rows.tags.map { ($0.id, $0.name) })
        var tagsByItem: [Int64: [String]] = [:]
        for ref in rows.crossRefs {
            if let name = tagsById[ref.tagId] {
                tagsByItem[ref.itemId, default: []].append(name)
            }
        }
        let contentsById = Dictionary(uniqueKeysWithValues: (rows.contents ?? []).map { ($0.itemId, $0) })

        var body = "<h1>\(RichText.htmlEscape(title))</h1>\n"
        for item in rows.items {
            let itemTags = (tagsByItem[item.id] ?? []).sorted()
            let dateStr = dateFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(item.createdAt) / 1000.0))
            body += "<article>\n"
            body += "<h2>\(RichText.htmlEscape(item.title))</h2>\n"
            body += "<p class=\"meta\">\(item.itemType.label) · \(dateStr)"
            for t in itemTags {
                body += " <span class=\"tag\">#\(RichText.htmlEscape(t))</span>"
            }
            body += "</p>\n"

            if item.itemType == .LINK, let u = item.contentUrl, !u.isEmpty {
                body += "<p class=\"link\"><a href=\"\(RichText.htmlEscape(u))\">\(RichText.htmlEscape(u))</a></p>\n"
            } else if item.itemType == .PHOTO || item.itemType == .DRAWING,
                      let fileUrl = FileStorageManager.shared.resolveMediaFile(item.contentUrl),
                      let imgData = try? Data(contentsOf: fileUrl),
                      imgData.count < 10 * 1024 * 1024 {
                body += "<img src=\"data:image/jpeg;base64,\(imgData.base64EncodedString())\" alt=\"\">\n"
            } else if item.itemType == .CHECKLIST {
                body += "<ul class=\"checklist\">\n"
                for c in ChecklistItem.fromJson(item.checklistJson) {
                    let cls = c.isChecked ? "done" : "todo"
                    let box = c.isChecked ? "☑ " : "☐ "
                    body += "<li class=\"\(cls)\">\(box)\(RichText.htmlEscape(c.text))</li>\n"
                }
                body += "</ul>\n"
            }

            if let desc = item.description, !desc.isEmpty {
                body += "<div class=\"text\">\(RichText.toHtml(desc))</div>\n"
            }
            if let extracted = contentsById[item.id]?.text, !extracted.isEmpty {
                body += "<details><summary>Testo / Copia salvata</summary><p>\(RichText.htmlEscape(extracted))</p></details>\n"
            }
            body += "</article>\n"
        }

        let html = """
        <!DOCTYPE html>
        <html lang="it">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(RichText.htmlEscape(title))</title>
        <style>
            :root { --bg: #FBFAF8; --fg: #1D1B19; --fg2: #6B6560; --line: #E4DFD9; --accent: #3A5BA9; }
            @media (prefers-color-scheme: dark) {
                :root { --bg: #141312; --fg: #ECE7E2; --fg2: #A29B94; --line: #2E2B28; --accent: #9DB5F0; }
            }
            html { background: var(--bg); }
            body { margin: 0 auto; max-width: 720px; padding: 32px 20px 64px; color: var(--fg);
                   font: 17px/1.6 -apple-system, system-ui, sans-serif; word-wrap: break-word; }
            article { border-top: 1px solid var(--line); padding: 24px 0; }
            .meta { color: var(--fg2); font-size: .85em; margin: 0 0 16px; }
            .tag, a, summary { color: var(--accent); }
            img { display: block; max-width: 100%; height: auto; border-radius: 12px; margin: 12px 0; }
            .checklist { list-style: none; padding: 0; }
            .checklist .done { color: var(--fg2); text-decoration: line-through; }
            footer { margin-top: 48px; color: var(--fg2); font-size: .8em; }
        </style>
        </head>
        <body>
        \(body)
        <footer>Condiviso da Paperclip · \(dateFormatter.string(from: Date()))</footer>
        </body>
        </html>
        """

        let fileUrl = FileManager.default.temporaryDirectory.appendingPathComponent("\(safeFileName(title)).html")
        try html.data(using: .utf8)?.write(to: fileUrl, options: .atomic)
        return fileUrl
    }

    static func safeFileName(_ title: String) -> String {
        let invalid = CharacterSet(charactersIn: "\\/:*?\"<>|\n\r\t")
        let cleaned = title.components(separatedBy: invalid).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = String(cleaned.prefix(60))
        return prefix.isEmpty ? "Paperclip" : prefix
    }
}

// MARK: - TrustedDevices (ECDH P-256 Pairing) & SharedFolders (HMAC-SHA256)

final class TrustedDevices: ObservableObject {
    static let shared = TrustedDevices()

    struct Device: Codable, Identifiable, Equatable {
        var deviceId: String
        var name: String
        var secret: String
        var pairedAt: Int64
        var id: String { deviceId }
    }

    @Published private(set) var devices: [Device] = []
    private let key = "paperclip_trusted_devices"

    private init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([Device].self, from: data) {
            devices = decoded
        }
    }

    func byId(_ deviceId: String?) -> Device? {
        guard let deviceId = deviceId else { return nil }
        return devices.first { $0.deviceId == deviceId }
    }

    func add(_ device: Device) {
        devices.removeAll { $0.deviceId == device.deviceId }
        devices.append(device)
        persist()
    }

    func remove(_ deviceId: String) {
        devices.removeAll { $0.deviceId == deviceId }
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(devices) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    /// ECDH P-256 Pairing 100% compatible with Android's `TrustedDevices.Pairing` (secp256r1 X.509 DER Base64).
    final class Pairing {
        private let privateKey = P256.KeyAgreement.PrivateKey()

        var publicKey: String {
            privateKey.publicKey.derRepresentation.base64EncodedString()
        }

        func derive(peerPublicKey: String, requesterKey: String, responderKey: String) throws -> (secret: String, code: String) {
            guard let peerDer = Data(base64Encoded: peerPublicKey) else {
                throw NSError(domain: "PaperclipPairing", code: 1, userInfo: [NSLocalizedDescriptionKey: "Chiave pubblica peer non valida"])
            }
            let peerPub = try P256.KeyAgreement.PublicKey(derRepresentation: peerDer)
            let sharedSecret = try privateKey.sharedSecretFromKeyAgreement(with: peerPub)
            let sharedBytes = sharedSecret.withUnsafeBytes { Data($0) }

            let transcript = Data("\(requesterKey)|\(responderKey)".utf8)

            var hasher = SHA256()
            hasher.update(data: Data("paperclip-pair-key".utf8))
            hasher.update(data: sharedBytes)
            hasher.update(data: transcript)
            let secretDigest = hasher.finalize()
            let secretHex = secretDigest.map { String(format: "%02x", $0) }.joined()

            let codeDigest = Array(SHA256.hash(data: transcript))
            let topUInt32 = (UInt32(codeDigest[0]) << 24) |
                            (UInt32(codeDigest[1]) << 16) |
                            (UInt32(codeDigest[2]) << 8) |
                            UInt32(codeDigest[3])
            let code = topUInt32 % 1_000_000
            return (secretHex, String(format: "%06d", code))
        }
    }
}

final class SharedFolders: ObservableObject {
    static let shared = SharedFolders()

    struct Partner: Codable, Equatable, Identifiable {
        var deviceId: String
        var name: String
        var secret: String
        var lastSyncAt: Int64? = nil
        var id: String { deviceId }
    }

    struct Share: Codable, Equatable, Identifiable {
        var id: String
        var folderId: Int64
        var partners: [Partner]
    }

    @Published private(set) var shares: [Share] = []
    private let key = "paperclip_shared_folders"

    private init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([Share].self, from: data) {
            shares = decoded
        }
    }

    func byId(_ shareId: String) -> Share? {
        shares.first { $0.id == shareId }
    }

    func forFolder(_ folderId: Int64) -> Share? {
        shares.first { $0.folderId == folderId }
    }

    func partnerIds() -> Set<String> {
        Set(shares.flatMap { $0.partners.map(\.deviceId) })
    }

    @discardableResult
    func addPartner(folderId: Int64, partner: Partner, shareId: String? = nil) -> String {
        let id = forFolder(folderId)?.id ?? shareId ?? UUID().uuidString
        let existing = shares.first { $0.id == id }
        let partners = (existing?.partners ?? []).filter { $0.deviceId != partner.deviceId } + [partner]
        shares.removeAll { $0.id == id }
        shares.append(Share(id: id, folderId: folderId, partners: partners))
        persist()
        return id
    }

    func removePartner(shareId: String, deviceId: String) {
        shares = shares.compactMap { share in
            guard share.id == shareId else { return share }
            let remaining = share.partners.filter { $0.deviceId != deviceId }
            return remaining.isEmpty ? nil : Share(id: share.id, folderId: share.folderId, partners: remaining)
        }
        persist()
    }

    func markSynced(shareId: String, deviceId: String) {
        let now = ArchiveItem.nowMillis()
        shares = shares.map { share in
            guard share.id == shareId else { return share }
            let updatedPartners = share.partners.map { p -> Partner in
                guard p.deviceId == deviceId else { return p }
                var copy = p
                copy.lastSyncAt = now
                return copy
            }
            return Share(id: share.id, folderId: share.folderId, partners: updatedPartners)
        }
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(shares) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    static func newSecret() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// HMAC-SHA256 signature matching Android's `SharedFolders.sign(secret, message)`.
    static func sign(secret: String, message: String) -> String {
        var keyBytes: [UInt8] = []
        var idx = secret.startIndex
        while idx < secret.endIndex {
            let next = secret.index(idx, offsetBy: 2, limitedBy: secret.endIndex) ?? secret.endIndex
            if let b = UInt8(secret[idx..<next], radix: 16) {
                keyBytes.append(b)
            }
            idx = next
        }
        let symKey = SymmetricKey(data: Data(keyBytes))
        let mac = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: symKey)
        return mac.map { String(format: "%02x", $0) }.joined()
    }
}
