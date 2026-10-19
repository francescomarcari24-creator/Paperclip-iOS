import Foundation

enum LinkUrls {
    private static let trackingParams: Set<String> = [
        "fbclid", "gclid", "igshid", "mc_cid", "mc_eid", "ref_src", "si"
    ]

    /// Normalizes a URL in the exact same way as Android's `LinkUrls.normalize`:
    /// strips scheme, leading "www.", trailing slash, fragment, and tracking parameters (`utm_*`, `fbclid`, etc.).
    static func normalize(_ url: String?) -> String? {
        guard let raw = url?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        let withScheme = raw.contains("://") ? raw : "https://\(raw)"
        guard let components = URLComponents(string: withScheme),
              let rawHost = components.host?.lowercased() else {
            var lower = raw.lowercased()
            if lower.hasSuffix("/") { lower.removeLast() }
            return lower
        }

        let host = rawHost.hasPrefix("www.") ? String(rawHost.dropFirst(4)) : rawHost
        var path = components.percentEncodedPath
        if path.hasSuffix("/") { path.removeLast() }

        let filteredQuery: String? = {
            guard let rawQuery = components.percentEncodedQuery, !rawQuery.isEmpty else { return nil }
            let parts = rawQuery
                .split(separator: "&")
                .map(String.init)
                .filter { param in
                    let name = param.split(separator: "=", maxSplits: 1).first.map(String.init)?.lowercased() ?? ""
                    return !name.isEmpty && !name.hasPrefix("utm_") && !trackingParams.contains(name)
                }
                .sorted()
            return parts.isEmpty ? nil : parts.joined(separator: "&")
        }()

        let portPart = components.port.map { ":\($0)" } ?? ""
        let queryPart = filteredQuery.map { "?\($0)" } ?? ""
        return host + portPart + path + queryPart
    }

    static func samePage(_ a: String?, _ b: String?) -> Bool {
        guard let keyA = normalize(a) else { return false }
        return keyA == normalize(b)
    }
}
