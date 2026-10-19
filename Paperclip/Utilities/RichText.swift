import Foundation
import SwiftUI

enum RichText {
    /// Strips Markdown markers for plain-text previews, notifications, and widgets, matching Android `RichText.strip`.
    static func strip(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        return lines.map { line in
            var body = line
            var isBullet = false
            if body.hasPrefix("# ") {
                body = String(body.dropFirst(2))
            } else if body.hasPrefix("## ") {
                body = String(body.dropFirst(3))
            } else if body.hasPrefix("### ") {
                body = String(body.dropFirst(4))
            } else if body.hasPrefix("- ") || body.hasPrefix("* ") {
                body = String(body.dropFirst(2))
                isBullet = true
            } else if body.hasPrefix("> ") {
                body = String(body.dropFirst(2))
            }
            let cleaned = body
                .replacingOccurrences(of: "**", with: "")
                .replacingOccurrences(of: "~~", with: "")
                .replacingOccurrences(of: "`", with: "")
            return isBullet ? "• \(cleaned)" : cleaned
        }.joined(separator: "\n")
    }

    /// Renders the Paperclip Markdown subset (`**`, `*`/`_`, `~~`, `` ` ``, `# `, `## `, `- `, `> `) into a SwiftUI `AttributedString`.
    static func render(_ text: String) -> AttributedString {
        let lines = text.components(separatedBy: "\n")
        var result = AttributedString()

        for (index, line) in lines.enumerated() {
            var linePrefix = ""
            var body = line
            var isH1 = false
            var isH2 = false
            var isQuote = false

            if line.hasPrefix("# ") {
                body = String(line.dropFirst(2))
                isH1 = true
            } else if line.hasPrefix("## ") {
                body = String(line.dropFirst(3))
                isH2 = true
            } else if line.hasPrefix("### ") {
                body = String(line.dropFirst(4))
                isH2 = true
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                body = String(line.dropFirst(2))
                linePrefix = "• "
            } else if line.hasPrefix("> ") {
                body = String(line.dropFirst(2))
                linePrefix = "▏ "
                isQuote = true
            }

            var renderedLine = (try? AttributedString(
                markdown: linePrefix + body,
                options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            )) ?? AttributedString(linePrefix + body)

            if isH1 {
                renderedLine.font = .system(size: 21, weight: .bold)
            } else if isH2 {
                renderedLine.font = .system(size: 18, weight: .bold)
            } else if isQuote {
                renderedLine.font = .system(.body).italic()
            }

            result.append(renderedLine)
            if index < lines.count - 1 {
                result.append(AttributedString("\n"))
            }
        }
        return result
    }

    /// Converts the Paperclip Markdown subset to HTML (matching `RichText.toHtml` in Android).
    static func toHtml(_ text: String) -> String {
        var out = ""
        var listOpen = false
        var paragraph: [String] = []

        func flushParagraph() {
            if !paragraph.isEmpty {
                out += "<p>\(paragraph.joined(separator: "<br>"))</p>\n"
                paragraph.removeAll()
            }
        }

        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let isBullet = line.hasPrefix("- ") || line.hasPrefix("* ")
            if !isBullet && listOpen {
                out += "</ul>\n"
                listOpen = false
            }

            if line.hasPrefix("# ") {
                flushParagraph()
                out += "<h3>\(htmlEscape(String(line.dropFirst(2))))</h3>\n"
            } else if line.hasPrefix("## ") {
                flushParagraph()
                out += "<h4>\(htmlEscape(String(line.dropFirst(3))))</h4>\n"
            } else if line.hasPrefix("### ") {
                flushParagraph()
                out += "<h4>\(htmlEscape(String(line.dropFirst(4))))</h4>\n"
            } else if line.hasPrefix("> ") {
                flushParagraph()
                out += "<blockquote>\(htmlEscape(String(line.dropFirst(2))))</blockquote>\n"
            } else if isBullet {
                flushParagraph()
                if !listOpen {
                    out += "<ul>\n"
                    listOpen = true
                }
                out += "<li>\(htmlEscape(String(line.dropFirst(2))))</li>\n"
            } else if trimmed.isEmpty {
                flushParagraph()
            } else {
                paragraph.append(htmlEscape(line))
            }
        }
        flushParagraph()
        if listOpen {
            out += "</ul>\n"
        }
        return out
    }

    static func htmlEscape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}
