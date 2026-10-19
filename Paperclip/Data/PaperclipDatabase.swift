import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class PaperclipDatabase {
    static let shared = PaperclipDatabase()

    private var db: OpaquePointer?
    private let lock = NSRecursiveLock()
    let dbPath: String

    init(customPath: String? = nil) {
        if let customPath = customPath {
            self.dbPath = customPath
        } else {
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            self.dbPath = docs.appendingPathComponent("paperclip_database.sqlite").path
        }
        openAndMigrate()
    }

    deinit {
        if let db = db {
            sqlite3_close(db)
        }
    }

    private func openAndMigrate() {
        lock.lock()
        defer { lock.unlock() }

        if sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) != SQLITE_OK {
            AppLogger.shared.error("Database", "Impossibile aprire SQLite a \(dbPath)")
            return
        }

        exec("PRAGMA foreign_keys = ON;")

        // Exact Room v6 schema from PaperclipDatabase.kt
        exec("""
        CREATE TABLE IF NOT EXISTS folders (
            id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
            name TEXT NOT NULL,
            colorHex TEXT NOT NULL DEFAULT '#6200EE',
            createdAt INTEGER NOT NULL,
            parentId INTEGER
        );
        """)

        exec("""
        CREATE TABLE IF NOT EXISTS tags (
            id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
            name TEXT NOT NULL,
            colorHex TEXT NOT NULL DEFAULT '#03DAC6'
        );
        """)

        exec("""
        CREATE TABLE IF NOT EXISTS archive_items (
            id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
            title TEXT NOT NULL,
            description TEXT,
            itemType TEXT NOT NULL,
            contentUrl TEXT,
            previewImageUrl TEXT,
            folderId INTEGER,
            audioDurationMs INTEGER,
            checklistJson TEXT,
            highlightsJson TEXT,
            reminderMinutes INTEGER,
            reminderDays INTEGER NOT NULL DEFAULT 0,
            createdAt INTEGER NOT NULL,
            updatedAt INTEGER NOT NULL,
            isPinned INTEGER NOT NULL DEFAULT 0,
            isArchived INTEGER NOT NULL DEFAULT 0,
            deletedAt INTEGER,
            readAt INTEGER,
            isPrivate INTEGER NOT NULL DEFAULT 0,
            FOREIGN KEY(folderId) REFERENCES folders(id) ON UPDATE NO ACTION ON DELETE SET NULL
        );
        """)

        exec("CREATE INDEX IF NOT EXISTS index_archive_items_folderId ON archive_items(folderId);")

        exec("""
        CREATE TABLE IF NOT EXISTS item_tag_cross_ref (
            itemId INTEGER NOT NULL,
            tagId INTEGER NOT NULL,
            PRIMARY KEY(itemId, tagId),
            FOREIGN KEY(itemId) REFERENCES archive_items(id) ON UPDATE NO ACTION ON DELETE CASCADE,
            FOREIGN KEY(tagId) REFERENCES tags(id) ON UPDATE NO ACTION ON DELETE CASCADE
        );
        """)

        exec("CREATE INDEX IF NOT EXISTS index_item_tag_cross_ref_itemId ON item_tag_cross_ref(itemId);")
        exec("CREATE INDEX IF NOT EXISTS index_item_tag_cross_ref_tagId ON item_tag_cross_ref(tagId);")

        exec("""
        CREATE TABLE IF NOT EXISTS item_content (
            itemId INTEGER NOT NULL PRIMARY KEY,
            sourceKey TEXT NOT NULL,
            text TEXT,
            articleJson TEXT,
            indexedAt INTEGER,
            attempts INTEGER NOT NULL DEFAULT 0,
            attemptedAt INTEGER NOT NULL DEFAULT 0,
            FOREIGN KEY(itemId) REFERENCES archive_items(id) ON UPDATE NO ACTION ON DELETE CASCADE
        );
        """)
    }

    @discardableResult
    private func exec(_ sql: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        var errMsg: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &errMsg)
        if rc != SQLITE_OK {
            let msg = errMsg.map { String(cString: $0) } ?? "SQLite error \(rc)"
            sqlite3_free(errMsg)
            AppLogger.shared.error("Database", "Errore SQL: \(msg)")
            return false
        }
        return true
    }

    func inTransaction(_ block: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        exec("BEGIN TRANSACTION;")
        block()
        exec("COMMIT;")
    }

    // MARK: - Folders

    func getAllFolders() -> [Folder] {
        lock.lock()
        defer { lock.unlock() }
        var result: [Folder] = []
        let sql = "SELECT id, name, colorHex, createdAt, parentId FROM folders ORDER BY name ASC;"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = sqlite3_column_int64(stmt, 0)
                let name = columnString(stmt, 1) ?? ""
                let colorHex = columnString(stmt, 2) ?? "#6200EE"
                let createdAt = sqlite3_column_int64(stmt, 3)
                let parentId: Int64? = sqlite3_column_type(stmt, 4) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, 4)
                result.append(Folder(id: id, name: name, colorHex: colorHex, createdAt: createdAt, parentId: parentId))
            }
        }
        sqlite3_finalize(stmt)
        return result
    }

    @discardableResult
    func saveFolder(_ folder: Folder) -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        if folder.id == 0 {
            let sql = "INSERT INTO folders (name, colorHex, createdAt, parentId) VALUES (?, ?, ?, ?);"
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                bindString(stmt, 1, folder.name)
                bindString(stmt, 2, folder.colorHex)
                sqlite3_bind_int64(stmt, 3, folder.createdAt)
                bindOptionalInt64(stmt, 4, folder.parentId)
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
            return sqlite3_last_insert_rowid(db)
        } else {
            let sql = "INSERT OR REPLACE INTO folders (id, name, colorHex, createdAt, parentId) VALUES (?, ?, ?, ?, ?);"
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_int64(stmt, 1, folder.id)
                bindString(stmt, 2, folder.name)
                bindString(stmt, 3, folder.colorHex)
                sqlite3_bind_int64(stmt, 4, folder.createdAt)
                bindOptionalInt64(stmt, 5, folder.parentId)
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
            return folder.id
        }
    }

    func deleteFolder(_ folder: Folder) {
        inTransaction {
            let now = ArchiveItem.nowMillis()
            var stmt1: OpaquePointer?
            if sqlite3_prepare_v2(db, "UPDATE folders SET parentId = ? WHERE parentId = ?;", -1, &stmt1, nil) == SQLITE_OK {
                bindOptionalInt64(stmt1, 1, folder.parentId)
                sqlite3_bind_int64(stmt1, 2, folder.id)
                sqlite3_step(stmt1)
            }
            sqlite3_finalize(stmt1)

            var stmt2: OpaquePointer?
            if sqlite3_prepare_v2(db, "UPDATE archive_items SET folderId = ?, updatedAt = ? WHERE folderId = ?;", -1, &stmt2, nil) == SQLITE_OK {
                bindOptionalInt64(stmt2, 1, folder.parentId)
                sqlite3_bind_int64(stmt2, 2, now)
                sqlite3_bind_int64(stmt2, 3, folder.id)
                sqlite3_step(stmt2)
            }
            sqlite3_finalize(stmt2)

            var stmt3: OpaquePointer?
            if sqlite3_prepare_v2(db, "DELETE FROM folders WHERE id = ?;", -1, &stmt3, nil) == SQLITE_OK {
                sqlite3_bind_int64(stmt3, 1, folder.id)
                sqlite3_step(stmt3)
            }
            sqlite3_finalize(stmt3)
        }
    }

    // MARK: - Tags

    func getAllTags() -> [Tag] {
        lock.lock()
        defer { lock.unlock() }
        var result: [Tag] = []
        let sql = "SELECT id, name, colorHex FROM tags ORDER BY name ASC;"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = sqlite3_column_int64(stmt, 0)
                let name = columnString(stmt, 1) ?? ""
                let colorHex = columnString(stmt, 2) ?? "#03DAC6"
                result.append(Tag(id: id, name: name, colorHex: colorHex))
            }
        }
        sqlite3_finalize(stmt)
        return result
    }

    @discardableResult
    func saveTag(_ tag: Tag) -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        if tag.id == 0 {
            let sql = "INSERT INTO tags (name, colorHex) VALUES (?, ?);"
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                bindString(stmt, 1, tag.name)
                bindString(stmt, 2, tag.colorHex)
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
            return sqlite3_last_insert_rowid(db)
        } else {
            let sql = "INSERT OR REPLACE INTO tags (id, name, colorHex) VALUES (?, ?, ?);"
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_int64(stmt, 1, tag.id)
                bindString(stmt, 2, tag.name)
                bindString(stmt, 3, tag.colorHex)
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
            return tag.id
        }
    }

    func deleteTag(_ tag: Tag) {
        lock.lock()
        defer { lock.unlock() }
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "DELETE FROM tags WHERE id = ?;", -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_int64(stmt, 1, tag.id)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
    }

    // MARK: - CrossRefs & ItemContent

    func getAllCrossRefs() -> [ItemTagCrossRef] {
        lock.lock()
        defer { lock.unlock() }
        var result: [ItemTagCrossRef] = []
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT itemId, tagId FROM item_tag_cross_ref;", -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                result.append(ItemTagCrossRef(
                    itemId: sqlite3_column_int64(stmt, 0),
                    tagId: sqlite3_column_int64(stmt, 1)
                ))
            }
        }
        sqlite3_finalize(stmt)
        return result
    }

    func insertCrossRef(_ ref: ItemTagCrossRef) {
        lock.lock()
        defer { lock.unlock() }
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO item_tag_cross_ref (itemId, tagId) VALUES (?, ?);", -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_int64(stmt, 1, ref.itemId)
            sqlite3_bind_int64(stmt, 2, ref.tagId)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
    }

    func getAllItemContents() -> [ItemContent] {
        lock.lock()
        defer { lock.unlock() }
        var result: [ItemContent] = []
        let sql = "SELECT itemId, sourceKey, text, articleJson, indexedAt, attempts, attemptedAt FROM item_content;"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                result.append(ItemContent(
                    itemId: sqlite3_column_int64(stmt, 0),
                    sourceKey: columnString(stmt, 1) ?? "",
                    text: columnString(stmt, 2),
                    articleJson: columnString(stmt, 3),
                    indexedAt: columnOptionalInt64(stmt, 4),
                    attempts: Int(sqlite3_column_int(stmt, 5)),
                    attemptedAt: sqlite3_column_int64(stmt, 6)
                ))
            }
        }
        sqlite3_finalize(stmt)
        return result
    }

    func upsertItemContent(_ content: ItemContent) {
        lock.lock()
        defer { lock.unlock() }
        let sql = """
        INSERT OR REPLACE INTO item_content (itemId, sourceKey, text, articleJson, indexedAt, attempts, attemptedAt)
        VALUES (?, ?, ?, ?, ?, ?, ?);
        """
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_int64(stmt, 1, content.itemId)
            bindString(stmt, 2, content.sourceKey)
            bindOptionalString(stmt, 3, content.text)
            bindOptionalString(stmt, 4, content.articleJson)
            bindOptionalInt64(stmt, 5, content.indexedAt)
            sqlite3_bind_int(stmt, 6, Int32(content.attempts))
            sqlite3_bind_int64(stmt, 7, content.attemptedAt)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
    }

    // MARK: - Items

    func getAllItems() -> [ArchiveItem] {
        lock.lock()
        defer { lock.unlock() }
        var result: [ArchiveItem] = []
        let sql = """
        SELECT id, title, description, itemType, contentUrl, previewImageUrl, folderId,
               audioDurationMs, checklistJson, highlightsJson, reminderMinutes, reminderDays,
               createdAt, updatedAt, isPinned, isArchived, deletedAt, readAt, isPrivate
        FROM archive_items
        ORDER BY isPinned DESC, createdAt DESC;
        """
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                result.append(readArchiveItem(stmt))
            }
        }
        sqlite3_finalize(stmt)
        return result
    }

    func getAllItemsWithDetails() -> [ArchiveItemWithDetails] {
        lock.lock()
        defer { lock.unlock() }
        let foldersById = Dictionary(uniqueKeysWithValues: getAllFolders().map { ($0.id, $0) })
        let tagsById = Dictionary(uniqueKeysWithValues: getAllTags().map { ($0.id, $0) })
        let refs = getAllCrossRefs()
        var tagsByItemId: [Int64: [Tag]] = [:]
        for ref in refs {
            if let tag = tagsById[ref.tagId] {
                tagsByItemId[ref.itemId, default: []].append(tag)
            }
        }
        return getAllItems().map { item in
            ArchiveItemWithDetails(
                item: item,
                folder: item.folderId.flatMap { foldersById[$0] },
                tags: tagsByItemId[item.id] ?? []
            )
        }
    }

    @discardableResult
    func insertOrReplaceItem(_ item: ArchiveItem) -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        if item.id == 0 {
            let sql = """
            INSERT INTO archive_items (
                title, description, itemType, contentUrl, previewImageUrl, folderId,
                audioDurationMs, checklistJson, highlightsJson, reminderMinutes, reminderDays,
                createdAt, updatedAt, isPinned, isArchived, deletedAt, readAt, isPrivate
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                bindItemFields(stmt, item: item, startIndex: 1)
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
            return sqlite3_last_insert_rowid(db)
        } else {
            let sql = """
            INSERT OR REPLACE INTO archive_items (
                id, title, description, itemType, contentUrl, previewImageUrl, folderId,
                audioDurationMs, checklistJson, highlightsJson, reminderMinutes, reminderDays,
                createdAt, updatedAt, isPinned, isArchived, deletedAt, readAt, isPrivate
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_int64(stmt, 1, item.id)
                bindItemFields(stmt, item: item, startIndex: 2)
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
            return item.id
        }
    }

    @discardableResult
    func saveItemWithTags(_ item: ArchiveItem, tagIds: [Int64]) -> Int64 {
        var savedId: Int64 = item.id
        inTransaction {
            savedId = insertOrReplaceItem(item)
            var delStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "DELETE FROM item_tag_cross_ref WHERE itemId = ?;", -1, &delStmt, nil) == SQLITE_OK {
                sqlite3_bind_int64(delStmt, 1, savedId)
                sqlite3_step(delStmt)
            }
            sqlite3_finalize(delStmt)

            for tagId in tagIds {
                insertCrossRef(ItemTagCrossRef(itemId: savedId, tagId: tagId))
            }
        }
        return savedId
    }

    func deleteItemPermanently(_ itemId: Int64) {
        lock.lock()
        defer { lock.unlock() }
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "DELETE FROM archive_items WHERE id = ?;", -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_int64(stmt, 1, itemId)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
    }

    private func bindItemFields(_ stmt: OpaquePointer?, item: ArchiveItem, startIndex: Int32) {
        bindString(stmt, startIndex + 0, item.title)
        bindOptionalString(stmt, startIndex + 1, item.description)
        bindString(stmt, startIndex + 2, item.itemType.rawValue)
        bindOptionalString(stmt, startIndex + 3, item.contentUrl)
        bindOptionalString(stmt, startIndex + 4, item.previewImageUrl)
        bindOptionalInt64(stmt, startIndex + 5, item.folderId)
        bindOptionalInt64(stmt, startIndex + 6, item.audioDurationMs)
        bindOptionalString(stmt, startIndex + 7, item.checklistJson)
        bindOptionalString(stmt, startIndex + 8, item.highlightsJson)
        if let mins = item.reminderMinutes {
            sqlite3_bind_int(stmt, startIndex + 9, Int32(mins))
        } else {
            sqlite3_bind_null(stmt, startIndex + 9)
        }
        sqlite3_bind_int(stmt, startIndex + 10, Int32(item.reminderDays))
        sqlite3_bind_int64(stmt, startIndex + 11, item.createdAt)
        sqlite3_bind_int64(stmt, startIndex + 12, item.updatedAt)
        sqlite3_bind_int(stmt, startIndex + 13, item.isPinned ? 1 : 0)
        sqlite3_bind_int(stmt, startIndex + 14, item.isArchived ? 1 : 0)
        bindOptionalInt64(stmt, startIndex + 15, item.deletedAt)
        bindOptionalInt64(stmt, startIndex + 16, item.readAt)
        sqlite3_bind_int(stmt, startIndex + 17, item.isPrivate ? 1 : 0)
    }

    private func readArchiveItem(_ stmt: OpaquePointer?) -> ArchiveItem {
        let id = sqlite3_column_int64(stmt, 0)
        let title = columnString(stmt, 1) ?? ""
        let description = columnString(stmt, 2)
        let typeRaw = columnString(stmt, 3) ?? "NOTE"
        let itemType = ItemType(rawValue: typeRaw) ?? .NOTE
        let contentUrl = columnString(stmt, 4)
        let previewImageUrl = columnString(stmt, 5)
        let folderId = columnOptionalInt64(stmt, 6)
        let audioDurationMs = columnOptionalInt64(stmt, 7)
        let checklistJson = columnString(stmt, 8)
        let highlightsJson = columnString(stmt, 9)
        let reminderMinutes: Int? = sqlite3_column_type(stmt, 10) == SQLITE_NULL ? nil : Int(sqlite3_column_int(stmt, 10))
        let reminderDays = Int(sqlite3_column_int(stmt, 11))
        let createdAt = sqlite3_column_int64(stmt, 12)
        let updatedAt = sqlite3_column_int64(stmt, 13)
        let isPinned = sqlite3_column_int(stmt, 14) != 0
        let isArchived = sqlite3_column_int(stmt, 15) != 0
        let deletedAt = columnOptionalInt64(stmt, 16)
        let readAt = columnOptionalInt64(stmt, 17)
        let isPrivate = sqlite3_column_int(stmt, 18) != 0

        return ArchiveItem(
            id: id,
            title: title,
            description: description,
            itemType: itemType,
            contentUrl: contentUrl,
            previewImageUrl: previewImageUrl,
            folderId: folderId,
            audioDurationMs: audioDurationMs,
            checklistJson: checklistJson,
            highlightsJson: highlightsJson,
            reminderMinutes: reminderMinutes,
            reminderDays: reminderDays,
            createdAt: createdAt,
            updatedAt: updatedAt,
            isPinned: isPinned,
            isArchived: isArchived,
            deletedAt: deletedAt,
            readAt: readAt,
            isPrivate: isPrivate
        )
    }

    // MARK: - SQLite Helpers

    private func columnString(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL,
              let cStr = sqlite3_column_text(stmt, index) else {
            return nil
        }
        return String(cString: cStr)
    }

    private func columnOptionalInt64(_ stmt: OpaquePointer?, _ index: Int32) -> Int64? {
        sqlite3_column_type(stmt, index) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, index)
    }

    private func bindString(_ stmt: OpaquePointer?, _ index: Int32, _ value: String) {
        sqlite3_bind_text(stmt, index, (value as NSString).utf8String, -1, SQLITE_TRANSIENT)
    }

    private func bindOptionalString(_ stmt: OpaquePointer?, _ index: Int32, _ value: String?) {
        if let value = value {
            bindString(stmt, index, value)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    private func bindOptionalInt64(_ stmt: OpaquePointer?, _ index: Int32, _ value: Int64?) {
        if let value = value {
            sqlite3_bind_int64(stmt, index, value)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }
}
