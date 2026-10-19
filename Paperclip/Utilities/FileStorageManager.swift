import Foundation

final class FileStorageManager {
    static let shared = FileStorageManager()

    var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    var mediaDirectory: URL {
        let dir = documentsDirectory.appendingPathComponent("media", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    /// Resolves a stored `contentUrl` (which may come from an Android backup or another iOS container UUID)
    /// by falling back to the file name inside `Documents/media/`.
    func resolveMediaFile(_ pathOrUrl: String?) -> URL? {
        guard let raw = pathOrUrl, !raw.isEmpty else { return nil }
        let directUrl = URL(fileURLWithPath: raw)
        if FileManager.default.fileExists(atPath: directUrl.path) {
            return directUrl
        }
        let fileName = (raw as NSString).lastPathComponent
        guard !fileName.isEmpty else { return nil }
        let fallback = mediaDirectory.appendingPathComponent(fileName)
        return FileManager.default.fileExists(atPath: fallback.path) ? fallback : directUrl
    }

    /// Rewrites an Android or foreign `/media/<name>` path to the local `Documents/media/<name>` path.
    func rewriteBackupMediaPath(_ contentUrl: String?) -> String? {
        guard let url = contentUrl else { return nil }
        guard url.contains("/media/") else { return url }
        let fileName = (url as NSString).lastPathComponent
        guard !fileName.isEmpty else { return url }
        return mediaDirectory.appendingPathComponent(fileName).path
    }

    func saveMediaData(_ data: Data, preferredFileName: String) throws -> String {
        let safeName = (preferredFileName as NSString).lastPathComponent
        let dest = mediaDirectory.appendingPathComponent(safeName)
        try data.write(to: dest, options: .atomic)
        return dest.path
    }

    func copyImportedFile(from sourceUrl: URL, prefix: String = "media") throws -> String {
        let ext = sourceUrl.pathExtension.isEmpty ? "bin" : sourceUrl.pathExtension
        let fileName = "\(prefix)_\(Int64(Date().timeIntervalSince1970 * 1000))_\(UUID().uuidString.prefix(6)).\(ext)"
        let dest = mediaDirectory.appendingPathComponent(fileName)
        let accessed = sourceUrl.startAccessingSecurityScopedResource()
        defer {
            if accessed { sourceUrl.stopAccessingSecurityScopedResource() }
        }
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.copyItem(at: sourceUrl, to: dest)
        return dest.path
    }

    func deleteFile(_ pathOrUrl: String?) {
        guard let resolved = resolveMediaFile(pathOrUrl) else { return }
        if FileManager.default.fileExists(atPath: resolved.path) {
            try? FileManager.default.removeItem(at: resolved)
        }
    }

    func listAllMediaFiles() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: mediaDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? []
    }
}
