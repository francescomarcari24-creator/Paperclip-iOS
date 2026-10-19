import Foundation

// MARK: - ItemType

enum ItemType: String, Codable, CaseIterable, Identifiable {
    case LINK
    case PHOTO
    case VIDEO
    case AUDIO
    case NOTE
    case CHECKLIST
    case DRAWING
    case PDF

    var id: String { rawValue }

    var label: String {
        switch self {
        case .LINK: return "Link"
        case .PHOTO: return "Foto"
        case .VIDEO: return "Video"
        case .AUDIO: return "Audio"
        case .NOTE: return "Nota"
        case .CHECKLIST: return "Checklist"
        case .DRAWING: return "Disegno"
        case .PDF: return "PDF"
        }
    }

    var pluralLabel: String {
        switch self {
        case .LINK: return "Link"
        case .PHOTO: return "Foto"
        case .VIDEO: return "Video"
        case .AUDIO: return "Audio"
        case .NOTE: return "Note"
        case .CHECKLIST: return "Checklist"
        case .DRAWING: return "Disegni"
        case .PDF: return "PDF"
        }
    }

    var systemIcon: String {
        switch self {
        case .LINK: return "link"
        case .PHOTO: return "photo"
        case .VIDEO: return "video"
        case .AUDIO: return "waveform"
        case .NOTE: return "note.text"
        case .CHECKLIST: return "checklist"
        case .DRAWING: return "scribble.variable"
        case .PDF: return "doc.richtext"
        }
    }

    var ordinal: Int {
        switch self {
        case .LINK: return 0
        case .PHOTO: return 1
        case .VIDEO: return 2
        case .AUDIO: return 3
        case .NOTE: return 4
        case .CHECKLIST: return 5
        case .DRAWING: return 6
        case .PDF: return 7
        }
    }

    static let mediaTypes: Set<ItemType> = [.PHOTO, .VIDEO, .AUDIO, .DRAWING, .PDF]
}

// MARK: - ArchiveItem

struct ArchiveItem: Codable, Identifiable, Equatable, Hashable {
    static let trashDays: Int = 30

    var id: Int64 = 0
    var title: String
    var description: String? = nil
    var itemType: ItemType
    var contentUrl: String? = nil
    var previewImageUrl: String? = nil
    var folderId: Int64? = nil
    var audioDurationMs: Int64? = nil
    var checklistJson: String? = nil
    var highlightsJson: String? = nil
    var reminderMinutes: Int? = nil
    var reminderDays: Int = 0
    var createdAt: Int64 = ArchiveItem.nowMillis()
    var updatedAt: Int64 = ArchiveItem.nowMillis()
    var isPinned: Bool = false
    var isArchived: Bool = false
    var deletedAt: Int64? = nil
    var readAt: Int64? = nil
    var isPrivate: Bool = false

    var hasReadState: Bool {
        itemType == .LINK || itemType == .PDF
    }

    var isUnread: Bool {
        hasReadState && readAt == nil
    }

    static func nowMillis() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }

    init(
        id: Int64 = 0,
        title: String,
        description: String? = nil,
        itemType: ItemType,
        contentUrl: String? = nil,
        previewImageUrl: String? = nil,
        folderId: Int64? = nil,
        audioDurationMs: Int64? = nil,
        checklistJson: String? = nil,
        highlightsJson: String? = nil,
        reminderMinutes: Int? = nil,
        reminderDays: Int = 0,
        createdAt: Int64 = ArchiveItem.nowMillis(),
        updatedAt: Int64 = ArchiveItem.nowMillis(),
        isPinned: Bool = false,
        isArchived: Bool = false,
        deletedAt: Int64? = nil,
        readAt: Int64? = nil,
        isPrivate: Bool = false
    ) {
        self.id = id
        self.title = title
        self.description = description
        self.itemType = itemType
        self.contentUrl = contentUrl
        self.previewImageUrl = previewImageUrl
        self.folderId = folderId
        self.audioDurationMs = audioDurationMs
        self.checklistJson = checklistJson
        self.highlightsJson = highlightsJson
        self.reminderMinutes = reminderMinutes
        self.reminderDays = reminderDays
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isPinned = isPinned
        self.isArchived = isArchived
        self.deletedAt = deletedAt
        self.readAt = readAt
        self.isPrivate = isPrivate
    }

    enum CodingKeys: String, CodingKey {
        case id, title, description, itemType, contentUrl, previewImageUrl
        case folderId, audioDurationMs, checklistJson, highlightsJson
        case reminderMinutes, reminderDays, createdAt, updatedAt
        case isPinned, isArchived, deletedAt, readAt, isPrivate
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(Int64.self, forKey: .id) ?? 0
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        description = try c.decodeIfPresent(String.self, forKey: .description)
        itemType = try c.decodeIfPresent(ItemType.self, forKey: .itemType) ?? .NOTE
        contentUrl = try c.decodeIfPresent(String.self, forKey: .contentUrl)
        previewImageUrl = try c.decodeIfPresent(String.self, forKey: .previewImageUrl)
        folderId = try c.decodeIfPresent(Int64.self, forKey: .folderId)
        audioDurationMs = try c.decodeIfPresent(Int64.self, forKey: .audioDurationMs)
        checklistJson = try c.decodeIfPresent(String.self, forKey: .checklistJson)
        highlightsJson = try c.decodeIfPresent(String.self, forKey: .highlightsJson)
        reminderMinutes = try c.decodeIfPresent(Int.self, forKey: .reminderMinutes)
        reminderDays = try c.decodeIfPresent(Int.self, forKey: .reminderDays) ?? 0
        let now = ArchiveItem.nowMillis()
        createdAt = try c.decodeIfPresent(Int64.self, forKey: .createdAt) ?? now
        updatedAt = try c.decodeIfPresent(Int64.self, forKey: .updatedAt) ?? createdAt
        isPinned = try c.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        isArchived = try c.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
        deletedAt = try c.decodeIfPresent(Int64.self, forKey: .deletedAt)
        readAt = try c.decodeIfPresent(Int64.self, forKey: .readAt)
        isPrivate = try c.decodeIfPresent(Bool.self, forKey: .isPrivate) ?? false
    }
}

// MARK: - Folder & FolderTree

struct Folder: Codable, Identifiable, Equatable, Hashable {
    var id: Int64 = 0
    var name: String
    var colorHex: String = "#6200EE"
    var createdAt: Int64 = ArchiveItem.nowMillis()
    var parentId: Int64? = nil

    init(
        id: Int64 = 0,
        name: String,
        colorHex: String = "#6200EE",
        createdAt: Int64 = ArchiveItem.nowMillis(),
        parentId: Int64? = nil
    ) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.createdAt = createdAt
        self.parentId = parentId
    }

    enum CodingKeys: String, CodingKey {
        case id, name, colorHex, createdAt, parentId
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(Int64.self, forKey: .id) ?? 0
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        colorHex = try c.decodeIfPresent(String.self, forKey: .colorHex) ?? "#6200EE"
        createdAt = try c.decodeIfPresent(Int64.self, forKey: .createdAt) ?? ArchiveItem.nowMillis()
        parentId = try c.decodeIfPresent(Int64.self, forKey: .parentId)
    }
}

struct FolderTree {
    struct Entry: Identifiable, Equatable {
        let folder: Folder
        let depth: Int
        var id: Int64 { folder.id }
    }

    private let byId: [Int64: Folder]
    private var children: [Int64?: [Folder]] = [:]
    let entries: [Entry]

    init(folders: [Folder]) {
        let map = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0) })
        self.byId = map

        func effectiveParent(_ folder: Folder) -> Int64? {
            guard let parent = folder.parentId, map[parent] != nil else { return nil }
            var seen: Set<Int64> = [folder.id]
            var current: Int64? = parent
            while let cur = current {
                if !seen.insert(cur).inserted { return nil }
                if let nextParent = map[cur]?.parentId, map[nextParent] != nil {
                    current = nextParent
                } else {
                    current = nil
                }
            }
            return parent
        }

        let locale = Locale(identifier: "it_IT")
        var grouped: [Int64?: [Folder]] = [:]
        for folder in folders {
            let p = effectiveParent(folder)
            grouped[p, default: []].append(folder)
        }
        for (k, list) in grouped {
            grouped[k] = list.sorted {
                $0.name.compare($1.name, options: [.caseInsensitive, .diacriticInsensitive], range: nil, locale: locale) == .orderedAscending
            }
        }
        self.children = grouped

        var built: [Entry] = []
        func visit(_ parent: Int64?, _ depth: Int) {
            for folder in grouped[parent] ?? [] {
                built.append(Entry(folder: folder, depth: depth))
                visit(folder.id, depth + 1)
            }
        }
        visit(nil, 0)
        self.entries = built
    }

    func withDescendants(_ folderId: Int64) -> Set<Int64> {
        var result: Set<Int64> = []
        func visit(_ id: Int64) {
            guard result.insert(id).inserted else { return }
            for child in children[id] ?? [] {
                visit(child.id)
            }
        }
        visit(folderId)
        return result
    }

    func pathOf(_ folderId: Int64) -> [String] {
        var names: [String] = []
        var seen: Set<Int64> = []
        var current = byId[folderId]
        while let cur = current, seen.insert(cur.id).inserted {
            names.insert(cur.name, at: 0)
            if let pid = cur.parentId, let parent = byId[pid] {
                current = parent
            } else {
                current = nil
            }
        }
        return names
    }

    func pathLabel(_ folderId: Int64) -> String {
        pathOf(folderId).joined(separator: " › ")
    }
}

// MARK: - Tag & ItemTagCrossRef

struct Tag: Codable, Identifiable, Equatable, Hashable {
    var id: Int64 = 0
    var name: String
    var colorHex: String = "#03DAC6"

    init(id: Int64 = 0, name: String, colorHex: String = "#03DAC6") {
        self.id = id
        self.name = name
        self.colorHex = colorHex
    }

    enum CodingKeys: String, CodingKey {
        case id, name, colorHex
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(Int64.self, forKey: .id) ?? 0
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        colorHex = try c.decodeIfPresent(String.self, forKey: .colorHex) ?? "#03DAC6"
    }
}

struct ItemTagCrossRef: Codable, Equatable, Hashable {
    var itemId: Int64
    var tagId: Int64
}

// MARK: - ItemContent

struct ItemContent: Codable, Equatable, Hashable {
    var itemId: Int64
    var sourceKey: String
    var text: String? = nil
    var articleJson: String? = nil
    var indexedAt: Int64? = nil
    var attempts: Int = 0
    var attemptedAt: Int64 = 0

    init(
        itemId: Int64,
        sourceKey: String,
        text: String? = nil,
        articleJson: String? = nil,
        indexedAt: Int64? = nil,
        attempts: Int = 0,
        attemptedAt: Int64 = 0
    ) {
        self.itemId = itemId
        self.sourceKey = sourceKey
        self.text = text
        self.articleJson = articleJson
        self.indexedAt = indexedAt
        self.attempts = attempts
        self.attemptedAt = attemptedAt
    }

    enum CodingKeys: String, CodingKey {
        case itemId, sourceKey, text, articleJson, indexedAt, attempts, attemptedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        itemId = try c.decode(Int64.self, forKey: .itemId)
        sourceKey = try c.decodeIfPresent(String.self, forKey: .sourceKey) ?? ""
        text = try c.decodeIfPresent(String.self, forKey: .text)
        articleJson = try c.decodeIfPresent(String.self, forKey: .articleJson)
        indexedAt = try c.decodeIfPresent(Int64.self, forKey: .indexedAt)
        attempts = try c.decodeIfPresent(Int.self, forKey: .attempts) ?? 0
        attemptedAt = try c.decodeIfPresent(Int64.self, forKey: .attemptedAt) ?? 0
    }
}

// MARK: - ArchiveItemWithDetails

struct ArchiveItemWithDetails: Identifiable, Equatable, Hashable {
    var item: ArchiveItem
    var folder: Folder?
    var tags: [Tag]

    var id: Int64 { item.id }
}

// MARK: - ChecklistItem

struct ChecklistItem: Codable, Identifiable, Equatable, Hashable {
    var id: String = UUID().uuidString
    var text: String
    var isChecked: Bool = false

    init(id: String = UUID().uuidString, text: String, isChecked: Bool = false) {
        self.id = id
        self.text = text
        self.isChecked = isChecked
    }

    enum CodingKeys: String, CodingKey {
        case id, text, isChecked
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        isChecked = try c.decodeIfPresent(Bool.self, forKey: .isChecked) ?? false
    }

    static func fromJson(_ json: String?) -> [ChecklistItem] {
        guard let json = json, !json.isEmpty, let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([ChecklistItem].self, from: data)) ?? []
    }

    static func toJson(_ items: [ChecklistItem]) -> String? {
        guard !items.isEmpty, let data = try? JSONEncoder().encode(items) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - Highlights

enum HighlightColor: String, Codable, CaseIterable, Identifiable {
    case YELLOW
    case GREEN
    case BLUE
    case PINK
    case ORANGE

    var id: String { rawValue }

    var label: String {
        switch self {
        case .YELLOW: return "Giallo"
        case .GREEN: return "Verde"
        case .BLUE: return "Azzurro"
        case .PINK: return "Rosa"
        case .ORANGE: return "Arancione"
        }
    }

    var argb: UInt32 {
        switch self {
        case .YELLOW: return 0xFFFFE94D
        case .GREEN: return 0xFFA5E887
        case .BLUE: return 0xFF8FD3FF
        case .PINK: return 0xFFFFA3C8
        case .ORANGE: return 0xFFFFC27A
        }
    }
}

struct ArticleHighlight: Codable, Identifiable, Equatable, Hashable {
    var id: String = UUID().uuidString
    var text: String
    var start: Int
    var prefix: String? = nil
    var suffix: String? = nil
    var color: HighlightColor? = .YELLOW
    var note: String? = nil
    var createdAt: Int64 = ArchiveItem.nowMillis()

    var highlightColor: HighlightColor { color ?? .YELLOW }

    static func fromJson(_ json: String?) -> [ArticleHighlight] {
        guard let json = json, !json.isEmpty, let data = json.data(using: .utf8) else { return [] }
        let list = (try? JSONDecoder().decode([ArticleHighlight].self, from: data)) ?? []
        return list.filter { !$0.text.isEmpty }
    }

    static func toJson(_ highlights: [ArticleHighlight]) -> String? {
        guard !highlights.isEmpty, let data = try? JSONEncoder().encode(highlights) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

struct PdfRect: Codable, Equatable, Hashable {
    var left: Float
    var top: Float
    var right: Float
    var bottom: Float
}

struct PdfHighlight: Codable, Identifiable, Equatable, Hashable {
    var id: String = UUID().uuidString
    var page: Int
    var color: HighlightColor? = .YELLOW
    var text: String? = nil
    var rects: [PdfRect]? = nil
    var stroke: [Float]? = nil
    var strokeWidth: Float = 0
    var createdAt: Int64 = ArchiveItem.nowMillis()

    var highlightColor: HighlightColor { color ?? .YELLOW }

    static func fromJson(_ json: String?) -> [PdfHighlight] {
        guard let json = json, !json.isEmpty, let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([PdfHighlight].self, from: data)) ?? []
    }

    static func toJson(_ highlights: [PdfHighlight]) -> String? {
        guard !highlights.isEmpty, let data = try? JSONEncoder().encode(highlights) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - BackupPayload

struct BackupPayload: Codable {
    var folders: [Folder]
    var tags: [Tag]
    var items: [ArchiveItem]
    var crossRefs: [ItemTagCrossRef]
    var contents: [ItemContent]? = nil

    enum CodingKeys: String, CodingKey {
        case folders, tags, items, crossRefs, contents
    }

    init(
        folders: [Folder],
        tags: [Tag],
        items: [ArchiveItem],
        crossRefs: [ItemTagCrossRef],
        contents: [ItemContent]? = nil
    ) {
        self.folders = folders
        self.tags = tags
        self.items = items
        self.crossRefs = crossRefs
        self.contents = contents
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        folders = try c.decodeIfPresent([Folder].self, forKey: .folders) ?? []
        tags = try c.decodeIfPresent([Tag].self, forKey: .tags) ?? []
        items = try c.decodeIfPresent([ArchiveItem].self, forKey: .items) ?? []
        crossRefs = try c.decodeIfPresent([ItemTagCrossRef].self, forKey: .crossRefs) ?? []
        contents = try c.decodeIfPresent([ItemContent].self, forKey: .contents)
    }
}
