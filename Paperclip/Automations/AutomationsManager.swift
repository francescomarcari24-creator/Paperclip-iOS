import Foundation
import CryptoKit
import LocalAuthentication

// MARK: - AutoRules

enum AutoRules {

    enum ConditionKind: String, Codable, CaseIterable, Identifiable {
        case LINK_CONTAINS
        case TEXT_CONTAINS
        case TYPE_IS

        var id: String { rawValue }

        var label: String {
            switch self {
            case .LINK_CONTAINS: return "Il link contiene"
            case .TEXT_CONTAINS: return "Titolo o nota contiene"
            case .TYPE_IS: return "Il tipo è"
            }
        }
    }

    enum ActionKind: String, Codable, CaseIterable, Identifiable {
        case MOVE_TO_FOLDER
        case ADD_TAG

        var id: String { rawValue }

        var label: String {
            switch self {
            case .MOVE_TO_FOLDER: return "Sposta nella cartella"
            case .ADD_TAG: return "Aggiungi tag"
            }
        }
    }

    struct AutoRule: Codable, Identifiable, Equatable {
        var id: String = UUID().uuidString
        var conditionKind: ConditionKind
        var conditionValue: String
        var actionKind: ActionKind
        var targetId: Int64
        var enabled: Bool = true
    }

    private static let keyRules = "paperclip_auto_rules_v1"

    static func list() -> [AutoRule] {
        guard let raw = UserDefaults.standard.string(forKey: keyRules),
              let data = raw.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([AutoRule].self, from: data) else {
            return []
        }
        return decoded
    }

    static func save(_ rules: [AutoRule]) {
        if let data = try? JSONEncoder().encode(rules),
           let str = String(data: data, encoding: .utf8) {
            UserDefaults.standard.set(str, forKey: keyRules)
        }
    }

    static func matches(rule: AutoRule, item: ArchiveItem) -> Bool {
        guard rule.enabled else { return false }
        let needle = rule.conditionValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return false }
        switch rule.conditionKind {
        case .LINK_CONTAINS:
            guard item.itemType == .LINK, let url = item.contentUrl else { return false }
            return url.localizedCaseInsensitiveContains(needle)
        case .TEXT_CONTAINS:
            let plainDesc = RichText.toPlainString(item.description ?? "")
            return item.title.localizedCaseInsensitiveContains(needle) || plainDesc.localizedCaseInsensitiveContains(needle)
        case .TYPE_IS:
            return item.itemType.rawValue.caseInsensitiveCompare(needle) == .orderedSame
        }
    }

    static func apply(item: ArchiveItem, tagIds: [Int64], rules: [AutoRule] = list()) -> (ArchiveItem, [Int64]) {
        var folderId = item.folderId
        var tags = Set(tagIds)
        for rule in rules where matches(rule: rule, item: item) {
            switch rule.actionKind {
            case .MOVE_TO_FOLDER:
                if folderId == nil {
                    folderId = rule.targetId
                }
            case .ADD_TAG:
                tags.insert(rule.targetId)
            }
        }
        var updated = item
        if folderId != item.folderId {
            updated.folderId = folderId
        }
        return (updated, Array(tags))
    }

    static func applyToAll(db: PaperclipDatabase = .shared) -> Int {
        let rules = list().filter { $0.enabled }
        guard !rules.isEmpty else { return 0 }
        let validFolders = Set(db.getAllFolders().map { $0.id })
        let validTags = Set(db.getAllTags().map { $0.id })
        let activeRules = rules.filter { r in
            switch r.actionKind {
            case .MOVE_TO_FOLDER: return validFolders.contains(r.targetId)
            case .ADD_TAG: return validTags.contains(r.targetId)
            }
        }
        guard !activeRules.isEmpty else { return 0 }

        var tagsByItem: [Int64: Set<Int64>] = [:]
        for ref in db.getAllCrossRefs() {
            tagsByItem[ref.itemId, default: []].insert(ref.tagId)
        }
        let now = ArchiveItem.nowMillis()
        var touched = 0

        for item in db.getAllItems() where item.deletedAt == nil {
            let currentTags = tagsByItem[item.id] ?? []
            var newFolder = item.folderId
            var addedTags: [Int64] = []
            for rule in activeRules where matches(rule: rule, item: item) {
                switch rule.actionKind {
                case .MOVE_TO_FOLDER:
                    if newFolder == nil { newFolder = rule.targetId }
                case .ADD_TAG:
                    if !currentTags.contains(rule.targetId) && !addedTags.contains(rule.targetId) {
                        addedTags.append(rule.targetId)
                    }
                }
            }
            let folderChanged = newFolder != item.folderId
            if folderChanged || !addedTags.isEmpty {
                var updated = item
                if folderChanged { updated.folderId = newFolder }
                updated.updatedAt = max(now, item.updatedAt + 1)
                let mergedTags = Array(currentTags.union(addedTags))
                _ = db.saveItemWithTags(updated, tagIds: mergedTags)
                touched += 1
            }
        }
        return touched
    }
}

// MARK: - RssFeeds

enum RssFeeds {

    struct RssFeed: Codable, Identifiable, Equatable {
        var id: String = UUID().uuidString
        var url: String
        var title: String
        var folderId: Int64? = nil
        var tagId: Int64? = nil
        var lastFetchedAt: Int64? = nil
    }

    struct FeedEntry {
        let title: String
        let link: String
        let summary: String?
        let publishedAt: Int64?
    }

    struct RefreshResult {
        var feedsChecked: Int = 0
        var newItems: Int = 0
        var failedFeeds: Int = 0
    }

    private static let keyFeeds = "paperclip_rss_feeds_v1"
    private static let maxEntriesPerRefresh = 25

    static func list() -> [RssFeed] {
        guard let raw = UserDefaults.standard.string(forKey: keyFeeds),
              let data = raw.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([RssFeed].self, from: data) else {
            return []
        }
        return decoded
    }

    static func save(_ feeds: [RssFeed]) {
        if let data = try? JSONEncoder().encode(feeds),
           let str = String(data: data, encoding: .utf8) {
            UserDefaults.standard.set(str, forKey: keyFeeds)
        }
    }

    static func remove(id: String) {
        save(list().filter { $0.id != id })
    }

    static func subscribe(
        rawUrl: String,
        folderId: Int64?,
        tagId: Int64?,
        db: PaperclipDatabase = .shared
    ) async throws -> (RssFeed, Int) {
        guard let normalized = LinkUrls.normalizeWebUrl(rawUrl) else {
            throw NSError(domain: "RssFeeds", code: 1, userInfo: [NSLocalizedDescriptionKey: "URL non valido"])
        }
        let body = try await fetchText(url: normalized)
        let finalUrl: String
        let parsed: (title: String?, entries: [FeedEntry])

        let attempt = parseFeed(xml: body, baseUrl: normalized)
        if !attempt.entries.isEmpty || !(attempt.title?.isEmpty ?? true) {
            finalUrl = normalized
            parsed = attempt
        } else if let discovered = discoverFeedUrlInHtml(html: body, baseUrl: normalized) {
            let feedBody = try await fetchText(url: discovered)
            finalUrl = discovered
            parsed = parseFeed(xml: feedBody, baseUrl: discovered)
        } else {
            throw NSError(domain: "RssFeeds", code: 2, userInfo: [NSLocalizedDescriptionKey: "Nessun feed RSS o Atom trovato a questo indirizzo"])
        }

        var existing = list()
        let feedTitle = (parsed.title?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
            ?? LinkUrls.defaultTitleForUrl(finalUrl)
            ?? finalUrl

        let feed: RssFeed
        if let found = existing.first(where: { $0.url.caseInsensitiveCompare(finalUrl) == .orderedSame }) {
            var updated = found
            updated.title = feedTitle
            updated.folderId = folderId
            updated.tagId = tagId
            updated.lastFetchedAt = ArchiveItem.nowMillis()
            feed = updated
            existing = existing.map { $0.id == found.id ? updated : $0 }
        } else {
            let created = RssFeed(
                url: finalUrl,
                title: feedTitle,
                folderId: folderId,
                tagId: tagId,
                lastFetchedAt: ArchiveItem.nowMillis()
            )
            feed = created
            existing.append(created)
        }
        save(existing)
        let added = importEntries(feed: feed, entries: parsed.entries, db: db)
        return (feed, added)
    }

    static func refreshAll(db: PaperclipDatabase = .shared) async -> RefreshResult {
        let current = list()
        guard !current.isEmpty else { return RefreshResult() }
        var updatedFeeds = current
        var totalAdded = 0
        var failed = 0

        for idx in updatedFeeds.indices {
            let feed = updatedFeeds[idx]
            do {
                let xml = try await fetchText(url: feed.url)
                let parsed = parseFeed(xml: xml, baseUrl: feed.url)
                let added = importEntries(feed: feed, entries: parsed.entries, db: db)
                totalAdded += added
                if let newTitle = parsed.title?.trimmingCharacters(in: .whitespacesAndNewlines), !newTitle.isEmpty, feed.title.isEmpty {
                    updatedFeeds[idx].title = newTitle
                }
                updatedFeeds[idx].lastFetchedAt = ArchiveItem.nowMillis()
            } catch {
                failed += 1
            }
        }
        save(updatedFeeds)
        return RefreshResult(feedsChecked: current.count, newItems: totalAdded, failedFeeds: failed)
    }

    private static func importEntries(feed: RssFeed, entries: [FeedEntry], db: PaperclipDatabase) -> Int {
        guard !entries.isEmpty else { return 0 }
        let validFolders = Set(db.getAllFolders().map { $0.id })
        let validTags = Set(db.getAllTags().map { $0.id })
        let folderId = feed.folderId.flatMap { validFolders.contains($0) ? $0 : nil }
        let tagId = feed.tagId.flatMap { validTags.contains($0) ? $0 : nil }

        var knownUrls = Set(
            db.getAllItems()
                .filter { $0.itemType == .LINK }
                .compactMap { $0.contentUrl?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        )

        let rules = AutoRules.list()
        let now = ArchiveItem.nowMillis()
        var added = 0

        for entry in entries.prefix(maxEntriesPerRefresh) {
            guard let normalized = LinkUrls.normalizeWebUrl(entry.link) else { continue }
            guard knownUrls.insert(normalized.lowercased()).inserted else { continue }
            let createdAt = entry.publishedAt.flatMap { $0 > 0 && $0 <= now + 86_400_000 ? $0 : nil } ?? now
            let cleanTitle = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let finalTitle = String((cleanTitle.isEmpty ? (LinkUrls.defaultTitleForUrl(normalized) ?? normalized) : cleanTitle).prefix(200))
            let cleanSummary = entry.summary?.trimmingCharacters(in: .whitespacesAndNewlines)
            let finalSummary = (cleanSummary?.isEmpty ?? true) ? nil : String(cleanSummary!.prefix(600))

            let baseItem = ArchiveItem(
                title: finalTitle,
                description: finalSummary,
                itemType: .LINK,
                contentUrl: normalized,
                folderId: folderId,
                createdAt: createdAt,
                updatedAt: createdAt
            )
            let initialTags = tagId.map { [$0] } ?? []
            let (ruledItem, ruledTags) = AutoRules.apply(item: baseItem, tagIds: initialTags, rules: rules)
            _ = db.saveItemWithTags(ruledItem, tagIds: ruledTags)
            added += 1
        }
        return added
    }

    private static func fetchText(url: String) async throws -> String {
        guard let reqUrl = URL(string: url) else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: reqUrl)
        request.timeoutInterval = 12
        request.setValue("Mozilla/5.0 (compatible; Paperclip/1.0)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/rss+xml, application/atom+xml, application/xml, text/xml, text/html;q=0.8", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }

    private static func discoverFeedUrlInHtml(html: String, baseUrl: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "(?is)<link\\b[^>]*>", options: []) else { return nil }
        let nsHtml = html as NSString
        for match in regex.matches(in: html, range: NSRange(location: 0, length: nsHtml.length)) {
            let tag = nsHtml.substring(with: match.range)
            let lower = tag.lowercased()
            if !lower.contains("alternate") { continue }
            if !(lower.contains("application/rss+xml") || lower.contains("application/atom+xml") || lower.contains("application/feed+json")) {
                continue
            }
            if let href = extractAttr(tag, name: "href"),
               let resolved = URL(string: href, relativeTo: URL(string: baseUrl))?.absoluteURL.absoluteString {
                return resolved
            }
        }
        return nil
    }

    private static func extractAttr(_ tag: String, name: String) -> String? {
        let pattern = "(?i)\\b\(NSRegularExpression.escapedPattern(for: name))\\s*=\\s*[\"']([^\"']+)[\"']"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let m = regex.firstMatch(in: tag, range: NSRange(location: 0, length: (tag as NSString).length)),
              m.range(at: 1).location != NSNotFound else {
            return nil
        }
        return (tag as NSString).substring(with: m.range(at: 1))
    }

    private static func parseFeed(xml: String, baseUrl: String) -> (title: String?, entries: [FeedEntry]) {
        guard let data = xml.data(using: .utf8) else { return (nil, []) }
        let delegate = FeedXmlParserDelegate(baseUrl: baseUrl)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        _ = parser.parse()
        return (delegate.feedTitle, delegate.entries)
    }

    private final class FeedXmlParserDelegate: NSObject, XMLParserDelegate {
        let baseUrl: String
        var feedTitle: String?
        var entries: [FeedEntry] = []

        private var inEntry = false
        private var currentTag = ""
        private var currentText = ""

        private var entryTitle = ""
        private var entryLink = ""
        private var entrySummary = ""
        private var entryDate = ""

        init(baseUrl: String) {
            self.baseUrl = baseUrl
        }

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            let local = (elementName.components(separatedBy: ":").last ?? elementName).lowercased()
            currentTag = local
            currentText = ""

            if local == "item" || local == "entry" {
                inEntry = true
                entryTitle = ""
                entryLink = ""
                entrySummary = ""
                entryDate = ""
            } else if inEntry && local == "link" {
                if let href = attributeDict["href"] ?? attributeDict["HREF"] {
                    let rel = (attributeDict["rel"] ?? "alternate").lowercased()
                    if entryLink.isEmpty || rel == "alternate" {
                        entryLink = href
                    }
                }
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            currentText.append(string)
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            let local = (elementName.components(separatedBy: ":").last ?? elementName).lowercased()
            let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)

            if inEntry {
                switch local {
                case "title":
                    if entryTitle.isEmpty { entryTitle = stripHtml(trimmed) }
                case "link":
                    if !trimmed.isEmpty && entryLink.isEmpty { entryLink = trimmed }
                case "guid":
                    if entryLink.isEmpty && (trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://")) {
                        entryLink = trimmed
                    }
                case "description", "summary", "encoded", "content":
                    if entrySummary.isEmpty && !trimmed.isEmpty {
                        entrySummary = stripHtml(trimmed)
                    }
                case "pubdate", "published", "updated", "date":
                    if entryDate.isEmpty && !trimmed.isEmpty {
                        entryDate = trimmed
                    }
                case "item", "entry":
                    inEntry = false
                    if let resolved = resolveLink(entryLink, baseUrl: baseUrl) {
                        entries.append(FeedEntry(
                            title: entryTitle,
                            link: resolved,
                            summary: entrySummary.isEmpty ? nil : entrySummary,
                            publishedAt: parseFeedDate(entryDate)
                        ))
                    }
                default:
                    break
                }
            } else if local == "title" && feedTitle == nil && !trimmed.isEmpty {
                feedTitle = stripHtml(trimmed)
            }
            currentText = ""
        }

        private func resolveLink(_ raw: String, baseUrl: String) -> String? {
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { return nil }
            if t.hasPrefix("http://") || t.hasPrefix("https://") { return t }
            return URL(string: t, relativeTo: URL(string: baseUrl))?.absoluteURL.absoluteString
        }

        private func stripHtml(_ raw: String) -> String {
            raw
                .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
                .replacingOccurrences(of: "&nbsp;", with: " ")
                .replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">")
                .replacingOccurrences(of: "&quot;", with: "\"")
                .replacingOccurrences(of: "&#39;", with: "'")
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        private func parseFeedDate(_ raw: String) -> Int64? {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let iso = ISO8601DateFormatter()
            if let d = iso.date(from: trimmed) {
                return Int64(d.timeIntervalSince1970 * 1000)
            }
            let formats = [
                "EEE, dd MMM yyyy HH:mm:ss Z",
                "EEE, d MMM yyyy HH:mm:ss Z",
                "dd MMM yyyy HH:mm:ss Z",
                "yyyy-MM-dd'T'HH:mm:ss.SSSZ",
                "yyyy-MM-dd'T'HH:mm:ssZ",
                "yyyy-MM-dd HH:mm:ss"
            ]
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            for f in formats {
                df.dateFormat = f
                if let d = df.date(from: trimmed) {
                    return Int64(d.timeIntervalSince1970 * 1000)
                }
            }
            return nil
        }
    }
}

// MARK: - LinkChecker

enum LinkChecker {

    enum Status: String, Codable {
        case BROKEN
        case UNREACHABLE
    }

    struct BrokenInfo: Codable, Equatable {
        var status: Status
        var code: Int
        var checkedAt: Int64
    }

    struct Summary {
        var checked: Int = 0
        var broken: Int = 0
        var unreachable: Int = 0
    }

    private static let keyBrokenMap = "paperclip_broken_links_v1"

    static func loadMap() -> [Int64: BrokenInfo] {
        guard let raw = UserDefaults.standard.string(forKey: keyBrokenMap),
              let data = raw.data(using: .utf8),
              let dict = try? JSONDecoder().decode([String: BrokenInfo].self, from: data) else {
            return [:]
        }
        var out: [Int64: BrokenInfo] = [:]
        for (k, v) in dict {
            if let id = Int64(k) { out[id] = v }
        }
        return out
    }

    static func saveMap(_ map: [Int64: BrokenInfo]) {
        let strDict = Dictionary(uniqueKeysWithValues: map.map { (String($0.key), $0.value) })
        if let data = try? JSONEncoder().encode(strDict),
           let str = String(data: data, encoding: .utf8) {
            UserDefaults.standard.set(str, forKey: keyBrokenMap)
        }
    }

    static func clearForItem(_ itemId: Int64) {
        var current = loadMap()
        if current.removeValue(forKey: itemId) != nil {
            saveMap(current)
        }
    }

    static func waybackUrl(for url: String) -> String {
        "https://web.archive.org/web/*/\(url)"
    }

    static func checkAllLinks(
        db: PaperclipDatabase = .shared,
        onProgress: @Sendable (Int, Int) -> Void = { _, _ in }
    ) async -> (Summary, [Int64: BrokenInfo]) {
        let links = db.getAllItems().filter { $0.deletedAt == nil && $0.itemType == .LINK && !($0.contentUrl?.isEmpty ?? true) }
        guard !links.isEmpty else {
            saveMap([:])
            return (Summary(), [:])
        }

        var results: [Int64: BrokenInfo] = [:]
        var brokenCount = 0
        var unreachableCount = 0
        let now = ArchiveItem.nowMillis()

        for (index, item) in links.enumerated() {
            if let info = await probe(url: item.contentUrl ?? "", checkedAt: now) {
                results[item.id] = info
                if info.status == .BROKEN { brokenCount += 1 }
                else { unreachableCount += 1 }
            }
            onProgress(index + 1, links.count)
        }

        saveMap(results)
        return (Summary(checked: links.count, broken: brokenCount, unreachable: unreachableCount), results)
    }

    private static func probe(url: String, checkedAt: Int64) async -> BrokenInfo? {
        guard let normalized = LinkUrls.normalizeWebUrl(url),
              let reqUrl = URL(string: normalized) else {
            return BrokenInfo(status: .BROKEN, code: 0, checkedAt: checkedAt)
        }
        let headCode = await requestCode(url: reqUrl, method: "HEAD")
        let finalCode: Int
        if headCode == 405 || headCode == 501 || headCode == 403 || headCode == 400 {
            finalCode = await requestCode(url: reqUrl, method: "GET")
        } else {
            finalCode = headCode
        }

        switch finalCode {
        case 404, 410, 451:
            return BrokenInfo(status: .BROKEN, code: finalCode, checkedAt: checkedAt)
        case -2:
            return BrokenInfo(status: .UNREACHABLE, code: 0, checkedAt: checkedAt)
        default:
            return nil
        }
    }

    private static func requestCode(url: URL, method: String) async -> Int {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 8
        req.setValue("Mozilla/5.0 (compatible; Paperclip/1.0)", forHTTPHeaderField: "User-Agent")
        if method == "GET" {
            req.setValue("bytes=0-1023", forHTTPHeaderField: "Range")
        }
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            return (resp as? HTTPURLResponse)?.statusCode ?? 200
        } catch let err as URLError {
            if err.code == .cannotFindHost || err.code == .dnsLookupFailed {
                return -2
            }
            return -1
        } catch {
            return -1
        }
    }
}

// MARK: - AppLockManager (PIN & Biometrics for App Lock + Private Vault)

final class AppLockManager: ObservableObject {
    static let shared = AppLockManager()

    private let keyPinSalt = "paperclip_security_pin_salt"
    private let keyPinHash = "paperclip_security_pin_hash"
    private let keyBiometricEnabled = "paperclip_security_biometric"
    private let keyAppLockEnabled = "paperclip_security_app_lock"

    @Published var hasPin: Bool = false
    @Published var biometricEnabled: Bool = false
    @Published var appLockEnabled: Bool = false
    @Published var isAppUnlocked: Bool = true
    @Published var isPrivateVaultUnlocked: Bool = false

    private init() {
        let pinPresent = !(UserDefaults.standard.string(forKey: keyPinHash)?.isEmpty ?? true)
        self.hasPin = pinPresent
        self.biometricEnabled = UserDefaults.standard.bool(forKey: keyBiometricEnabled)
        let lockOn = pinPresent && UserDefaults.standard.bool(forKey: keyAppLockEnabled)
        self.appLockEnabled = lockOn
        self.isAppUnlocked = !lockOn
    }

    func setPin(_ pin: String) {
        var salt = Data(count: 16)
        _ = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        let hash = hashPin(pin, salt: salt)
        UserDefaults.standard.set(salt.base64EncodedString(), forKey: keyPinSalt)
        UserDefaults.standard.set(hash.base64EncodedString(), forKey: keyPinHash)
        hasPin = true
        isPrivateVaultUnlocked = true
        isAppUnlocked = true
    }

    func verifyPin(_ pin: String) -> Bool {
        guard let saltB64 = UserDefaults.standard.string(forKey: keyPinSalt),
              let hashB64 = UserDefaults.standard.string(forKey: keyPinHash),
              let salt = Data(base64Encoded: saltB64),
              let expected = Data(base64Encoded: hashB64) else {
            return false
        }
        let actual = hashPin(pin, salt: salt)
        return actual == expected
    }

    func removePin() {
        UserDefaults.standard.removeObject(forKey: keyPinSalt)
        UserDefaults.standard.removeObject(forKey: keyPinHash)
        UserDefaults.standard.set(false, forKey: keyBiometricEnabled)
        UserDefaults.standard.set(false, forKey: keyAppLockEnabled)
        hasPin = false
        biometricEnabled = false
        appLockEnabled = false
        isAppUnlocked = true
        isPrivateVaultUnlocked = false
    }

    func setBiometricEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: keyBiometricEnabled)
        biometricEnabled = enabled
    }

    func setAppLockEnabled(_ enabled: Bool) {
        let actual = enabled && hasPin
        UserDefaults.standard.set(actual, forKey: keyAppLockEnabled)
        appLockEnabled = actual
        if !actual {
            isAppUnlocked = true
        }
    }

    func lockIfNeededOnBackground() {
        isPrivateVaultUnlocked = false
        if appLockEnabled && hasPin {
            isAppUnlocked = false
        }
    }

    func canUseBiometrics() -> Bool {
        let ctx = LAContext()
        var error: NSError?
        return ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
    }

    func authenticateWithBiometrics(reason: String, completion: @escaping (Bool) -> Void) {
        let ctx = LAContext()
        var error: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            DispatchQueue.main.async { completion(false) }
            return
        }
        ctx.localizedFallbackTitle = "Usa il PIN"
        ctx.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason) { success, _ in
            DispatchQueue.main.async {
                completion(success)
            }
        }
    }

    private func hashPin(_ pin: String, salt: Data) -> Data {
        var combined = salt
        combined.append(Data(pin.utf8))
        return Data(SHA256.hash(data: combined))
    }
}
