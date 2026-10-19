import Foundation

enum BackupImportResult: Equatable {
    case success(itemsCount: Int, foldersCount: Int, tagsCount: Int)
    case passwordNeeded
    case wrongPassword
    case failed(String)
}

final class BackupManager {
    static let shared = BackupManager()

    private static let dataEntry = "backup_data.json"
    private static let mediaPrefix = "media/"

    private let database = PaperclipDatabase.shared
    private let fileStorage = FileStorageManager.shared

    func createBackupData() throws -> Data {
        let payload = BackupPayload(
            folders: database.getAllFolders(),
            tags: database.getAllTags(),
            items: database.getAllItems(),
            crossRefs: database.getAllCrossRefs(),
            contents: database.getAllItemContents()
        )

        let encoder = JSONEncoder()
        let jsonBytes = try encoder.encode(payload)

        var entries: [ZipEntryData] = [
            ZipEntryData(name: Self.dataEntry, data: jsonBytes)
        ]

        for mediaUrl in fileStorage.listAllMediaFiles() {
            if let fileData = try? Data(contentsOf: mediaUrl) {
                entries.append(ZipEntryData(name: "\(Self.mediaPrefix)\(mediaUrl.lastPathComponent)", data: fileData))
            }
        }

        let zipData = ZipArchive.createZip(entries: entries)
        if let password = BackupPassword.get(), !password.isEmpty {
            AppLogger.shared.info("Backup", "Esportazione backup cifrato (PCLIPENC) con \(payload.items.count) elementi")
            return try BackupCrypto.encrypt(zipData, password: password)
        } else {
            AppLogger.shared.info("Backup", "Esportazione backup ZIP standard con \(payload.items.count) elementi")
            return zipData
        }
    }

    func isEncryptedBackup(at url: URL) -> Bool {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        guard let handle = try? FileHandle(forReadingFrom: url),
              let header = try? handle.read(upToCount: BackupCrypto.headerSize) else {
            return false
        }
        try? handle.close()
        return BackupCrypto.isEncrypted(header)
    }

    func importBackup(from url: URL, password: String? = nil) -> BackupImportResult {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        guard let rawData = try? Data(contentsOf: url) else {
            return .failed("Impossibile leggere il file selezionato")
        }

        let encrypted = BackupCrypto.isEncrypted(rawData)
        let zipData: Data

        if encrypted {
            let effectivePassword = password ?? BackupPassword.get()
            guard let pwd = effectivePassword, !pwd.isEmpty else {
                return .passwordNeeded
            }
            do {
                zipData = try BackupCrypto.decrypt(rawData, password: pwd)
            } catch BackupCryptoError.wrongPassword {
                if password == nil {
                    // Stored password didn't match this backup: ask the user
                    return .passwordNeeded
                }
                return .wrongPassword
            } catch {
                return .failed(error.localizedDescription)
            }
        } else {
            zipData = rawData
        }

        do {
            let entries = try ZipArchive.readZip(zipData)
            var payload: BackupPayload?

            for entry in entries {
                if entry.name == Self.dataEntry {
                    payload = try JSONDecoder().decode(BackupPayload.self, from: entry.data)
                } else if entry.name.hasPrefix(Self.mediaPrefix) {
                    let fileName = (entry.name as NSString).lastPathComponent
                    if !fileName.isEmpty {
                        _ = try? fileStorage.saveMediaData(entry.data, preferredFileName: fileName)
                    }
                }
            }

            guard let restored = payload else {
                return .failed("File backup_data.json non trovato nell'archivio")
            }

            database.inTransaction {
                for folder in restored.folders {
                    database.saveFolder(folder)
                }
                for tag in restored.tags {
                    database.saveTag(tag)
                }
                var restoredUrls: [Int64: String?] = [:]
                for var item in restored.items {
                    let localPath = fileStorage.rewriteBackupMediaPath(item.contentUrl)
                    item.contentUrl = localPath
                    database.insertOrReplaceItem(item)
                    restoredUrls[item.id] = localPath
                }
                for ref in restored.crossRefs {
                    database.insertCrossRef(ref)
                }
                for var content in restored.contents ?? [] {
                    if let maybeUrl = restoredUrls[content.itemId], let url = maybeUrl {
                        content.sourceKey = url
                        database.upsertItemContent(content)
                    }
                }
            }

            AppLogger.shared.info("Backup", "Ripristinati \(restored.items.count) elementi, \(restored.folders.count) cartelle, \(restored.tags.count) tag")
            return .success(
                itemsCount: restored.items.count,
                foldersCount: restored.folders.count,
                tagsCount: restored.tags.count
            )
        } catch {
            AppLogger.shared.error("Backup", "Errore importazione backup: \(error.localizedDescription)")
            return .failed(error.localizedDescription)
        }
    }
}
