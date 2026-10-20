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

    /// Normalizes a raw web URL ensuring an `http://` or `https://` scheme and valid host.
    static func normalizeWebUrl(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        let lower = trimmed.lowercased()
        if lower.hasPrefix("javascript:") || lower.hasPrefix("data:") || lower.hasPrefix("about:") || lower.hasPrefix("chrome:") || lower.hasPrefix("place:") {
            return nil
        }
        let withScheme: String
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            withScheme = trimmed
        } else if trimmed.contains(".") && !trimmed.contains(" ") {
            withScheme = "https://\(trimmed)"
        } else {
            return nil
        }
        guard let comps = URLComponents(string: withScheme),
              let host = comps.host, !host.isEmpty else {
            return nil
        }
        return comps.url?.absoluteString ?? withScheme
    }

    static func defaultTitleForUrl(_ raw: String?) -> String? {
        guard let norm = normalizeWebUrl(raw),
              let url = URL(string: norm),
              let host = url.host else {
            return nil
        }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    static func extractFirstUrl(_ text: String) -> String? {
        guard !text.isEmpty,
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return nil
        }
        let nsText = text as NSString
        let matches = detector.matches(in: text, options: [], range: NSRange(location: 0, length: nsText.length))
        for match in matches {
            if let url = match.url,
               let scheme = url.scheme?.lowercased(),
               scheme == "http" || scheme == "https" {
                return url.absoluteString
            }
        }
        return nil
    }
}
