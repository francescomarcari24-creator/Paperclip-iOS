import Foundation
import os.log

@MainActor
final class AppLogger: ObservableObject {
    static let shared = AppLogger()

    struct Entry: Identifiable {
        let id = UUID()
        let timestamp: Date
        let category: String
        let message: String
        let isError: Bool
    }

    @Published private(set) var entries: [Entry] = []
    private let logger = Logger(subsystem: "com.project.paperclip", category: "Paperclip")

    private init() {
        info("App", "Paperclip iOS avviato")
    }

    nonisolated func info(_ category: String, _ message: String) {
        logger.info("[\(category, privacy: .public)] \(message, privacy: .public)")
        Task { @MainActor in
            self.append(category: category, message: message, isError: false)
        }
    }

    nonisolated func error(_ category: String, _ message: String) {
        logger.error("[\(category, privacy: .public)] ERRORE: \(message, privacy: .public)")
        Task { @MainActor in
            self.append(category: category, message: message, isError: true)
        }
    }

    private func append(category: String, message: String, isError: Bool) {
        entries.insert(Entry(timestamp: Date(), category: category, message: message, isError: isError), at: 0)
        if entries.count > 300 {
            entries.removeLast(entries.count - 300)
        }
    }

    func clear() {
        entries.removeAll()
    }

    func exportText() -> String {
        let formatter = ISO8601DateFormatter()
        return entries.map { entry in
            "[\(formatter.string(from: entry.timestamp))] [\(entry.isError ? "ERR" : "INFO")] [\(entry.category)] \(entry.message)"
        }.joined(separator: "\n")
    }
}
