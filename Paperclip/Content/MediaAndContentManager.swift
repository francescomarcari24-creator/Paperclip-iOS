import SwiftUI
import UIKit
import WebKit
import PDFKit
import Vision
import VisionKit
import Speech
import AVFoundation
import PencilKit

// MARK: - ExtractedArticle & ArticleExtractor

struct ExtractedArticle: Codable, Equatable {
    var url: String
    var title: String? = nil
    var byline: String? = nil
    var siteName: String? = nil
    var leadImageUrl: String? = nil
    var contentHtml: String
    var plainText: String
    var readingMinutes: Int = 1

    static func fromJson(_ json: String?) -> ExtractedArticle? {
        guard let json = json, !json.isEmpty, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ExtractedArticle.self, from: data)
    }

    func toJson() -> String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

enum ArticleExtractor {

    static func fetchAndExtract(url: String) async -> ExtractedArticle? {
        guard let normalized = LinkUrls.normalizeWebUrl(url),
              let reqUrl = URL(string: normalized) else { return nil }
        var req = URLRequest(url: reqUrl)
        req.timeoutInterval = 15
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                return nil
            }
            let html = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
            return parse(html: html, url: normalized)
        } catch {
            return nil
        }
    }

    static func parse(html: String, url: String) -> ExtractedArticle? {
        let title = metaContent(html, keys: ["og:title", "twitter:title"]) ?? extractTagText(html, tag: "title")
        let siteName = metaContent(html, keys: ["og:site_name", "application-name"]) ?? URL(string: url)?.host?.replacingOccurrences(of: "^www\\.", with: "", options: .regularExpression)
        let byline = metaContent(html, keys: ["author", "article:author", "twitter:creator"])
        let leadImage = metaContent(html, keys: ["og:image", "twitter:image"])
        let description = metaContent(html, keys: ["og:description", "description", "twitter:description"])

        // Strip scripts, styles, nav, header, footer, aside
        var cleaned = html
        let removePatterns = [
            "(?is)<script\\b[^>]*>.*?</script>",
            "(?is)<style\\b[^>]*>.*?</style>",
            "(?is)<noscript\\b[^>]*>.*?</noscript>",
            "(?is)<svg\\b[^>]*>.*?</svg>",
            "(?is)<nav\\b[^>]*>.*?</nav>",
            "(?is)<footer\\b[^>]*>.*?</footer>",
            "(?is)<aside\\b[^>]*>.*?</aside>",
            "(?is)<!--.*?-->"
        ]
        for pat in removePatterns {
            cleaned = cleaned.replacingOccurrences(of: pat, with: " ", options: .regularExpression)
        }

        // Prefer <article> or <main> if available
        let containerHtml: String
        if let articleBody = firstMatchBlock(cleaned, tag: "article"), articleBody.count > 250 {
            containerHtml = articleBody
        } else if let mainBody = firstMatchBlock(cleaned, tag: "main"), mainBody.count > 250 {
            containerHtml = mainBody
        } else if let body = firstMatchBlock(cleaned, tag: "body") {
            containerHtml = body
        } else {
            containerHtml = cleaned
        }

        var paragraphs: [String] = []
        var plainParts: [String] = []
        let blockRegex = try? NSRegularExpression(pattern: "(?is)<(p|h2|h3|h4|blockquote|li|pre)\\b[^>]*>(.*?)</\\1>", options: [])
        let nsContainer = containerHtml as NSString
        let matches = blockRegex?.matches(in: containerHtml, range: NSRange(location: 0, length: nsContainer.length)) ?? []

        for m in matches {
            let tag = nsContainer.substring(with: m.range(at: 1)).lowercased()
            let inner = nsContainer.substring(with: m.range(at: 2))
            let plain = decodeEntities(stripHtmlTags(inner)).trimmingCharacters(in: .whitespacesAndNewlines)
            if plain.count < 20 && tag == "p" { continue }
            guard !plain.isEmpty else { continue }
            plainParts.append(plain)
            let escaped = escapeHtml(plain)
            paragraphs.append("<\(tag)>\(escaped)</\(tag)>")
        }

        if plainParts.isEmpty, let desc = description?.trimmingCharacters(in: .whitespacesAndNewlines), !desc.isEmpty {
            plainParts.append(desc)
            paragraphs.append("<p>\(escapeHtml(desc))</p>")
        }

        let fullPlain = plainParts.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fullPlain.isEmpty else { return nil }
        let words = fullPlain.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.count
        let readingMins = max(1, (words + 150) / 200)

        return ExtractedArticle(
            url: url,
            title: title?.trimmingCharacters(in: .whitespacesAndNewlines),
            byline: byline?.trimmingCharacters(in: .whitespacesAndNewlines),
            siteName: siteName?.trimmingCharacters(in: .whitespacesAndNewlines),
            leadImageUrl: leadImage?.trimmingCharacters(in: .whitespacesAndNewlines),
            contentHtml: paragraphs.joined(separator: "\n"),
            plainText: fullPlain,
            readingMinutes: readingMins
        )
    }

    private static func metaContent(_ html: String, keys: [String]) -> String? {
        for key in keys {
            let escaped = NSRegularExpression.escapedPattern(for: key)
            let patterns = [
                "(?is)<meta\\b[^>]+(?:property|name)\\s*=\\s*[\"']\(escaped)[\"'][^>]+content\\s*=\\s*[\"']([^\"']+)[\"']",
                "(?is)<meta\\b[^>]+content\\s*=\\s*[\"']([^\"']+)[\"'][^>]+(?:property|name)\\s*=\\s*[\"']\(escaped)[\"']"
            ]
            for pat in patterns {
                if let regex = try? NSRegularExpression(pattern: pat),
                   let m = regex.firstMatch(in: html, range: NSRange(location: 0, length: (html as NSString).length)),
                   m.range(at: 1).location != NSNotFound {
                    let val = decodeEntities((html as NSString).substring(with: m.range(at: 1))).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !val.isEmpty { return val }
                }
            }
        }
        return nil
    }

    private static func extractTagText(_ html: String, tag: String) -> String? {
        guard let block = firstMatchBlock(html, tag: tag) else { return nil }
        let text = decodeEntities(stripHtmlTags(block)).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private static func firstMatchBlock(_ html: String, tag: String) -> String? {
        let pat = "(?is)<\(tag)\\b[^>]*>(.*?)</\(tag)>"
        guard let regex = try? NSRegularExpression(pattern: pat),
              let m = regex.firstMatch(in: html, range: NSRange(location: 0, length: (html as NSString).length)),
              m.range(at: 1).location != NSNotFound else { return nil }
        return (html as NSString).substring(with: m.range(at: 1))
    }

    private static func stripHtmlTags(_ s: String) -> String {
        s.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    private static func decodeEntities(_ s: String) -> String {
        s.replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
    }

    private static func escapeHtml(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

// MARK: - ContentIndexer (OCR, PDF Text, Audio Speech-to-Text, Link Offline Article)

final class ContentIndexer {
    static let shared = ContentIndexer()

    private init() {}

    func sourceKey(for item: ArchiveItem) -> String? {
        guard let raw = item.contentUrl?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        switch item.itemType {
        case .LINK:
            return "v2|\(item.itemType.rawValue)|\(raw)"
        case .PHOTO, .PDF, .AUDIO, .DRAWING:
            if let fileUrl = FileStorageManager.shared.resolveMediaFile(raw),
               let attrs = try? FileManager.default.attributesOfItem(atPath: fileUrl.path),
               let size = attrs[.size] as? NSNumber {
                return "v2|\(item.itemType.rawValue)|\(fileUrl.lastPathComponent)|\(size.int64Value)"
            }
            return "v2|\(item.itemType.rawValue)|\(raw)"
        default:
            return nil
        }
    }

    func indexItem(_ item: ArchiveItem, force: Bool = false, db: PaperclipDatabase = .shared) async -> ItemContent? {
        guard let key = sourceKey(for: item) else { return nil }
        let existing = db.getAllItemContents().first { $0.itemId == item.id }
        if !force, let ex = existing, ex.sourceKey == key, (ex.indexedAt != nil || ex.attempts >= 3) {
            return ex
        }

        let now = ArchiveItem.nowMillis()
        var extractedText: String?
        var articleJson: String?

        switch item.itemType {
        case .LINK:
            if let url = item.contentUrl, let article = await ArticleExtractor.fetchAndExtract(url: url) {
                extractedText = String(article.plainText.prefix(200_000))
                articleJson = article.toJson()
                // Enrich item preview / title if needed
                var updatedItem = item
                var changed = false
                if (updatedItem.previewImageUrl?.isEmpty ?? true), let lead = article.leadImageUrl, !lead.isEmpty {
                    updatedItem.previewImageUrl = lead
                    changed = true
                }
                if changed {
                    _ = db.insertOrReplaceItem(updatedItem)
                }
            }
        case .PHOTO, .DRAWING:
            if let url = FileStorageManager.shared.resolveMediaFile(item.contentUrl),
               let image = UIImage(contentsOfFile: url.path) {
                extractedText = await recognizeTextInImage(image)
            }
        case .PDF:
            if let url = FileStorageManager.shared.resolveMediaFile(item.contentUrl) {
                extractedText = await extractTextFromPdf(url: url)
            }
        case .AUDIO:
            if let url = FileStorageManager.shared.resolveMediaFile(item.contentUrl) {
                extractedText = await transcribeAudioFile(url: url)
            }
        default:
            break
        }

        let cleanText = extractedText?.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalText = (cleanText?.isEmpty ?? true) ? nil : String(cleanText!.prefix(200_000))
        let content = ItemContent(
            itemId: item.id,
            sourceKey: key,
            text: finalText,
            articleJson: articleJson,
            indexedAt: (finalText != nil || articleJson != nil) ? now : nil,
            attempts: (existing?.sourceKey == key ? (existing?.attempts ?? 0) : 0) + 1,
            attemptedAt: now
        )
        db.upsertItemContent(content)
        return content
    }

    func recognizeTextInImage(_ image: UIImage) async -> String? {
        guard let cgImage = image.cgImage else { return nil }
        return await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { req, _ in
                let observations = (req.results as? [VNRecognizedTextObservation]) ?? []
                let lines = observations.compactMap { $0.topCandidates(1).first?.string }
                let joined = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                continuation.resume(returning: joined.isEmpty ? nil : joined)
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = ["it-IT", "en-US"]
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(returning: nil)
            }
        }
    }

    private func extractTextFromPdf(url: URL) async -> String? {
        guard let doc = PDFDocument(url: url) else { return nil }
        var pagesText: [String] = []
        let maxPages = min(doc.pageCount, 40)
        for i in 0..<maxPages {
            guard let page = doc.page(at: i) else { continue }
            if let text = page.string?.trimmingCharacters(in: .whitespacesAndNewlines), text.count > 20 {
                pagesText.append(text)
            } else {
                // Render page and run Vision OCR
                let bounds = page.bounds(for: .mediaBox)
                let renderer = UIGraphicsImageRenderer(size: bounds.size)
                let img = renderer.image { ctx in
                    UIColor.white.set()
                    ctx.fill(bounds)
                    ctx.cgContext.translateBy(x: 0, y: bounds.size.height)
                    ctx.cgContext.scaleBy(x: 1.0, y: -1.0)
                    page.draw(with: .mediaBox, to: ctx.cgContext)
                }
                if let ocr = await recognizeTextInImage(img), !ocr.isEmpty {
                    pagesText.append(ocr)
                }
            }
        }
        let full = pagesText.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return full.isEmpty ? nil : full
    }

    func transcribeAudioFile(url: URL) async -> String? {
        let authStatus = await withCheckedContinuation { (cont: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status)
            }
        }
        guard authStatus == .authorized else { return nil }
        let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "it-IT")) ?? SFSpeechRecognizer()
        guard let recognizer = recognizer, recognizer.isAvailable else { return nil }

        return await withCheckedContinuation { continuation in
            let req = SFSpeechURLRecognitionRequest(url: url)
            req.shouldReportPartialResults = false
            var didResume = false
            recognizer.recognitionTask(with: req) { result, error in
                if didResume { return }
                if let result = result, result.isFinal {
                    didResume = true
                    let text = result.bestTranscription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(returning: text.isEmpty ? nil : text)
                } else if error != nil {
                    didResume = true
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}

// MARK: - ReaderSettings & ReaderModeView

enum ReaderFont: String, CaseIterable, Identifiable {
    case SANS
    case SERIF
    case MONO

    var id: String { rawValue }
    var label: String {
        switch self {
        case .SANS: return "Sans"
        case .SERIF: return "Serif"
        case .MONO: return "Mono"
        }
    }
    var cssStack: String {
        switch self {
        case .SANS: return "-apple-system, BlinkMacSystemFont, sans-serif"
        case .SERIF: return "Georgia, 'Times New Roman', serif"
        case .MONO: return "ui-monospace, SFMono-Regular, Menlo, monospace"
        }
    }
}

enum ReaderTheme: String, CaseIterable, Identifiable {
    case AUTO
    case LIGHT
    case SEPIA
    case DARK

    var id: String { rawValue }
    var label: String {
        switch self {
        case .AUTO: return "Auto"
        case .LIGHT: return "Chiaro"
        case .SEPIA: return "Seppia"
        case .DARK: return "Scuro"
        }
    }
}

final class ReaderSettingsStore: ObservableObject {
    static let shared = ReaderSettingsStore()

    @Published var font: ReaderFont {
        didSet { UserDefaults.standard.set(font.rawValue, forKey: "reader_font") }
    }
    @Published var fontSizeSp: Int {
        didSet { UserDefaults.standard.set(fontSizeSp, forKey: "reader_font_size") }
    }
    @Published var lineHeight: Double {
        didSet { UserDefaults.standard.set(lineHeight, forKey: "reader_line_height") }
    }
    @Published var theme: ReaderTheme {
        didSet { UserDefaults.standard.set(theme.rawValue, forKey: "reader_theme") }
    }

    private init() {
        self.font = ReaderFont(rawValue: UserDefaults.standard.string(forKey: "reader_font") ?? "") ?? .SERIF
        let size = UserDefaults.standard.integer(forKey: "reader_font_size")
        self.fontSizeSp = (14...26).contains(size) ? size : 18
        let lh = UserDefaults.standard.double(forKey: "reader_line_height")
        self.lineHeight = (1.3...2.0).contains(lh) ? lh : 1.65
        self.theme = ReaderTheme(rawValue: UserDefaults.standard.string(forKey: "reader_theme") ?? "") ?? .AUTO
    }
}

// MARK: - ReadAloudManager & ReadAloudBar

@MainActor
final class ReadAloudManager: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private var chunks: [String] = []
    private static let speeds: [Float] = [0.8, 1.0, 1.25, 1.5, 1.75, 2.0]

    @Published var isActive: Bool = false
    @Published var isPlaying: Bool = false
    @Published var currentIndex: Int = 0
    @Published var totalChunks: Int = 0
    @Published var speed: Float = 1.0

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func start(title: String?, body: String) {
        let built = Self.splitIntoChunks(title: title, body: body)
        guard !built.isEmpty else { return }
        chunks = built
        totalChunks = built.count
        currentIndex = 0
        isActive = true
        speakChunk(at: 0)
    }

    func togglePlayPause() {
        if !isActive { return }
        if synthesizer.isSpeaking {
            if synthesizer.isPaused {
                synthesizer.continueSpeaking()
                isPlaying = true
            } else {
                synthesizer.pauseSpeaking(at: .word)
                isPlaying = false
            }
        } else {
            speakChunk(at: currentIndex)
        }
    }

    func next() {
        guard isActive, currentIndex + 1 < chunks.count else { return }
        speakChunk(at: currentIndex + 1)
    }

    func previous() {
        guard isActive else { return }
        speakChunk(at: max(0, currentIndex - 1))
    }

    func cycleSpeed() {
        let idx = Self.speeds.firstIndex(of: speed) ?? 1
        speed = Self.speeds[(idx + 1) % Self.speeds.count]
        if isActive && isPlaying {
            speakChunk(at: currentIndex)
        }
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        isActive = false
        isPlaying = false
        currentIndex = 0
    }

    private func speakChunk(at index: Int) {
        guard index >= 0 && index < chunks.count else {
            isActive = false
            isPlaying = false
            return
        }
        synthesizer.stopSpeaking(at: .immediate)
        currentIndex = index
        let text = chunks[index]
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: Self.detectLanguageTag(text))
        // Convert 1.0x speed to AVSpeechUtteranceDefaultSpeechRate scale
        utterance.rate = min(AVSpeechUtteranceMaximumSpeechRate, max(AVSpeechUtteranceMinimumSpeechRate, AVSpeechUtteranceDefaultSpeechRate * speed))
        isPlaying = true
        synthesizer.speak(utterance)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            guard self.isActive else { return }
            if self.currentIndex + 1 < self.chunks.count {
                self.speakChunk(at: self.currentIndex + 1)
            } else {
                self.isPlaying = false
                self.isActive = false
                self.currentIndex = 0
            }
        }
    }

    private static func detectLanguageTag(_ sample: String) -> String {
        let lower = " " + sample.prefix(1500).lowercased() + " "
        let itTokens = [" il ", " lo ", " la ", " gli ", " le ", " che ", " non ", " per ", " con ", " una ", " della ", " nella ", " sono ", " anche ", " più ", " perché "]
        let enTokens = [" the ", " and ", " that ", " with ", " from ", " this ", " have ", " which ", " their ", " would ", " there ", " about "]
        let itHits = itTokens.filter { lower.contains($0) }.count
        let enHits = enTokens.filter { lower.contains($0) }.count
        if enHits >= 3 && enHits > itHits * 2 { return "en-US" }
        if itHits >= 2 { return "it-IT" }
        return Locale.current.identifier
    }

    private static func splitIntoChunks(title: String?, body: String) -> [String] {
        var result: [String] = []
        if let t = title?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
            result.append(t)
        }
        let paragraphs = body.components(separatedBy: "\n\n")
            .map { $0.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        for para in paragraphs {
            if para.count <= 320 {
                result.append(para)
            } else {
                result.append(para)
            }
        }
        return result
    }
}

struct ReadAloudBar: View {
    @ObservedObject var manager: ReadAloudManager

    var body: some View {
        if manager.isActive {
            VStack(spacing: 4) {
                ProgressView(value: Double(manager.currentIndex + 1), total: Double(max(1, manager.totalChunks)))
                    .tint(.accentColor)

                HStack(spacing: 12) {
                    Button {
                        manager.previous()
                    } label: {
                        Image(systemName: "backward.end.fill")
                    }
                    .disabled(manager.currentIndex <= 0)

                    Button {
                        manager.togglePlayPause()
                    } label: {
                        Image(systemName: manager.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.title2)
                    }

                    Button {
                        manager.next()
                    } label: {
                        Image(systemName: "forward.end.fill")
                    }
                    .disabled(manager.currentIndex + 1 >= manager.totalChunks)

                    Text("\(manager.currentIndex + 1) / \(manager.totalChunks)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)

                    Spacer()

                    Button {
                        manager.cycleSpeed()
                    } label: {
                        Text(String(format: "%.2gx", manager.speed))
                            .font(.caption.weight(.bold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.accentColor.opacity(0.15), in: Capsule())
                    }

                    Button {
                        manager.stop()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            .padding(.horizontal)
        }
    }
}

// MARK: - AudioRecorderManager & AudioPlayerManager

@MainActor
final class AudioRecorderManager: NSObject, ObservableObject, AVAudioRecorderDelegate {
    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var startTime: Date?

    @Published var isRecording: Bool = false
    @Published var elapsedMs: Int64 = 0
    @Published var recordedFilePath: String?
    @Published var errorMessage: String?

    func startRecording() {
        let session = AVAudioSession.sharedInstance()
        session.requestRecordPermission { [weak self] granted in
            Task { @MainActor in
                guard let self = self else { return }
                guard granted else {
                    self.errorMessage = "Permesso microfono negato"
                    return
                }
                do {
                    try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
                    try session.setActive(true)
                    let fileName = "voice_\(ArchiveItem.nowMillis()).m4a"
                    let fileUrl = FileStorageManager.shared.mediaDirectory.appendingPathComponent(fileName)
                    let settings: [String: Any] = [
                        AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                        AVSampleRateKey: 44100,
                        AVNumberOfChannelsKey: 1,
                        AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
                    ]
                    let rec = try AVAudioRecorder(url: fileUrl, settings: settings)
                    rec.delegate = self
                    rec.record()
                    self.recorder = rec
                    self.recordedFilePath = fileUrl.path
                    self.startTime = Date()
                    self.elapsedMs = 0
                    self.isRecording = true
                    self.timer?.invalidate()
                    self.timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
                        Task { @MainActor in
                            guard let self = self, let start = self.startTime else { return }
                            self.elapsedMs = Int64(Date().timeIntervalSince(start) * 1000)
                        }
                    }
                } catch {
                    self.errorMessage = "Errore registrazione: \(error.localizedDescription)"
                }
            }
        }
    }

    func stopRecording() -> (path: String, durationMs: Int64)? {
        timer?.invalidate()
        timer = nil
        recorder?.stop()
        recorder = nil
        isRecording = false
        guard let path = recordedFilePath else { return nil }
        return (path, max(1000, elapsedMs))
    }
}

@MainActor
final class AudioPlayerManager: NSObject, ObservableObject, AVAudioPlayerDelegate {
    private var player: AVAudioPlayer?
    private var timer: Timer?

    @Published var isPlaying: Bool = false
    @Published var currentTimeMs: Int64 = 0
    @Published var durationMs: Int64 = 0

    func loadAndToggle(url: URL) {
        if let player = player, player.url == url {
            if player.isPlaying {
                player.pause()
                isPlaying = false
                timer?.invalidate()
            } else {
                player.play()
                isPlaying = true
                startProgressTimer()
            }
            return
        }
        stop()
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
            let p = try AVAudioPlayer(contentsOf: url)
            p.delegate = self
            p.prepareToPlay()
            durationMs = Int64(p.duration * 1000)
            p.play()
            player = p
            isPlaying = true
            startProgressTimer()
        } catch {
            isPlaying = false
        }
    }

    func seek(toMs ms: Int64) {
        guard let p = player else { return }
        p.currentTime = Double(ms) / 1000.0
        currentTimeMs = ms
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        player?.stop()
        player = nil
        isPlaying = false
        currentTimeMs = 0
    }

    private func startProgressTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self, let p = self.player else { return }
                self.currentTimeMs = Int64(p.currentTime * 1000)
            }
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.isPlaying = false
            self.currentTimeMs = 0
            self.timer?.invalidate()
        }
    }
}

// MARK: - DocumentScannerView (VNDocumentCameraViewController -> Multi-page PDF)

struct DocumentScannerView: UIViewControllerRepresentable {
    var onScannedPdf: (String, Int) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator {
        Coordinator(onScannedPdf: onScannedPdf, dismiss: dismiss)
    }

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let vc = VNDocumentCameraViewController()
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ uiViewController: VNDocumentCameraViewController, context: Context) {}

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let onScannedPdf: (String, Int) -> Void
        let dismiss: DismissAction

        init(onScannedPdf: @escaping (String, Int) -> Void, dismiss: DismissAction) {
            self.onScannedPdf = onScannedPdf
            self.dismiss = dismiss
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            let pdfDoc = PDFDocument()
            for i in 0..<scan.pageCount {
                let img = scan.imageOfPage(at: i)
                if let page = PDFPage(image: img) {
                    pdfDoc.insert(page, at: pdfDoc.pageCount)
                }
            }
            let fileName = "scan_\(ArchiveItem.nowMillis()).pdf"
            let dest = FileStorageManager.shared.mediaDirectory.appendingPathComponent(fileName)
            if pdfDoc.write(to: dest) {
                onScannedPdf(dest.path, scan.pageCount)
            }
            dismiss()
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            dismiss()
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
            dismiss()
        }
    }
}

// MARK: - CameraCaptureView (UIImagePickerController .camera)

struct CameraCaptureView: UIViewControllerRepresentable {
    var onCapturedImage: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator {
        Coordinator(onCapturedImage: onCapturedImage, dismiss: dismiss)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        if UIImagePickerController.isSourceTypeAvailable(.camera) {
            picker.sourceType = .camera
        } else {
            picker.sourceType = .photoLibrary
        }
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let onCapturedImage: (String) -> Void
        let dismiss: DismissAction

        init(onCapturedImage: @escaping (String) -> Void, dismiss: DismissAction) {
            self.onCapturedImage = onCapturedImage
            self.dismiss = dismiss
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let img = info[.originalImage] as? UIImage,
               let data = img.jpegData(compressionQuality: 0.88),
               let saved = try? FileStorageManager.shared.saveMediaData(data, preferredFileName: "camera_\(ArchiveItem.nowMillis()).jpg") {
                onCapturedImage(saved)
            }
            dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            dismiss()
        }
    }
}

// MARK: - DrawingCanvasSheet (PencilKit Freehand & Photo Annotation)

struct DrawingCanvasSheet: View {
    var backgroundImagePath: String? = nil
    var onSave: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var drawing = PKDrawing()
    @State private var canvasBounds: CGRect = CGRect(x: 0, y: 0, width: 390, height: 600)

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                ZStack {
                    Color.white
                    if let bgPath = backgroundImagePath,
                       let url = FileStorageManager.shared.resolveMediaFile(bgPath),
                       let uiImg = UIImage(contentsOfFile: url.path) {
                        Image(uiImage: uiImg)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    PencilKitCanvasRepresentable(drawing: $drawing)
                }
                .onAppear {
                    canvasBounds = CGRect(origin: .zero, size: geo.size)
                }
                .onChange(of: geo.size) { newSize in
                    canvasBounds = CGRect(origin: .zero, size: newSize)
                }
            }
            .navigationTitle(backgroundImagePath == nil ? "Disegno a mano libera" : "Disegna su foto")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annulla") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Pulisci") {
                        drawing = PKDrawing()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Salva") {
                        saveRenderedDrawing()
                    }
                }
            }
        }
    }

    private func saveRenderedDrawing() {
        let rect = canvasBounds.width > 10 ? canvasBounds : CGRect(x: 0, y: 0, width: 800, height: 1000)
        let renderer = UIGraphicsImageRenderer(bounds: rect)
        let finalImage = renderer.image { ctx in
            UIColor.white.setFill()
            ctx.fill(rect)
            if let bgPath = backgroundImagePath,
               let url = FileStorageManager.shared.resolveMediaFile(bgPath),
               let bgImg = UIImage(contentsOfFile: url.path) {
                bgImg.draw(in: rect)
            }
            let strokesImg = drawing.image(from: rect, scale: UIScreen.main.scale)
            strokesImg.draw(in: rect)
        }
        if let png = finalImage.pngData(),
           let path = try? FileStorageManager.shared.saveMediaData(png, preferredFileName: "drawing_\(ArchiveItem.nowMillis()).png") {
            onSave(path)
        }
        dismiss()
    }
}

private struct PencilKitCanvasRepresentable: UIViewRepresentable {
    @Binding var drawing: PKDrawing

    func makeCoordinator() -> Coordinator {
        Coordinator(drawing: $drawing)
    }

    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = PKCanvasView()
        canvas.drawingPolicy = .anyInput
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.tool = PKInkingTool(.pen, color: .black, width: 5)
        canvas.delegate = context.coordinator
        return canvas
    }

    func updateUIView(_ uiView: PKCanvasView, context: Context) {
        if uiView.drawing != drawing {
            uiView.drawing = drawing
        }
    }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        @Binding var drawing: PKDrawing
        init(drawing: Binding<PKDrawing>) {
            _drawing = drawing
        }
        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            drawing = canvasView.drawing
        }
    }
}

// MARK: - ReaderModeSheet (Offline Article Reader + Highlights + Read Aloud)

struct ReaderModeSheet: View {
    let item: ArchiveItem
    let article: ExtractedArticle
    var onUpdateHighlights: ([ArticleHighlight]) -> Void

    @ObservedObject private var settings = ReaderSettingsStore.shared
    @StateObject private var readAloud = ReadAloudManager()
    @State private var highlights: [ArticleHighlight]
    @State private var showSettings = false
    @State private var showAddHighlight = false
    @State private var newHighlightText = ""
    @State private var newHighlightNote = ""
    @State private var newHighlightColor: HighlightColor = .YELLOW
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    init(item: ArchiveItem, article: ExtractedArticle, onUpdateHighlights: @escaping ([ArticleHighlight]) -> Void) {
        self.item = item
        self.article = article
        self.onUpdateHighlights = onUpdateHighlights
        _highlights = State(initialValue: ArticleHighlight.fromJson(item.highlightsJson))
    }

    private var palette: (bg: Color, fg: Color, muted: Color) {
        let effectiveDark = settings.theme == .DARK || (settings.theme == .AUTO && colorScheme == .dark)
        if settings.theme == .SEPIA {
            return (Color(hexString: "#F5ECD9"), Color(hexString: "#2C2218"), Color(hexString: "#6E5D49"))
        } else if effectiveDark {
            return (Color(hexString: "#121316"), Color(hexString: "#E7E8EC"), Color(hexString: "#9AA0AC"))
        } else {
            return (.white, Color(hexString: "#1B1C1F"), Color(hexString: "#5F6470"))
        }
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if let site = article.siteName, !site.isEmpty {
                            Text("\(site) • \(article.readingMinutes) min di lettura")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(palette.muted)
                        }
                        Text(article.title ?? item.title)
                            .font(.system(size: CGFloat(settings.fontSizeSp + 6), weight: .bold))
                            .foregroundStyle(palette.fg)

                        if let byline = article.byline, !byline.isEmpty {
                            Text(byline)
                                .font(.subheadline)
                                .foregroundStyle(palette.muted)
                        }

                        Divider()

                        Text(article.plainText)
                            .font(swiftUIFont)
                            .lineSpacing(CGFloat(Double(settings.fontSizeSp) * (settings.lineHeight - 1.0)))
                            .foregroundStyle(palette.fg)
                            .textSelection(.enabled)

                        if !highlights.isEmpty {
                            Divider().padding(.vertical, 8)
                            Text("Evidenziazioni (\(highlights.count))")
                                .font(.headline)
                                .foregroundStyle(palette.fg)

                            ForEach(highlights) { h in
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack {
                                        Circle()
                                            .fill(Color(argb: h.highlightColor.argb))
                                            .frame(width: 12, height: 12)
                                        Text(h.highlightColor.label)
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(palette.muted)
                                        Spacer()
                                        Button(role: .destructive) {
                                            highlights.removeAll { $0.id == h.id }
                                            onUpdateHighlights(highlights)
                                        } label: {
                                            Image(systemName: "trash")
                                                .font(.caption)
                                        }
                                    }
                                    Text("“\(h.text)”")
                                        .font(.subheadline)
                                        .foregroundStyle(palette.fg)
                                    if let note = h.note, !note.isEmpty {
                                        Text(note)
                                            .font(.caption)
                                            .italic()
                                            .foregroundStyle(palette.muted)
                                    }
                                }
                                .padding(12)
                                .background(Color(argb: h.highlightColor.argb).opacity(0.22), in: RoundedRectangle(cornerRadius: 12))
                            }
                        }
                    }
                    .padding(20)
                    .padding(.bottom, readAloud.isActive ? 90 : 24)
                }
                .background(palette.bg.ignoresSafeArea())

                ReadAloudBar(manager: readAloud)
                    .padding(.bottom, 8)
            }
            .navigationTitle("Modalità lettura")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Chiudi") {
                        readAloud.stop()
                        dismiss()
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        if readAloud.isActive {
                            readAloud.stop()
                        } else {
                            readAloud.start(title: article.title ?? item.title, body: article.plainText)
                        }
                    } label: {
                        Image(systemName: readAloud.isActive ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    }

                    Button {
                        showAddHighlight = true
                    } label: {
                        Image(systemName: "highlighter")
                    }

                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "textformat.size")
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                readerSettingsSheet
            }
            .sheet(isPresented: $showAddHighlight) {
                addHighlightSheet
            }
        }
    }

    private var swiftUIFont: Font {
        let size = CGFloat(settings.fontSizeSp)
        switch settings.font {
        case .SANS: return .system(size: size, design: .default)
        case .SERIF: return .system(size: size, design: .serif)
        case .MONO: return .system(size: size, design: .monospaced)
        }
    }

    private var readerSettingsSheet: some View {
        NavigationStack {
            Form {
                Section("Carattere") {
                    Picker("Font", selection: $settings.font) {
                        ForEach(ReaderFont.allCases) { f in
                            Text(f.label).tag(f)
                        }
                    }
                    .pickerStyle(.segmented)

                    Stepper("Dimensione: \(settings.fontSizeSp) pt", value: $settings.fontSizeSp, in: 14...26)

                    VStack(alignment: .leading) {
                        Text(String(format: "Interlinea: %.2f", settings.lineHeight))
                        Slider(value: $settings.lineHeight, in: 1.3...2.0, step: 0.05)
                    }
                }

                Section("Tema di lettura") {
                    Picker("Tema", selection: $settings.theme) {
                        ForEach(ReaderTheme.allCases) { t in
                            Text(t.label).tag(t)
                        }
                    }
                    .pickerStyle(.segmented)
                }
            }
            .navigationTitle("Aspetto lettura")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fatto") { showSettings = false }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private var addHighlightSheet: some View {
        NavigationStack {
            Form {
                Section("Testo evidenziato") {
                    TextEditor(text: $newHighlightText)
                        .frame(minHeight: 80)
                }
                Section("Colore") {
                    Picker("Colore", selection: $newHighlightColor) {
                        ForEach(HighlightColor.allCases) { c in
                            Text(c.label).tag(c)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                Section("Nota (opzionale)") {
                    TextField("Aggiungi una nota...", text: $newHighlightNote)
                }
            }
            .navigationTitle("Nuova evidenziazione")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annulla") { showAddHighlight = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Salva") {
                        let clean = newHighlightText.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !clean.isEmpty else { return }
                        let h = ArticleHighlight(
                            text: clean,
                            start: highlights.count,
                            color: newHighlightColor,
                            note: newHighlightNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : newHighlightNote.trimmingCharacters(in: .whitespacesAndNewlines)
                        )
                        highlights.append(h)
                        onUpdateHighlights(highlights)
                        newHighlightText = ""
                        newHighlightNote = ""
                        showAddHighlight = false
                    }
                    .disabled(newHighlightText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }
}

private extension Color {
    init(argb: UInt32) {
        let a = Double((argb >> 24) & 0xFF) / 255.0
        let r = Double((argb >> 16) & 0xFF) / 255.0
        let g = Double((argb >> 8) & 0xFF) / 255.0
        let b = Double(argb & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}
