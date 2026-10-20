import Foundation

// MARK: - ArchiveExporter

enum ArchiveExporter {

    struct Result {
        let count: Int
        let fileUrl: URL
    }

    static func suggestedName(prefix: String, ext: String) -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyyMMdd_HHmm"
        return "\(prefix)_\(fmt.string(from: Date())).\(ext)"
    }

    // MARK: - Markdown / Obsidian (.zip)

    static func writeMarkdownZip(db: PaperclipDatabase = .shared) throws -> Result {
        let rows = ArchiveRows.load(db: db).activeOnly()
        let tree = FolderTree(folders: rows.folders)
        let tagsById = Dictionary(uniqueKeysWithValues: rows.tags.map { ($0.id, $0) })
        var tagsByItem: [Int64: [Tag]] = [:]
        for ref in rows.crossRefs {
            if let tag = tagsById[ref.tagId] {
                tagsByItem[ref.itemId, default: []].append(tag)
            }
        }
        let contentByItem = Dictionary(uniqueKeysWithValues: (rows.contents ?? []).map { ($0.itemId, $0) })

        var usedPaths = Set<String>()
        var mediaFiles: [String: URL] = [:]
        var entries: [ZipEntryData] = []

        for item in rows.items {
            let folderSegments = item.folderId.map { tree.pathOf($0).map(safeSegment).filter { !$0.isEmpty } } ?? []
            let dirPrefix = folderSegments.isEmpty ? "" : folderSegments.joined(separator: "/") + "/"
            let baseName = safeSegment(item.title.isEmpty ? item.itemType.label : item.title)
            let entryPath = uniquePath(dir: dirPrefix, base: baseName.isEmpty ? "nota" : baseName, ext: "md", used: &usedPaths)
            let tags = tagsByItem[item.id] ?? []
            let content = contentByItem[item.id]

            var mediaRel: String?
            if ItemType.mediaTypes.contains(item.itemType),
               let fileUrl = FileStorageManager.shared.resolveMediaFile(item.contentUrl),
               FileManager.default.fileExists(atPath: fileUrl.path) {
                let fileName = fileUrl.lastPathComponent
                mediaFiles[fileName] = fileUrl
                let depth = folderSegments.count
                let up = String(repeating: "../", count: depth)
                mediaRel = "\(up)media/\(fileName)"
            }

            let md = buildMarkdown(
                item: item,
                folderPath: item.folderId.map { tree.pathOf($0) } ?? [],
                tags: tags,
                indexedText: content?.text,
                mediaRelativePath: mediaRel
            )
            if let data = md.data(using: .utf8) {
                entries.append(ZipEntryData(name: entryPath, data: data))
            }
        }

        for (name, fileUrl) in mediaFiles {
            if let data = try? Data(contentsOf: fileUrl) {
                entries.append(ZipEntryData(name: "media/\(name)", data: data))
            }
        }

        let zipData = ZipArchive.createZip(entries: entries)
        let outUrl = FileManager.default.temporaryDirectory.appendingPathComponent(suggestedName(prefix: "paperclip_markdown", ext: "zip"))
        try zipData.write(to: outUrl, options: .atomic)
        return Result(count: rows.items.count, fileUrl: outUrl)
    }

    private static func buildMarkdown(
        item: ArchiveItem,
        folderPath: [String],
        tags: [Tag],
        indexedText: String?,
        mediaRelativePath: String?
    ) -> String {
        let iso = DateFormatter()
        iso.locale = Locale(identifier: "en_US_POSIX")
        iso.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"

        var out: [String] = []
        out.append("---")
        out.append("title: \(yamlQuote(item.title))")
        out.append("type: \(item.itemType.rawValue.lowercased())")
        out.append("created: \(iso.string(from: Date(timeIntervalSince1970: Double(item.createdAt) / 1000.0)))")
        out.append("updated: \(iso.string(from: Date(timeIntervalSince1970: Double(item.updatedAt) / 1000.0)))")
        if !folderPath.isEmpty {
            out.append("folder: \(yamlQuote(folderPath.joined(separator: "/")))")
        }
        if item.isPinned { out.append("pinned: true") }
        if item.isArchived { out.append("archived: true") }
        if let readAt = item.readAt {
            out.append("read_at: \(iso.string(from: Date(timeIntervalSince1970: Double(readAt) / 1000.0)))")
        }
        if item.itemType == .LINK, let url = item.contentUrl, !url.isEmpty {
            out.append("url: \(yamlQuote(url))")
        }
        if !tags.isEmpty {
            out.append("tags:")
            for tag in tags {
                out.append("  - \(yamlQuote(tag.name))")
            }
        }
        out.append("---")
        out.append("")
        out.append("# \(item.title)")
        out.append("")

        if item.itemType == .LINK, let url = item.contentUrl, !url.isEmpty {
            out.append("[\(url)](\(url))")
            out.append("")
        }

        if let mediaRel = mediaRelativePath {
            switch item.itemType {
            case .PHOTO, .DRAWING:
                out.append("![\(item.title)](\(mediaRel))")
            default:
                out.append("[\(item.title)](\(mediaRel))")
            }
            out.append("")
        }

        if let desc = item.description?.trimmingCharacters(in: .whitespacesAndNewlines), !desc.isEmpty {
            out.append(RichText.toMarkdown(desc))
            out.append("")
        }

        if item.itemType == .CHECKLIST {
            let entries = ChecklistItem.fromJson(item.checklistJson)
            if !entries.isEmpty {
                for entry in entries {
                    let mark = entry.isChecked ? "x" : " "
                    out.append("- [\(mark)] \(RichText.toMarkdown(entry.text))")
                }
                out.append("")
            }
        }

        if item.itemType == .LINK {
            let highlights = ArticleHighlight.fromJson(item.highlightsJson)
            if !highlights.isEmpty {
                out.append("## Evidenziazioni")
                out.append("")
                for h in highlights {
                    out.append("> \(h.text.replacingOccurrences(of: "\n", with: "\n> "))")
                    if let note = h.note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
                        out.append("")
                        out.append("*\(note)*")
                    }
                    out.append("")
                }
            }
        } else if item.itemType == .PDF {
            let highlights = PdfHighlight.fromJson(item.highlightsJson).filter { !($0.text?.isEmpty ?? true) }
            if !highlights.isEmpty {
                out.append("## Evidenziazioni")
                out.append("")
                for h in highlights {
                    out.append("> \(h.text!.replacingOccurrences(of: "\n", with: "\n> ")) *(pag. \(h.page + 1))*")
                    out.append("")
                }
            }
        }

        if let indexed = indexedText?.trimmingCharacters(in: .whitespacesAndNewlines),
           !indexed.isEmpty,
           item.itemType != .NOTE {
            out.append("## Testo estratto")
            out.append("")
            out.append(indexed)
            out.append("")
        }

        return out.joined(separator: "\n")
    }

    // MARK: - Netscape Bookmarks (.html)

    static func writeBookmarksHtml(db: PaperclipDatabase = .shared) throws -> Result {
        let rows = ArchiveRows.load(db: db).activeOnly()
        let links = rows.items.filter { $0.itemType == .LINK && !($0.contentUrl?.isEmpty ?? true) }
        let tagsById = Dictionary(uniqueKeysWithValues: rows.tags.map { ($0.id, $0) })
        var tagsByItem: [Int64: [Tag]] = [:]
        for ref in rows.crossRefs {
            if let tag = tagsById[ref.tagId] {
                tagsByItem[ref.itemId, default: []].append(tag)
            }
        }
        let foldersByParent = Dictionary(grouping: rows.folders, by: { $0.parentId })
        let itemsByFolder = Dictionary(grouping: links, by: { $0.folderId })

        var out: [String] = []
        out.append("<!DOCTYPE NETSCAPE-Bookmark-file-1>")
        out.append("<!-- This is an automatically generated file. -->")
        out.append("<META HTTP-EQUIV=\"Content-Type\" CONTENT=\"text/html; charset=UTF-8\">")
        out.append("<TITLE>Bookmarks</TITLE>")
        out.append("<H1>Bookmarks</H1>")
        out.append("<DL><p>")

        func emitItem(_ item: ArchiveItem, indent: String) {
            let url = htmlAttr(item.contentUrl ?? "")
            let addDate = item.createdAt / 1000
            let tagList = (tagsByItem[item.id] ?? []).map { $0.name.replacingOccurrences(of: ",", with: " ") }.joined(separator: ",")
            let tagsAttr = tagList.isEmpty ? "" : " TAGS=\"\(htmlAttr(tagList))\""
            let title = htmlText(item.title.isEmpty ? (item.contentUrl ?? "") : item.title)
            out.append("\(indent)<DT><A HREF=\"\(url)\" ADD_DATE=\"\(addDate)\"\(tagsAttr)>\(title)</A>")
            let desc = RichText.toPlainString(item.description ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !desc.isEmpty {
                out.append("\(indent)<DD>\(htmlText(desc))")
            }
        }

        var visitedFolders = Set<Int64>()
        func emitFolder(_ folder: Folder, indent: String) {
            guard visitedFolders.insert(folder.id).inserted else { return }
            let addDate = folder.createdAt / 1000
            out.append("\(indent)<DT><H3 ADD_DATE=\"\(addDate)\">\(htmlText(folder.name))</H3>")
            out.append("\(indent)<DL><p>")
            for child in foldersByParent[folder.id] ?? [] {
                emitFolder(child, indent: indent + "    ")
            }
            for item in itemsByFolder[folder.id] ?? [] {
                emitItem(item, indent: indent + "    ")
            }
            out.append("\(indent)</DL><p>")
        }

        for root in foldersByParent[nil as Int64?] ?? [] {
            emitFolder(root, indent: "    ")
        }
        for item in itemsByFolder[nil as Int64?] ?? [] {
            emitItem(item, indent: "    ")
        }
        out.append("</DL><p>")

        let html = out.joined(separator: "\n")
        let outUrl = FileManager.default.temporaryDirectory.appendingPathComponent(suggestedName(prefix: "paperclip_bookmarks", ext: "html"))
        try html.data(using: .utf8)?.write(to: outUrl, options: .atomic)
        return Result(count: links.count, fileUrl: outUrl)
    }

    // MARK: - Readwise Highlights (.csv)

    static func writeReadwiseCsv(db: PaperclipDatabase = .shared) throws -> Result {
        let rows = ArchiveRows.load(db: db).activeOnly()
        var lines: [String] = ["Highlight,Title,Author,URL,Note,Location,Date"]
        let iso = DateFormatter()
        iso.locale = Locale(identifier: "en_US_POSIX")
        iso.timeZone = TimeZone(secondsFromGMT: 0)
        iso.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        var count = 0

        for item in rows.items {
            let title = item.title.isEmpty ? item.itemType.label : item.title
            let url = item.itemType == .LINK ? (item.contentUrl ?? "") : ""
            if item.itemType == .LINK {
                for h in ArticleHighlight.fromJson(item.highlightsJson) {
                    let row = [
                        h.text,
                        title,
                        "",
                        url,
                        h.note ?? "",
                        String(h.start),
                        iso.string(from: Date(timeIntervalSince1970: Double(h.createdAt) / 1000.0))
                    ].map(csvField).joined(separator: ",")
                    lines.append(row)
                    count += 1
                }
            } else if item.itemType == .PDF {
                for h in PdfHighlight.fromJson(item.highlightsJson) {
                    guard let text = h.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { continue }
                    let row = [
                        text,
                        title,
                        "",
                        "",
                        "",
                        String(h.page + 1),
                        iso.string(from: Date(timeIntervalSince1970: Double(h.createdAt) / 1000.0))
                    ].map(csvField).joined(separator: ",")
                    lines.append(row)
                    count += 1
                }
            }
        }

        let csv = lines.joined(separator: "\n") + "\n"
        let outUrl = FileManager.default.temporaryDirectory.appendingPathComponent(suggestedName(prefix: "paperclip_highlights", ext: "csv"))
        try csv.data(using: .utf8)?.write(to: outUrl, options: .atomic)
        return Result(count: count, fileUrl: outUrl)
    }

    // MARK: - Formatting Helpers

    private static func safeSegment(_ raw: String) -> String {
        let invalid = CharacterSet(charactersIn: "\\/:*?\"<>|\u{0000}")
        let cleaned = raw.unicodeScalars.map { invalid.contains($0) || $0.value < 32 ? "_" : Character($0) }
        let str = String(cleaned).trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        return String(str.prefix(80))
    }

    private static func uniquePath(dir: String, base: String, ext: String, used: inout Set<String>) -> String {
        var candidate = "\(dir)\(base).\(ext)"
        var n = 2
        while !used.insert(candidate.lowercased()).inserted {
            candidate = "\(dir)\(base) (\(n)).\(ext)"
            n += 1
        }
        return candidate
    }

    private static func yamlQuote(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "")
        return "\"\(escaped)\""
    }

    private static func csvField(_ value: String) -> String {
        let clean = value.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        if clean.contains(",") || clean.contains("\"") || clean.contains("\n") {
            return "\"\(clean.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        return clean
    }

    private static func htmlText(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func htmlAttr(_ value: String) -> String {
        htmlText(value).replacingOccurrences(of: "\"", with: "&quot;")
    }
}

// MARK: - ExternalImporter

enum ExternalImporter {

    struct Result {
        var imported: Int = 0
        var skipped: Int = 0
    }

    private static let tagPalette = [
        "#EF5350", "#EC407A", "#AB47BC", "#7E57C2",
        "#5C6BC0", "#29B6F6", "#26A69A", "#66BB6A",
        "#FFA726", "#8D6E63"
    ]

    static func importFromUrl(_ url: URL, db: PaperclipDatabase = .shared) throws -> Result {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        let name = url.lastPathComponent.lowercased()

        if data.count >= 4 && data[0] == 0x50 && data[1] == 0x4B && data[2] == 0x03 && data[3] == 0x04 {
            return try importKeepZip(data: data, db: db)
        }
        let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if name.hasSuffix(".json") || trimmed.hasPrefix("{") {
            let state = ImportState(db: db)
            return importKeepJsonObject(text: trimmed, mediaByName: [:], state: state) ? Result(imported: 1, skipped: 0) : Result(imported: 0, skipped: 1)
        }
        if name.hasSuffix(".csv") || (!trimmed.hasPrefix("<") && firstLineLooksLikeCsv(trimmed)) {
            return importPocketCsv(text: text, db: db)
        }
        return importBookmarksHtml(text: text, db: db)
    }

    // MARK: - Google Keep (.zip / .json)

    private static func importKeepZip(data: Data, db: PaperclipDatabase) throws -> Result {
        let entries = try ZipArchive.readZip(data)
        var jsonEntries: [String] = []
        var mediaByName: [String: URL] = [:]

        for entry in entries {
            let baseName = (entry.name as NSString).lastPathComponent
            guard !baseName.isEmpty else { continue }
            if baseName.lowercased().hasSuffix(".json") {
                if let str = String(data: entry.data, encoding: .utf8) {
                    jsonEntries.append(str)
                }
            } else if isMediaFilename(baseName) {
                let ext = (baseName as NSString).pathExtension.lowercased()
                let safeExt = ext.isEmpty ? "bin" : ext
                let fileName = "keep_\(ArchiveItem.nowMillis())_\(Int.random(in: 1000...9999)).\(safeExt)"
                if let savedPath = try? FileStorageManager.shared.saveMediaData(entry.data, preferredFileName: fileName) {
                    mediaByName[baseName.lowercased()] = URL(fileURLWithPath: savedPath)
                }
            }
        }

        let state = ImportState(db: db)
        var imported = 0
        var skipped = 0
        for raw in jsonEntries {
            if importKeepJsonObject(text: raw, mediaByName: mediaByName, state: state) {
                imported += 1
            } else {
                skipped += 1
            }
        }
        return Result(imported: imported, skipped: skipped)
    }

    private static func importKeepJsonObject(text: String, mediaByName: [String: URL], state: ImportState) -> Bool {
        guard let data = text.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return false
        }
        if (obj["isTrashed"] as? Bool) == true { return false }

        let rawTitle = (obj["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let textContent = (obj["textContent"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let createdUsec = (obj["createdTimestampUsec"] as? NSNumber)?.int64Value ?? 0
        let editedUsec = (obj["userEditedTimestampUsec"] as? NSNumber)?.int64Value ?? createdUsec
        let now = ArchiveItem.nowMillis()
        let createdAt = createdUsec > 0 ? createdUsec / 1000 : now
        let updatedAt = editedUsec > 0 ? editedUsec / 1000 : createdAt
        let isPinned = (obj["isPinned"] as? Bool) ?? false
        let isArchived = (obj["isArchived"] as? Bool) ?? false

        var checklist: [ChecklistItem] = []
        if let listArr = obj["listContent"] as? [[String: Any]] {
            for entry in listArr {
                let itemText = (entry["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !itemText.isEmpty {
                    let isChecked = (entry["isChecked"] as? Bool) ?? false
                    checklist.append(ChecklistItem(text: itemText, isChecked: isChecked))
                }
            }
        }

        var attachedFile: URL?
        var attachedMime = ""
        if let atts = obj["attachments"] as? [[String: Any]] {
            for att in atts {
                let path = ((att["filePath"] as? String) ?? "").components(separatedBy: "/").last?.lowercased() ?? ""
                if let found = mediaByName[path] {
                    attachedFile = found
                    attachedMime = ((att["mimetype"] as? String) ?? "").lowercased()
                    break
                }
            }
        }

        var annotationUrl: String?
        var annotationTitle: String?
        if let anns = obj["annotations"] as? [[String: Any]] {
            for ann in anns {
                let u = (ann["url"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !u.isEmpty {
                    annotationUrl = u
                    annotationTitle = (ann["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    break
                }
            }
        }

        let soloUrl = LinkUrls.extractFirstUrl(textContent)
        let isPureLink = soloUrl != nil && textContent == soloUrl && checklist.isEmpty && attachedFile == nil

        let itemType: ItemType
        var contentUrl: String?
        var description: String?
        var checklistJson: String?

        if let file = attachedFile {
            let type: ItemType
            if attachedMime.hasPrefix("image/") { type = .PHOTO }
            else if attachedMime.hasPrefix("video/") { type = .VIDEO }
            else if attachedMime.hasPrefix("audio/") { type = .AUDIO }
            else if attachedMime == "application/pdf" || file.pathExtension.lowercased() == "pdf" { type = .PDF }
            else { type = .PHOTO }
            itemType = type
            contentUrl = file.path
            description = textContent.isEmpty ? nil : textContent
        } else if !checklist.isEmpty {
            itemType = .CHECKLIST
            description = textContent.isEmpty ? nil : textContent
            checklistJson = ChecklistItem.toJson(checklist)
        } else if isPureLink, let u = soloUrl {
            itemType = .LINK
            contentUrl = u
        } else if let annUrl = annotationUrl, textContent.isEmpty {
            itemType = .LINK
            contentUrl = annUrl
        } else {
            itemType = .NOTE
            description = textContent.isEmpty ? nil : textContent
        }

        if itemType == .NOTE && rawTitle.isEmpty && (description?.isEmpty ?? true) {
            return false
        }
        if itemType == .LINK, let u = contentUrl, !state.claimUrl(u) {
            return false
        }

        let fallbackTitle = firstLine(textContent)
            ?? checklist.first?.text
            ?? annotationTitle
            ?? contentUrl
            ?? itemType.label
        let title = String((rawTitle.isEmpty ? fallbackTitle : rawTitle).prefix(200))

        var tagIds: [Int64] = []
        if let labels = obj["labels"] as? [[String: Any]] {
            for lbl in labels {
                let name = (lbl["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !name.isEmpty {
                    tagIds.append(state.getOrCreateTagId(name: name))
                }
            }
        }

        let item = ArchiveItem(
            title: title,
            description: description,
            itemType: itemType,
            contentUrl: contentUrl,
            checklistJson: checklistJson,
            createdAt: createdAt,
            updatedAt: updatedAt,
            isPinned: isPinned,
            isArchived: isArchived
        )
        state.insertItem(item, tagIds: tagIds)
        return true
    }

    private static func isMediaFilename(_ name: String) -> Bool {
        let lower = name.lowercased()
        let exts = [".jpg", ".jpeg", ".png", ".webp", ".gif", ".heic", ".mp4", ".mov", ".m4a", ".mp3", ".wav", ".aac", ".ogg", ".opus", ".3gp", ".amr", ".pdf"]
        return exts.contains { lower.hasSuffix($0) }
    }

    // MARK: - Pocket (.csv)

    private static func firstLineLooksLikeCsv(_ text: String) -> Bool {
        let line = text.lineSequence().first?.lowercased() ?? ""
        return line.contains("url") && line.contains(",")
    }

    private static func importPocketCsv(text: String, db: PaperclipDatabase) -> Result {
        let rows = parseCsv(text)
        guard !rows.isEmpty else { return Result() }
        let header = rows[0].map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        let hasHeader = header.contains("url")
        let urlCol = hasHeader ? (header.firstIndex(of: "url") ?? 0) : 0
        let titleCol = hasHeader ? header.firstIndex(of: "title") : (rows[0].count > 1 ? 1 : nil)
        let timeCol = hasHeader ? (header.firstIndex(of: "time_added") ?? header.firstIndex(of: "created")) : nil
        let tagsCol = hasHeader ? header.firstIndex(of: "tags") : nil
        let statusCol = hasHeader ? header.firstIndex(of: "status") : nil

        let state = ImportState(db: db)
        var imported = 0
        var skipped = 0
        let startRow = hasHeader ? 1 : 0

        for idx in startRow..<rows.count {
            let cols = rows[idx]
            let rawUrl = (urlCol < cols.count ? cols[urlCol] : "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard let normalized = LinkUrls.normalizeWebUrl(rawUrl) else {
                if !rawUrl.isEmpty { skipped += 1 }
                continue
            }
            if !state.claimUrl(normalized) {
                skipped += 1
                continue
            }
            let rawTitle = (titleCol != nil && titleCol! < cols.count ? cols[titleCol!] : "").trimmingCharacters(in: .whitespacesAndNewlines)
            let title = rawTitle.isEmpty || rawTitle == rawUrl ? (LinkUrls.defaultTitleForUrl(normalized) ?? normalized) : rawTitle
            let epochSec = timeCol != nil && timeCol! < cols.count ? Int64(cols[timeCol!].trimmingCharacters(in: .whitespacesAndNewlines)) : nil
            let createdAt = (epochSec ?? 0) > 0 ? epochSec! * 1000 : ArchiveItem.nowMillis()
            let status = statusCol != nil && statusCol! < cols.count ? cols[statusCol!].trimmingCharacters(in: .whitespacesAndNewlines).lowercased() : ""
            let isArchived = status == "archive" || status == "archived"

            let tagsRaw = tagsCol != nil && tagsCol! < cols.count ? cols[tagsCol!].trimmingCharacters(in: .whitespacesAndNewlines) : ""
            let tagIds = tagsRaw
                .components(separatedBy: CharacterSet(charactersIn: "|,"))
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .map { state.getOrCreateTagId(name: $0) }

            let item = ArchiveItem(
                title: String(title.prefix(200)),
                itemType: .LINK,
                contentUrl: normalized,
                createdAt: createdAt,
                updatedAt: createdAt,
                isArchived: isArchived,
                readAt: isArchived ? createdAt : nil
            )
            state.insertItem(item, tagIds: tagIds)
            imported += 1
        }
        return Result(imported: imported, skipped: skipped)
    }

    private static func parseCsv(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var currentRow: [String] = []
        var field = ""
        var inQuotes = false
        let chars = Array(text)
        var i = 0

        while i < chars.count {
            let c = chars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < chars.count && chars[i + 1] == "\"" {
                        field.append("\"")
                        i += 1
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(c)
                }
            } else {
                switch c {
                case "\"":
                    inQuotes = true
                case ",":
                    currentRow.append(field)
                    field = ""
                case "\r", "\n":
                    if c == "\r" && i + 1 < chars.count && chars[i + 1] == "\n" {
                        i += 1
                    }
                    currentRow.append(field)
                    field = ""
                    if currentRow.contains(where: { !$0.isEmpty }) {
                        rows.append(currentRow)
                    }
                    currentRow = []
                default:
                    field.append(c)
                }
            }
            i += 1
        }
        if !field.isEmpty || !currentRow.isEmpty {
            currentRow.append(field)
            if currentRow.contains(where: { !$0.isEmpty }) {
                rows.append(currentRow)
            }
        }
        return rows
    }

    // MARK: - Browser / Pocket Bookmarks (.html)

    private static func importBookmarksHtml(text: String, db: PaperclipDatabase) -> Result {
        let state = ImportState(db: db)
        var folderStack: [Int64?] = []
        var pendingFolderId: Int64?
        var imported = 0
        var skipped = 0

        let tokenRegex = try! NSRegularExpression(
            pattern: "(?is)<H3([^>]*)>(.*?)</H3>|<DL\\b[^>]*>|</DL>|<A\\b([^>]*)>(.*?)</A>|<DD>([^<\\r\\n]*)",
            options: []
        )
        let nsText = text as NSString
        let matches = tokenRegex.matches(in: text, options: [], range: NSRange(location: 0, length: nsText.length))

        for match in matches {
            let token = nsText.substring(with: match.range).trimmingCharacters(in: .whitespacesAndNewlines)
            let upper = token.uppercased()

            if upper.hasPrefix("<H3") {
                let rawName = match.range(at: 2).location != NSNotFound ? nsText.substring(with: match.range(at: 2)) : ""
                let name = decodeHtml(stripTags(rawName)).trimmingCharacters(in: .whitespacesAndNewlines)
                let parent = folderStack.last ?? nil
                pendingFolderId = isGenericRootFolder(name) && parent == nil ? nil : state.getOrCreateFolderId(name: name, parentId: parent)
            } else if upper.hasPrefix("<DL") {
                folderStack.append(pendingFolderId)
                pendingFolderId = nil
            } else if upper.hasPrefix("</DL") {
                if !folderStack.isEmpty { folderStack.removeLast() }
            } else if upper.hasPrefix("<A") {
                let attrs = match.range(at: 3).location != NSNotFound ? nsText.substring(with: match.range(at: 3)) : ""
                let inner = match.range(at: 4).location != NSNotFound ? nsText.substring(with: match.range(at: 4)) : ""
                guard let hrefRaw = extractAttr(attrs, name: "HREF") else { continue }
                let href = decodeHtml(hrefRaw)
                guard let normalized = LinkUrls.normalizeWebUrl(href) else {
                    skipped += 1
                    continue
                }
                if !state.claimUrl(normalized) {
                    skipped += 1
                    continue
                }
                let titleText = decodeHtml(stripTags(inner)).trimmingCharacters(in: .whitespacesAndNewlines)
                let title = titleText.isEmpty || titleText == href ? (LinkUrls.defaultTitleForUrl(normalized) ?? normalized) : titleText
                let addDate = extractAttr(attrs, name: "ADD_DATE").flatMap { Int64($0) }
                let createdAt = (addDate ?? 0) > 0 ? addDate! * 1000 : ArchiveItem.nowMillis()
                let tagsAttr = extractAttr(attrs, name: "TAGS").map(decodeHtml) ?? ""
                let tagIds = tagsAttr
                    .components(separatedBy: CharacterSet(charactersIn: ",|"))
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .map { state.getOrCreateTagId(name: $0) }
                let currentFolder = folderStack.reversed().compactMap { $0 }.first

                let item = ArchiveItem(
                    title: String(title.prefix(200)),
                    itemType: .LINK,
                    contentUrl: normalized,
                    folderId: currentFolder,
                    createdAt: createdAt,
                    updatedAt: createdAt
                )
                state.insertItem(item, tagIds: tagIds)
                imported += 1
            }
        }

        return Result(imported: imported, skipped: skipped)
    }

    private static func isGenericRootFolder(_ name: String) -> Bool {
        let lower = name.lowercased()
        let roots: Set<String> = [
            "", "bookmarks", "bookmarks bar", "bookmarks menu", "barra dei preferiti",
            "menu segnalibri", "other bookmarks", "altri preferiti", "preferiti",
            "segnalibri", "unread", "archive"
        ]
        return roots.contains(lower)
    }

    private static func extractAttr(_ attrs: String, name: String) -> String? {
        let pattern = "(?i)\\b\(NSRegularExpression.escapedPattern(for: name))\\s*=\\s*\"([^\"]*)\""
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: attrs, range: NSRange(location: 0, length: (attrs as NSString).length)),
              match.range(at: 1).location != NSNotFound else {
            return nil
        }
        return (attrs as NSString).substring(with: match.range(at: 1))
    }

    private static func stripTags(_ html: String) -> String {
        html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    }

    private static func decodeHtml(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    private static func firstLine(_ value: String) -> String? {
        value
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    // MARK: - ImportState

    private final class ImportState {
        let db: PaperclipDatabase
        var tagsByKey: [String: Tag] = [:]
        var foldersByKey: [FolderKey: Folder] = [:]
        var existingUrls: Set<String> = []
        var colorIndex: Int = 0

        struct FolderKey: Hashable {
            let parentId: Int64?
            let nameKey: String
        }

        init(db: PaperclipDatabase) {
            self.db = db
            for tag in db.getAllTags() {
                tagsByKey[tag.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()] = tag
            }
            for folder in db.getAllFolders() {
                let key = FolderKey(parentId: folder.parentId, nameKey: folder.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
                foldersByKey[key] = folder
            }
            for item in db.getAllItems() where item.deletedAt == nil && item.itemType == .LINK {
                if let u = item.contentUrl?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !u.isEmpty {
                    existingUrls.insert(u)
                }
            }
            colorIndex = tagsByKey.count + foldersByKey.count
        }

        func claimUrl(_ url: String) -> Bool {
            let key = url.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !key.isEmpty else { return false }
            return existingUrls.insert(key).inserted
        }

        func getOrCreateTagId(name: String) -> Int64 {
            let clean = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(50))
            let key = clean.lowercased()
            if let existing = tagsByKey[key] { return existing.id }
            let color = ExternalImporter.tagPalette[colorIndex % ExternalImporter.tagPalette.count]
            colorIndex += 1
            let savedId = db.saveTag(Tag(name: clean, colorHex: color))
            let created = Tag(id: savedId, name: clean, colorHex: color)
            tagsByKey[key] = created
            return savedId
        }

        func getOrCreateFolderId(name: String, parentId: Int64?) -> Int64? {
            let clean = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
            guard !clean.isEmpty else { return parentId }
            let key = FolderKey(parentId: parentId, nameKey: clean.lowercased())
            if let existing = foldersByKey[key] { return existing.id }
            let color = ExternalImporter.tagPalette[colorIndex % ExternalImporter.tagPalette.count]
            colorIndex += 1
            let savedId = db.saveFolder(Folder(name: clean, colorHex: color, parentId: parentId))
            let created = Folder(id: savedId, name: clean, colorHex: color, parentId: parentId)
            foldersByKey[key] = created
            return savedId
        }

        func insertItem(_ item: ArchiveItem, tagIds: [Int64]) {
            _ = db.saveItemWithTags(item, tagIds: Array(Set(tagIds)))
        }
    }
}

private extension String {
    func lineSequence() -> [String] {
        components(separatedBy: .newlines)
    }
}
